/**
 * HermesSession — pi-UI-compatible session driven by the forked hermes engine.
 *
 * ALFRED fork. The pi interactive TUI is fused to `AgentSession`; this class
 * subclasses it and swaps ONLY the agent turn machinery: instead of running
 * the pi agent loop, each prompt is executed by the local hermes gateway
 * (see ./hermes-gateway.ts) while every event the UI renders — message
 * start/update/end, turn start/end, tool execution, agent end — is
 * synthesized through the real AgentSession event pipeline, so session
 * persistence, extensions (including the ALFRED header/theme), footer stats,
 * and all rendering behave exactly as before.
 *
 * Enabled with ALFRED_ENGINE=hermes (see sdk.ts).
 */

import { contentText } from "@earendil-works/pi-ai";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { AgentSession, type AgentSessionConfig } from "./agent-session.ts";
import { HermesGateway, type HermesTurnResult } from "./hermes-gateway.ts";

type StreamingAssistantMessage = Omit<AgentMessage, "content"> & {
	role: "assistant";
	content: any[];
	stopReason?: string;
	errorMessage?: string;
	usage?: any;
};

function tryContentText(content: any): string {
	try {
		return contentText(content, "");
	} catch {
		if (typeof content === "string") return content;
		return "";
	}
}

function mapUsage(usage: any): any {
	const input = Number(usage?.input ?? usage?.prompt_tokens ?? 0) || 0;
	const output = Number(usage?.output ?? usage?.completion_tokens ?? 0) || 0;
	const cacheRead = Number(usage?.cacheRead ?? usage?.cache_read ?? usage?.cached_tokens ?? 0) || 0;
	const cacheWrite = Number(usage?.cacheWrite ?? usage?.cache_write ?? 0) || 0;
	return {
		input,
		output,
		cacheRead,
		cacheWrite,
		total: Number(usage?.total ?? input + output) || 0,
		cost: Number(usage?.cost ?? usage?.total_cost ?? 0) || 0,
	};
}

export class HermesSession extends AgentSession {
	private gateway: HermesGateway | undefined;

	constructor(config: AgentSessionConfig) {
		super(config);
		this.installEngineOverrides();
	}

	/**
	 * Swap the private turn/queue machinery for the hermes-backed versions.
	 * The public `prompt()`/`steer()`/`followUp()` methods are untouched, so
	 * extension-command interception, skill/template expansion, auth
	 * preflight, and streaming-behavior queueing all behave identically.
	 */
	private installEngineOverrides(): void {
		const anyThis = this as any;

		anyThis._runAgentPrompt = (messages: AgentMessage | AgentMessage[]) =>
			this.runHermesPrompt(messages);

		anyThis._queueSteer = async (text: string) => {
			anyThis._steeringMessages.push(text);
			anyThis._emitQueueUpdate();
			await this.gatewaySafe().steer(text);
			// If steer didn't land (e.g. turn already over), carry it as a
			// follow-up so it is never silently dropped.
			if (!this.isStreaming) {
				const index = anyThis._steeringMessages.indexOf(text);
				if (index >= 0) {
					anyThis._steeringMessages.splice(index, 1);
					anyThis._followUpMessages.push(text);
					anyThis._emitQueueUpdate();
				}
			}
		};

		anyThis._queueFollowUp = async (text: string) => {
			anyThis._followUpMessages.push(text);
			anyThis._emitQueueUpdate();
		};
	}

	/** Engine-side abort: interrupt hermes, then wait for the turn to settle. */
	override async abort(): Promise<void> {
		this.abortRetry();
		try {
			await this.gatewaySafe().interrupt();
		} catch {
			// best-effort
		}
		await this.waitForIdle();
	}

	override dispose(): void {
		super.dispose();
		try {
			this.gateway?.close();
		} catch {
			// best-effort
		}
		this.gateway = undefined;
	}

	// -- engine machinery ---------------------------------------------------

	private gatewaySafe(): HermesGateway {
		if (!this.gateway) {
			this.gateway = new HermesGateway();
		}
		return this.gateway;
	}

	/**
	 * Replaces AgentSession._runAgentPrompt: execute the turn on hermes and
	 * synthesize every event through the real pipeline.
	 */
	private async runHermesPrompt(messages: AgentMessage | AgentMessage[]): Promise<void> {
		const anyThis = this as any;
		anyThis._isAgentRunActive = true;
		try {
			const list = Array.isArray(messages) ? messages : [messages];

			await anyThis._handleAgentEvent({ type: "agent_start" });

			// Custom (extension-injected) messages first, then the user turn.
			for (const message of list) {
				if (message.role !== "custom") continue;
				this.agent.state.messages.push(message);
				await anyThis._handleAgentEvent({ type: "message_start", message });
				await anyThis._handleAgentEvent({ type: "message_end", message });
			}

			const userMessages = list.filter((message) => message.role === "user");
			if (userMessages.length > 0) {
				const text = userMessages
					.map((message) => tryContentText(message.content))
					.filter(Boolean)
					.join("\n");
				await this.runHermesTurn(text || "(empty prompt)");
			}

			// Drain follow-ups queued while the turn was running (alt+enter).
			let guard = 0;
			while ((anyThis._followUpMessages?.length ?? 0) > 0 && guard++ < 50) {
				const next = anyThis._followUpMessages.shift();
				if (typeof next === "string" && next.trim()) {
					await this.runHermesTurn(next.trim());
				}
			}
		} catch {
			// Engine failures surface as an error bubble inside runHermesTurn;
			// nothing else to do here — the finally below settles the run.
		} finally {
			anyThis._systemPromptOverride = undefined;
			try {
				anyThis._flushPendingBashMessages?.();
			} catch {
				// best-effort
			}
			try {
				anyThis._flushPendingCustomMessages?.();
			} catch {
				// best-effort
			}
			try {
				await anyThis._handleAgentEvent({
					type: "agent_end",
					messages: this.agent.state.messages.slice(),
				});
			} catch {
				// best-effort
			}
			await anyThis._emitAgentSettled();
		}
	}

	/**
	 * One user→assistant exchange on hermes, synthesized into pi events.
	 */
	private async runHermesTurn(originalText: string): Promise<void> {
		const anyThis = this as any;

		const userMessage: AgentMessage = {
			role: "user",
			content: [{ type: "text", text: originalText }],
			timestamp: Date.now(),
		};
		this.agent.state.messages.push(userMessage);
		await anyThis._handleAgentEvent({ type: "message_start", message: userMessage });
		await anyThis._handleAgentEvent({ type: "message_end", message: userMessage });

		const assistant: StreamingAssistantMessage = {
			role: "assistant",
			content: [],
			timestamp: Date.now(),
		};
		this.agent.state.messages.push(assistant as unknown as AgentMessage);
		await anyThis._handleAgentEvent({
			type: "turn_start",
			turnIndex: anyThis._turnIndex ?? 0,
			timestamp: Date.now(),
		});
		await anyThis._handleAgentEvent({ type: "message_start", message: assistant as unknown as AgentMessage });

		let accumulated = "";
		let result: HermesTurnResult;
		try {
			result = await this.gatewaySafe().prompt(originalText, {
					onDelta: async (delta) => {
						accumulated += delta;
						assistant.content = [{ type: "text", text: accumulated }];
						await anyThis._handleAgentEvent({
							type: "message_update",
							message: assistant as unknown as AgentMessage,
							assistantMessageEvent: { type: "text_delta", delta, isReasoning: false },
							timestamp: Date.now(),
						});
					},
					onToolStart: async (tool) => {
						assistant.content = [...assistant.content, {
							type: "toolCall",
							id: tool.toolCallId,
							name: tool.name,
							arguments: safeArgs(tool.args),
						}];
						await anyThis._handleAgentEvent({
							type: "message_update",
							message: assistant as unknown as AgentMessage,
							assistantMessageEvent: { type: "toolcall_updatesync", toolCallId: tool.toolCallId },
							timestamp: Date.now(),
						});
						anyThis._emit({
							type: "tool_execution_start",
							toolCallId: tool.toolCallId,
							toolName: tool.name,
							args: tool.args ?? {},
							timestamp: Date.now(),
						});
					},
					onToolEnd: async (tool) => {
						assistant.content = assistant.content.map((part: any) =>
							part.type === "toolCall" && part.id === tool.toolCallId
								? {
										type: "toolResult",
										toolCallId: tool.toolCallId,
										content: [{ type: "text", text: tool.resultText ?? "" }],
										isError: tool.isError,
										timestamp: Date.now(),
									}
								: part,
						);
						await anyThis._handleAgentEvent({
							type: "message_update",
							message: assistant as unknown as AgentMessage,
							assistantMessageEvent: { type: "toolcall_updatesync", toolCallId: tool.toolCallId },
							timestamp: Date.now(),
						});
						anyThis._emit({
							type: "tool_execution_end",
							toolCallId: tool.toolCallId,
							toolName: tool.name,
							args: tool.args ?? {},
							result: {
								content: [{ type: "text", text: tool.resultText ?? "" }],
								isError: tool.isError,
							},
							isError: tool.isError,
							timestamp: Date.now(),
						});				},
			});
		} catch (error) {
			// Gateway-level failure (spawn/RPC): surface as an error turn.
			result = {
				status: "error",
				error: error instanceof Error ? error.message : String(error),
			};
		}

		assistant.stopReason =
			result.status === "error" ? "error" : result.status === "interrupted" ? "aborted" : "end_turn";
		if (result.error) {
			assistant.errorMessage = result.error;
		}
		if (result.usage) {
			assistant.usage = mapUsage(result.usage);
		}
		await anyThis._handleAgentEvent({ type: "message_end", message: assistant as unknown as AgentMessage });
		await anyThis._handleAgentEvent({
			type: "turn_end",
			message: assistant as unknown as AgentMessage,
			toolResults: [],
		});
	}
}

function safeArgs(args: unknown): string {
	try {
		const text = typeof args === "string" ? args : JSON.stringify(args ?? {});
		return text.length > 4_000 ? `${text.slice(0, 4_000)}…` : text;
	} catch {
		return String(args ?? "");
	}
}