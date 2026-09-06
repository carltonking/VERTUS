/**
 * HubSession — pi-UI-compatible session driven by the VERTUS fleet hub.
 *
 * VERTUS fork. Same seam as HermesSession: subclass AgentSession and swap
 * ONLY the agent turn machinery, so the interactive TUI — block-letter
 * header, theme, components, footer — is untouched. Each prompt is queued
 * on the hub (POST /api/prompt), the reply streams back over the agent's
 * fleet SSE stream (/api/events?agent_id=…), and every event the UI renders
 * (message start/update/end, turn start/end, tool execution) is synthesized
 * through the real AgentSession pipeline, exactly like HermesSession does
 * for the local gateway.
 *
 * What hub mode means for the terminal:
 *   - turns run on the AGENT's gateway (hub-managed, run-store rows, replay)
 *   - the transcript seeds from /api/agents/<id>/messages and resumes with
 *     since=<last seq> (cursor persisted to the agent dir), so closing the
 *     terminal never abandons a running turn — reopen and the turn is still
 *     there, in the store, live on the stream
 *   - steer (mid-turn correction) via POST /api/steer, abort via
 *     POST /api/agents/<id>/cancel (the hub's escalation ladder)
 *   - bot-to-bot traffic for THIS agent arrives on the same stream: runs
 *     the terminal did not start (kind=message handoffs, routines) are
 *     attributed from the run row and rendered, so a bot messaging the
 *     agent reaches the terminal
 *
 * Opt in with VERTUS_ENGINE=hub (see sdk.ts). Local (pi engine) remains the
 * default and is byte-for-byte unchanged; VERTUS_ENGINE=hermes unchanged.
 *
 * Engine selection precedence (all read here, at construction):
 *   --agent flag (main.ts sets VERTUS_AGENT from it) > VERTUS_AGENT env >
 *   "primary". Hub URL: VERTUS_SERVER_URL > http://127.0.0.1:8787. Token:
 *   first line of ~/.vertus/token (same file the one-shot client reads).
 *
 * Degradation is EXPLICIT, not silent: REPL features the hub cannot honor
 * (thinking-level cycling, compaction, session naming, model switching,
 * scoped-model picker) are overridden to post a one-time visible notice
 * into the chat (custom-role message) explaining why, instead of doing
 * nothing. See the degradation table in README/VERTUS_PLAN.
 */

import { readFile, writeFile } from "node:fs/promises";
import { homedir } from "node:os";
import { join } from "node:path";
import { contentText, type Model } from "@earendil-works/pi-ai";
import type { AgentMessage, ThinkingLevel } from "@earendil-works/pi-agent-core";
import { AgentSession, type AgentSessionConfig, type ModelMutationOptions } from "./agent-session.ts";
import type { BashResult } from "./bash-executor.ts";
import { getAgentDir } from "../config.ts";

const DEFAULT_BASE_URL = "http://127.0.0.1:8787";
const HTTP_TIMEOUT_MS = 15_000;
const SEED_LIMIT = 100;

type StreamingAssistantMessage = Omit<AgentMessage, "content"> & {
	role: "assistant";
	content: any[];
	stopReason?: string;
	errorMessage?: string;
	usage?: any;
};

export interface HubTurnResult {
	status: "done" | "error" | "interrupted";
	error?: string;
}

interface LiveRun {
	runId: string;
	assistant: StreamingAssistantMessage;
	accumulated: string;
	attributed: boolean;      // run detail fetched (kind/from_agent)
	prompt: string;
	fromAgent?: string;
	runKind: string;
	lastToolId?: string;      // for chaining tool bubbles from activity
	assistantIndex: number;   // state.messages index once finalized (-1 while live)
}

interface HubWireEvent {
	type: string;
	agent_id?: string;
	run_id?: string | null;
	seq: number;
	ts: number;
	text?: string;
	message?: string;
	steering?: string[];
	follow_up?: string[];
	steers?: string[];
}

function tryContentText(content: any): string {
	try {
		return contentText(content, "");
	} catch {
		if (typeof content === "string") return content;
		return "";
	}
}

/** Zeroed Usage object — pi's footer/stats sum assistant-message usage and an
 *  absent object crashes the TUI render loop (mirrors HermesSession). */
function zeroUsage(): any {
	return {
		input: 0,
		output: 0,
		cacheRead: 0,
		cacheWrite: 0,
		totalTokens: 0,
		cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0, total: 0 },
	};
}

function hubBaseUrl(): string {
	return process.env.VERTUS_SERVER_URL ?? DEFAULT_BASE_URL;
}

async function readToken(): Promise<string> {
	try {
		const raw = await readFile(join(homedir(), ".vertus", "token"), "utf8");
		return raw.trim() || "";
	} catch {
		return "";
	}
}

export class HubSession extends AgentSession {
	private readonly baseUrl: string;
	private token: string;
	private readonly agentId: string;
	private readonly cursorFile: string;

	private cursor = 0;
	private lastCursorWrite = 0;
	private controller: AbortController | undefined;
	private readerLoop: Promise<void> | undefined;
	private reconnectDelayMs = 1_000;
	private seedTask: Promise<void> | undefined;
	private seededRunIds = new Set<string>();

	// The turn this session started and is awaiting its terminal event.
	private pendingTurn: {
		resolve: (r: HubTurnResult) => void;
		assistant: StreamingAssistantMessage;
		accumulated: string;
		runId: string;
		promptInFlight: boolean;
	} | undefined;

	// Runs on the agent's stream that THIS session did not start (bot
	// messages, routines, other clients' prompts) — attributed + rendered.
	private liveRuns = new Map<string, LiveRun>();
	// Runs that already reached a terminal state but whose run-detail fetch
	// is still in flight: the attribution bubble must render even then.
	private finalizedRuns = new Map<string, LiveRun>();
	private runDetailCache = new Map<string, { kind: string; from: string; prompt: string }>();

	// One-time degradation notices (Checkpoint 3 — never silent).
	private readonly notices = new Set<string>();

	constructor(config: AgentSessionConfig) {
		super(config);
		this.baseUrl = hubBaseUrl();
		this.token = "";
		this.agentId = (process.env.VERTUS_AGENT ?? "primary").trim() || "primary";
		this.cursorFile = join(getAgentDir(), "hub-cursor.json");
		this.installEngineOverrides();
		void readToken().then((token) => {
			this.token = token;
			if (!token) {
				this.notice("hub mode: no token at ~/.vertus/token — turns will fail until the hub token is readable");
			}
			this.seedTask = this.seedTranscript();
			this.connectStream();
		});
	}

	// -- seam overrides (mirrors HermesSession.installEngineOverrides) --------

	private installEngineOverrides(): void {
		const anyThis = this as any;

		anyThis._runAgentPrompt = (messages: AgentMessage | AgentMessage[]) =>
			this.runHubPrompt(messages);

		anyThis._queueSteer = async (text: string) => {
			anyThis._steeringMessages.push(text);
			anyThis._emitQueueUpdate();
			try {
				await this.hubSteer(text);
				// Accepted ≠ delivered: the fork injects steers at the next
				// tool batch only, so a generation-only turn may finish with
				// the steer never reaching the model. Say what actually
				// happened — never imply delivery (terminal demo, Phase D).
				this.notice(`steer queued on the hub: it is delivered at the next tool boundary; on a generation-only turn it may never arrive`);
			} catch (error) {
				// Steer refused (turn over / idle): carry it as a follow-up so
				// it is never silently dropped — mirror hermes.
				this.notice(`hub refused steer: ${error instanceof Error ? error.message : String(error)}`);
			}
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

	/** Engine-side abort: the hub's escalation ladder, then settle. */
	override async abort(): Promise<void> {
		this.abortRetry();
		try {
			await this.hubFetch(`/api/agents/${encodeURIComponent(this.agentId)}/cancel`, {
				method: "POST",
			});
		} catch {
			// best-effort; the turn may also end on its own
		}
		await this.waitForIdle();
	}

	override dispose(): void {
		super.dispose();
		// Closing the terminal must NOT abandon a running turn: the hub keeps
		// running it; we only drop our stream subscription. The cursor was
		// persisted as events applied, so reopening resumes from here.
		try {
			this.controller?.abort();
		} catch {
			// best-effort
		}
		this.controller = undefined;
	}

	// -- explicit degradation (Checkpoint 3) ----------------------------------

	override setThinkingLevel(level: ThinkingLevel, options: ModelMutationOptions = {}): void {
		this.noticeOnce("thinking", "hub mode: thinking level is fixed by the agent profile — change it in the Fleet app (bot editor) or PATCH /api/agents");
	}

	override cycleThinkingLevel(options: ModelMutationOptions = {}): ThinkingLevel | undefined {
		this.noticeOnce("thinking", "hub mode: thinking level is fixed by the agent profile — change it in the Fleet app (bot editor) or PATCH /api/agents");
		return undefined;
	}

	override setScopedModels(scopedModels: Array<{ model: Model<any>; thinkingLevel?: ThinkingLevel }>): void {
		this.noticeOnce("models", "hub mode: the model is owned by the agent profile (PATCH /api/agents/<id> {model}); the Ctrl+P picker is disabled");
	}

	override async setModel(model: Model<any>, options: ModelMutationOptions = {}): Promise<void> {
		this.noticeOnce("models", "hub mode: the model is owned by the agent profile (PATCH /api/agents/<id> {model}); it applies on the next turn via the hub's deferred respawn");
	}

	override async cycleModel(
		direction: "forward" | "backward" = "forward",
		options: ModelMutationOptions = {},
	): Promise<any> {
		this.noticeOnce("models", "hub mode: the model is owned by the agent profile — cycling is disabled here; change it in the Fleet app (bot editor) or PATCH /api/agents/<id>");
		return undefined;
	}

	override setSteeringMode(mode: "all" | "one-at-a-time"): void {
		this.noticeOnce("steering-mode", "hub mode: steering is delivered straight to the live turn on the hub — the local steering-mode setting has no effect");
	}

	override setFollowUpMode(mode: "all" | "one-at-a-time"): void {
		this.noticeOnce("followup-mode", "hub mode: follow-ups queue in the terminal and drain as new hub turns — the local follow-up-mode setting has no effect");
	}

	override setAutoCompactionEnabled(enabled: boolean): void {
		this.noticeOnce("compaction", "hub mode: compaction is unavailable — the agent's gateway manages its own context; restart the agent in the Fleet app if a turn is losing the thread");
	}

	override async executeBash(
		command: string,
		onChunk?: (chunk: string) => void,
		options?: { excludeFromContext?: boolean; id?: string },
	): Promise<BashResult> {
		// Still run locally — it is a harmless scratch shell — but say plainly
		// that the hub model never sees the output (the gateway has its own
		// sandbox shell, so recordBashResult context injection is local-only).
		this.noticeOnce("bash", "hub mode: interactive bash output stays local — the hub model cannot see it (the agent's gateway has its own sandbox shell)");
		return super.executeBash(command, onChunk, options);
	}

	override async compact(customInstructions?: string): Promise<any> {
		this.noticeOnce("compaction", "hub mode: compaction is unavailable — the agent's gateway manages its own context; restart the agent in the Fleet app if a turn is losing the thread");
		return undefined;
	}

	override setSessionName(name: string): void {
		this.noticeOnce("session-name", "hub mode: session naming is unavailable — the agent has one identity (its name in the fleet), not per-terminal sessions");
	}

	private notice(text: string): void {
		const anyThis = this as any;
		try {
		// Custom-role messages render as a distinct bubble in the TUI
		// (InteractiveMode's message_start handler); AgentMessage's union
		// lacks the role, so cast like HermesSession casts its streams.
		// Push into agent state like the base _appendCustomMessage does:
		// _handleAgentEvent is a pure dispatcher and never mutates state.
		const message = {
			role: "custom",
			customType: "hub-notice",
			content: [{ type: "text", text }],
			timestamp: Date.now(),
		} as unknown as AgentMessage;
		this.agent.state.messages.push(message);
		anyThis._handleAgentEvent({ type: "message_start", message });
		anyThis._handleAgentEvent({ type: "message_end", message });
		} catch {
			// rendering fallback: console
			console.warn(`[hub-session] ${text}`);
		}
	}

	private noticeOnce(key: string, text: string): void {
		if (this.notices.has(key)) return;
		this.notices.add(key);
		this.notice(text);
	}

	// -- engine machinery -----------------------------------------------------

	private async runHubPrompt(messages: AgentMessage | AgentMessage[]): Promise<void> {
		const anyThis = this as any;
		anyThis._isAgentRunActive = true;
		try {
			const list = Array.isArray(messages) ? messages : [messages];

			await anyThis._handleAgentEvent({ type: "agent_start" });

			// Custom (extension-injected) messages first, then the user turn.
			// Custom entries render locally but are NOT sent to the hub model
			// (the gateway has its own sandbox shell — same as hermes mode).
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
				await this.runHubTurn(text || "(empty prompt)");
			}

			// Drain follow-ups queued while the turn was running (alt+enter).
			let guard = 0;
			while ((anyThis._followUpMessages?.length ?? 0) > 0 && guard++ < 50) {
				const next = anyThis._followUpMessages.shift();
				if (typeof next === "string" && next.trim()) {
					await this.runHubTurn(next.trim());
				}
			}
		} catch {
			// Engine failures surface as an error bubble inside runHubTurn.
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

	/** One user→assistant exchange on the hub, synthesized into pi events. */
	private async runHubTurn(originalText: string): Promise<void> {
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

		const result = await new Promise<HubTurnResult>((resolve) => {
			this.pendingTurn = {
				resolve,
				assistant,
				accumulated: "",
				runId: "",
				promptInFlight: true,
			};
			void this.hubPrompt(originalText).then(
				(runId) => {
					if (this.pendingTurn) this.pendingTurn.runId = runId;
					if (this.pendingTurn) this.pendingTurn.promptInFlight = false;
				},
				(error) => {
					// POST failed outright: no run exists — resolve as error.
					if (this.pendingTurn) {
						const p = this.pendingTurn;
						this.pendingTurn = undefined;
						p.resolve({ status: "error", error: error instanceof Error ? error.message : String(error) });
					}
				},
			);
		});
		this.pendingTurn = undefined;

		assistant.stopReason =
			result.status === "error" ? "error"
			: result.status === "interrupted" ? "aborted"
			: "end_turn";
		if (result.error) {
			assistant.errorMessage = result.error;
		}
		if (result.status === "error" && !assistant.content.length) {
			// Nothing streamed: put the failure text in the bubble so the
			// error is visible, not an empty assistant turn.
			assistant.content = [{ type: "text", text: `⚠️ ${result.error}` }];
		}
		// Zeroed usage: pi's footer and stats sum assistant-message usage;
		// an absent object freezes the TUI after an error turn.
		assistant.usage = zeroUsage();
		await anyThis._handleAgentEvent({ type: "message_end", message: assistant as unknown as AgentMessage });
		await anyThis._handleAgentEvent({
			type: "turn_end",
			message: assistant as unknown as AgentMessage,
			toolResults: [],
		});
	}

	// -- hub HTTP -------------------------------------------------------------

	private async hubFetch(path: string, init: RequestInit = {}): Promise<Response> {
		const res = await fetch(`${this.baseUrl}${path}`, {
			...init,
			headers: {
				Authorization: `Bearer ${this.token}`,
				"Content-Type": "application/json",
				"X-Vertus-Client": "terminal",
				...(init.headers ?? {}),
			},
			signal: init.signal ?? AbortSignal.timeout(HTTP_TIMEOUT_MS),
		});
		if (!res.ok) {
		let detail = "";
		try {
			const body = (await res.json()) as Record<string, unknown>;
			detail = typeof body?.error === "string" ? body.error : "";
		} catch {
			// non-JSON error body
		}
			throw new Error(`hub ${res.status}${detail ? `: ${detail}` : ""}`);
		}
		return res;
	}

	private async hubPrompt(text: string): Promise<string> {
		const res = await this.hubFetch("/api/prompt", {
			method: "POST",
			body: JSON.stringify({ agent_id: this.agentId, text }),
		});
		const body = (await res.json()) as { run_id?: string };
		if (!body.run_id) throw new Error("hub prompt accepted but returned no run_id");
		return body.run_id;
	}

	/** POST /api/steer — renamed (hubSteer) so it never collides with the
	 *  base class's public steer()/prompt() surface. */
	private async hubSteer(text: string): Promise<void> {
		await this.hubFetch("/api/steer", {
			method: "POST",
			body: JSON.stringify({ agent_id: this.agentId, text }),
		});
	}

	private async runDetail(runId: string): Promise<{ kind: string; from: string; prompt: string }> {
		const cached = this.runDetailCache.get(runId);
		if (cached) return cached;
		try {
			const res = await this.hubFetch(`/api/runs/${encodeURIComponent(runId)}`);
			const body = (await res.json()) as {
				run_kind?: string;
				from_agent?: string;
				prompt?: string;
			};
			const detail = {
				kind: body.run_kind ?? "user",
				from: body.from_agent ?? "",
				prompt: body.prompt ?? "",
			};
			this.runDetailCache.set(runId, detail);
			return detail;
		} catch {
			return { kind: "user", from: "", prompt: "" };
		}
	}

	// -- transcript seeding + SSE stream ---------------------------------------

	private async loadCursor(): Promise<number> {
		try {
			const raw = await readFile(this.cursorFile, "utf8");
			const parsed = JSON.parse(raw);
			return Number(parsed.seq) || 0;
		} catch {
			return 0;
		}
	}

	private persistCursor(seq: number): void {
		this.cursor = Math.max(this.cursor, seq);
		const now = Date.now();
		if (now - this.lastCursorWrite < 1_000) return;
		this.lastCursorWrite = now;
		// Best-effort, throttled: a stale cursor only costs a replay.
		void writeFile(this.cursorFile, JSON.stringify({ seq: this.cursor })).catch(() => {});
	}

	/** Seed the transcript from folded history, then open the live stream. */
	private async seedTranscript(): Promise<void> {
		try {
			const res = await this.hubFetch(
				`/api/agents/${encodeURIComponent(this.agentId)}/messages?limit=${SEED_LIMIT}`,
			);
			const body = (await res.json()) as { messages?: Array<{ run_id?: string; role: string; text: string }> };
			const rows = body.messages ?? [];
			this.cursor = await this.loadCursor();
			// Newest-first from the hub; render oldest→newest.
			for (const row of rows.slice().reverse()) {
				if (row.run_id) this.seededRunIds.add(row.run_id);
				await this.synthesizeHistoryMessage(row.role, row.text);
			}
			this.emitHistoryReady();
		} catch {
			// Hub down at start: the stream retry loop will keep trying; the
			// first prompt surfaces the error visibly.
		}
	}

	private async synthesizeHistoryMessage(role: string, text: string): Promise<void> {
		const anyThis = this as any;
		const message = {
			role: role === "user" ? ("user" as const) : ("assistant" as const),
			content: [{ type: "text", text }],
			timestamp: Date.now(),
		} as AgentMessage;
		this.agent.state.messages.push(message);
		await anyThis._handleAgentEvent({ type: "message_start", message });
		await anyThis._handleAgentEvent({ type: "message_end", message });
	}

	private emitHistoryReady(): void {
		const anyThis = this as any;
		try {
			anyThis._handleAgentEvent({ type: "queue_update", steering: [], followUp: [] });
		} catch {
			// best-effort
		}
	}

	/** Reset the reconnect backoff after a healthy stream open. */
	private resetBackoff(): void {
		this.reconnectDelayMs = 1_000;
	}

	private connectStream(): void {
		if (this.controller) return;
		this.controller = new AbortController();
		this.readerLoop = this.readStream(this.controller.signal);
	}

	private async readStream(signal: AbortSignal): Promise<void> {
		for (;;) {
			if (signal.aborted) return;
			try {
				const res = await fetch(
					`${this.baseUrl}/api/events?agent_id=${encodeURIComponent(this.agentId)}&since=${this.cursor}`,
					{ headers: { Authorization: `Bearer ${this.token}` }, signal },
				);
				if (!res.ok || res.body === null) throw new Error(`stream ${res.status}`);
				this.resetBackoff();
				const reader = res.body.getReader();
				const decoder = new TextDecoder();
				let buffer = "";
				for (;;) {
					const { done, value } = await reader.read();
					if (done) break;
					buffer += decoder.decode(value, { stream: true });
					let newline: number;
					while ((newline = buffer.indexOf("\n")) >= 0) {
						const line = buffer.slice(0, newline).trim();
						buffer = buffer.slice(newline + 1);
						if (!line.startsWith("data: ")) continue;
						try {
							this.applyEvent(JSON.parse(line.slice(6)) as HubWireEvent);
						} catch {
							// one malformed frame is not a stream failure
						}
					}
				}
				throw new Error("stream ended");
			} catch (error) {
				if (signal.aborted) return;
				// Backoff reconnect; since=cursor means the store replays
				// exactly what we missed (events are durable before fanout).
				await new Promise((r) => setTimeout(r, this.reconnectDelayMs));
				this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, 30_000);
			}
		}
	}

	// -- wire events → AgentSessionEvent ---------------------------------------

	private applyEvent(event: HubWireEvent): void {
		this.persistCursor(event.seq);
		if (event.run_id == null) {
			// Run-less events: steer/queue_update traffic for this agent.
			if (event.type === "steer" && event.text) {
				const anyThis = this as any;
				anyThis._steeringMessages.push(event.text);
				anyThis._emitQueueUpdate();
			} else if (event.type === "queue_update") {
				const anyThis = this as any;
				anyThis._steeringMessages = [...(event.steering ?? [])];
				anyThis._followUpMessages = [...(event.follow_up ?? [])];
				anyThis._emitQueueUpdate();
			}
			return;
		}
		const runId = event.run_id;

		// The run we started ourselves?
		if (this.pendingTurn && this.pendingTurn.runId === runId) {
			this.applyToTurn(event);
			return;
		}
		// A run started while our prompt POST was in flight (adopt it — the
		// only source of a brand-new run at that moment is our own prompt).
		if (this.pendingTurn && this.pendingTurn.promptInFlight && !this.pendingTurn.runId) {
			this.pendingTurn.runId = runId;
			this.pendingTurn.promptInFlight = false;
			this.applyToTurn(event);
			return;
		}
		// Seeded history: replay events for already-rendered runs are skipped
		// (the folded messages are authoritative; deltas would duplicate).
		if (this.seededRunIds.has(runId)) return;
		this.applyToExternalRun(runId, event);
	}

	/** Events for the turn this session started. */
	private applyToTurn(event: HubWireEvent): void {
		const p = this.pendingTurn;
		if (!p) return;
		const anyThis = this as any;
		switch (event.type) {
			case "text":
				if (!event.text) break;
				p.accumulated += event.text;
				p.assistant.content = [{ type: "text", text: p.accumulated }];
				anyThis._handleAgentEvent({
					type: "message_update",
					message: p.assistant,
					assistantMessageEvent: { type: "text_delta", delta: event.text, isReasoning: false },
					timestamp: Date.now(),
				});
				break;
			case "activity": {
				const toolName = (event.text ?? "tool").replace(/^running\s+/, "").replace(/…$/, "").trim() || "tool";
				const toolCallId = `hub-${event.seq}`;
				anyThis._handleAgentEvent({
					type: "tool_execution_start",
					toolCallId,
					toolName,
					args: {},
					timestamp: Date.now(),
				});
				// The hub wire carries no tool results — close the bubble
				// immediately with the status text as its result so no tool
				// bubble hangs "running…" forever.
				anyThis._handleAgentEvent({
					type: "tool_execution_end",
					toolCallId,
					toolName,
					args: {},
					result: { content: [{ type: "text", text: event.text ?? "" }], isError: false },
					isError: false,
					timestamp: Date.now(),
				});
				break;
			}
			case "done":
				p.resolve({ status: "done" });
				break;
			case "error":
				p.resolve({ status: "error", error: event.message ?? "hub run failed" });
				break;			case "cancelled":
				p.resolve({ status: "interrupted", error: "cancelled" });
				break;
			case "steer_undelivered":
				// The hub inferred the turn ended without a tool boundary after
				// our steer: it never reached the model. Make that visible
				// instead of letting the user assume it was followed.
				this.notice(`steer was NOT delivered: the turn ended before the next tool boundary (${(event.steers ?? []).join("; ") || ""})`);
				break;
			default:
				break;
			}
		}

	/** Events for a run this session did NOT start (bot message, routine,
	 *  another client's prompt) — attribute from the run row and render. */
	private applyToExternalRun(runId: string, event: HubWireEvent): void {
		const anyThis = this as any;
		let run = this.liveRuns.get(runId);
		if (!run) {
			run = {
				runId,
				assistant: { role: "assistant", content: [], timestamp: Date.now() },
				accumulated: "",
				attributed: false,
				prompt: "",
				runKind: "user",
				assistantIndex: -1,
			};
			this.liveRuns.set(runId, run);
			void this.runDetail(runId).then((detail) => {
				// The run may already have finished (done/error/cancelled
				// raced the detail fetch) — attribution must still render.
				const live = this.liveRuns.get(runId) ?? this.finalizedRuns.get(runId);
				if (!live) return;
				live.attributed = true;
				live.prompt = detail.prompt;
				live.fromAgent = detail.from;
				live.runKind = detail.kind;
				this.renderExternalBubble(live);
			});
		}
		switch (event.type) {
			case "text":
				if (!event.text) break;
				run.accumulated += event.text;
				run.assistant.content = [{ type: "text", text: run.accumulated }];
				anyThis._handleAgentEvent({
					type: "message_update",
					message: run.assistant,
					assistantMessageEvent: { type: "text_delta", delta: event.text, isReasoning: false },
					timestamp: Date.now(),
				});
				break;
			case "done":
				this.finalizeExternalRun(run, "end_turn");
				break;
			case "error":
				run.assistant.errorMessage = event.message ?? "hub run failed";
				if (!run.assistant.content.length) {
					run.assistant.content = [{ type: "text", text: `⚠️ ${run.assistant.errorMessage}` }];
				}
				this.finalizeExternalRun(run, "error");
				break;
			case "cancelled":
				this.finalizeExternalRun(run, "aborted");
				break;
			default:
				break;
		}
	}

	private renderExternalBubble(run: LiveRun): void {
		const anyThis = this as any;
		if (!run.attributed) return;
		let label: string;
		if (run.runKind === "message" && run.fromAgent) {
			label = `⟨message from ${run.fromAgent}⟩ ${run.prompt}`;
		} else if (run.runKind === "handoff" && run.fromAgent) {
			label = `⟨handoff from ${run.fromAgent}⟩ ${run.prompt}`;
		} else if (run.runKind === "routine") {
			label = `⟨routine⟩ ${run.prompt}`;
		} else {
			label = run.prompt;
		}
		if (!label.trim()) return;
		const message: AgentMessage = {
			role: "user",
			content: [{ type: "text", text: label }],
			timestamp: Date.now(),
		};
		if (run.assistantIndex >= 0) {
			// Attribution landed after the turn ended: insert the bubble
			// right before the assistant reply so the transcript reads
			// bubble → reply, not the reverse.
			this.agent.state.messages.splice(run.assistantIndex, 0, message);
		} else {
			this.agent.state.messages.push(message);
		}
		this.finalizedRuns.delete(run.runId);
		anyThis._handleAgentEvent({ type: "message_start", message });
		anyThis._handleAgentEvent({ type: "message_end", message });
	}

	private finalizeExternalRun(run: LiveRun, stopReason: string): void {
		const anyThis = this as any;
		if (!run.assistant.content.length && stopReason !== "error") {
			run.assistant.content = [{ type: "text", text: "(turn produced no text)" }];
		}
		run.assistant.stopReason = stopReason;
		run.assistant.timestamp = Date.now();
		run.assistant.usage = zeroUsage();
		// The wire stream only ever carried deltas on a private object — the
		// transcript must contain the reply, so push it into state before
		// message_end (same pattern as runHubTurn).
		this.agent.state.messages.push(run.assistant as unknown as AgentMessage);
		run.assistantIndex = this.agent.state.messages.length - 1;
		anyThis._handleAgentEvent({ type: "message_end", message: run.assistant });
		anyThis._handleAgentEvent({
			type: "turn_end",
			message: run.assistant,
			toolResults: [],
		});
		// Keep the run for a possibly in-flight attribution fetch; the
		// bubble render deletes it from finalizedRuns.
		this.liveRuns.delete(run.runId);
		this.finalizedRuns.set(run.runId, run);
	}
}