/**
 * HermesGateway — drives the forked hermes engine's TUI gateway over stdio.
 *
 * Spawns `python -u -m tui_gateway.entry` from the hermes-agent venv and
 * speaks newline-framed JSON-RPC 2.0 (the documented TUI-gateway protocol,
 * see website/docs/developer-guide/programmatic-integration.md in the fork).
 *
 * This is the engine side of the ALFRED hermes bridge: the pi UI keeps its
 * session machinery (events, transcript, extensions, themes) and ONLY the
 * agent turn itself is executed by hermes.
 */

import { spawn, type ChildProcess } from "node:child_process";
import { createInterface } from "node:readline";
import { appendFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/** ALFRED_GW_DEBUG=1 → append raw gateway wire traffic to /tmp/alfred-gw-debug.log */
export function gwDebug(msg: string): void {
	if (process.env.ALFRED_GW_DEBUG !== "1") return;
	try {
		appendFileSync("/tmp/alfred-gw-debug.log", `${new Date().toISOString()} ${msg}\n`);
	} catch {
		// diagnostics only
	}
}

export interface HermesToolStart {
	toolCallId: string;
	name: string;
	args: unknown;
}

export interface HermesToolEnd {
	toolCallId: string;
	name: string;
	args: unknown;
	result: unknown;
	/** Plain-text rendering of the tool result when the gateway provides it. */
	resultText?: string;
	isError: boolean;
}

export interface HermesTurnResult {
	/** Full reasoning text when the engine only reports it on message.complete (non-streaming path). */
	reasoning?: string;
	status: "complete" | "interrupted" | "error";
	error?: string;
	usage?: unknown;
}

export interface HermesPromptHandlers {
	onDelta?: (delta: string) => void | Promise<void>;
	/**
	 * Real model reasoning tokens (hermes reasoning.delta → reasoning_callback).
	 * Streamed per-delta during generation; render as the thinking block.
	 */
	onReasoningDelta?: (delta: string) => void | Promise<void>;
	/**
	 * KawaiiSpinner status text (hermes thinking.delta → thinking_callback,
	 * e.g. "(◔_◔) reflecting..."). NOT model reasoning — the engine only
	 * emits it in quiet mode as an API-call indicator. Surfaces must not
	 * render it as thinking content.
	 */
	onThinkingStatus?: (text: string) => void | Promise<void>;
	onToolStart?: (tool: HermesToolStart) => void | Promise<void>;
	onToolEnd?: (tool: HermesToolEnd) => void | Promise<void>;
}

export function hermesRepoPath(): string {
	return (
		process.env.ALFRED_HERMES_REPO ??
		join(homedir(), ".hermes", "hermes-agent")
	);
}

export function hermesPythonPath(): string {
	return (
		process.env.ALFRED_HERMES_PYTHON ??
		join(hermesRepoPath(), "venv", "bin", "python")
	);
}

const READY_TIMEOUT_MS = 60_000;
const RPC_TIMEOUT_MS = 90_000;
const TURN_TIMEOUT_MS = 30 * 60_000;

function firstText(value: unknown): string | undefined {
	if (typeof value === "string") return value;
	if (Array.isArray(value)) {
		const text = value
			.map((part) => (part && typeof part === "object" ? (part as { text?: unknown }).text : undefined))
			.filter((t): t is string => typeof t === "string")
			.join("");
		return text || undefined;
	}
	return undefined;
}

export class HermesGateway {
	private proc: ChildProcess | undefined;
	private rl: ReturnType<typeof createInterface> | undefined;
	private ready = false;
	private readyWaiters: Array<(error?: Error) => void> = [];
	private sessionId: string | undefined;
	private seq = 0;
	private pendingRpc = new Map<string, { resolve: (v: unknown) => void; reject: (e: Error) => void }>();
	private turn: {
		resolve: (result: HermesTurnResult) => void;
		handlers: HermesPromptHandlers;
	} | undefined;
	private closed = false;

	/** Spawn the gateway (once) and wait for gateway.ready + session.create. */
	async connect(cwd: string): Promise<void> {
		if (this.sessionId) return;
		if (this.closed) throw new Error("hermes gateway was closed");
		if (this.proc) {
			await this.waitReady();
			await this.ensureSession(cwd);
			return;
		}
		const [proc, rl] = this.spawnGateway();
		this.proc = proc;
		this.rl = rl;
		rl.on("line", (line) => this.handleLine(line));
		proc.on("exit", (code, signal) => {
			this.ready = true;
			const error = new Error(
				`hermes gateway exited (code=${code ?? "null"}, signal=${signal ?? "null"})`,
			);
			for (const waiter of this.readyWaiters.splice(0)) waiter(error);
			for (const [, pending] of this.pendingRpc) pending.reject(error);
			this.pendingRpc.clear();
			this.failTurn(error);
		});
		await this.waitReady();
		await this.ensureSession(cwd);
	}

	/** Submit a prompt and resolve when hermes finishes the turn. */
	async prompt(text: string, handlers: HermesPromptHandlers = {}): Promise<HermesTurnResult> {
		await this.connect(process.cwd());
		if (this.turn) {
			throw new Error("a hermes turn is already in flight");
		}
		if (!this.sessionId) throw new Error("hermes session not created");
		return await new Promise<HermesTurnResult>((resolve, reject) => {
			this.turn = { resolve, handlers };
			const timer = setTimeout(() => {
				this.failTurn(new Error("hermes turn timed out"));
			}, TURN_TIMEOUT_MS);
			// Keep the timer from holding the process open after resolution.
			const resolveTurn = (result: HermesTurnResult) => {
				clearTimeout(timer);
				resolve(result);
			};
			const prevResolve = this.turn.resolve;
			this.turn.resolve = (result) => {
				prevResolve(result);
				resolveTurn(result);
			};
			this.rpc("prompt.submit", { session_id: this.sessionId, text })
				.then(() => gwDebug(`prompt.submit acked session=${this.sessionId} chars=${text.length}`))
				.catch((error: unknown) => {
					this.turn = undefined;
					clearTimeout(timer);
					reject(error instanceof Error ? error : new Error(String(error)));
				});
		});
	}

	/** Injection steering (no interrupt) — best-effort. */
	async steer(text: string): Promise<void> {
		if (!this.sessionId) return;
		try {
			await this.rpc("session.steer", { session_id: this.sessionId, text });
		} catch {
			// Steer is a nicety; queue-fallback happens in the session layer.
		}
	}

	/** Abort the in-flight turn. */
	async interrupt(): Promise<void> {
		if (!this.sessionId) return;
		try {
			await this.rpc("session.interrupt", { session_id: this.sessionId });
		} catch {
			// The turn may already be over.
		}
	}

	close(): void {
		if (this.closed) return;
		this.closed = true;
		this.failTurn(new Error("hermes gateway closed"));
		try {
			this.proc?.stdin?.end();
		} catch {
			// already gone
		}
		const timer = setTimeout(() => this.proc?.kill("SIGKILL"), 1500);
		timer.unref();
		this.proc?.on("exit", () => clearTimeout(timer));
	}

	// -- internals ---------------------------------------------------------

	private spawnGateway(): [ChildProcess, ReturnType<typeof createInterface>] {
		const proc = spawn(hermesPythonPath(), ["-u", "-m", "tui_gateway.entry"], {
			cwd: hermesRepoPath(),
			env: gatewayEnv(),
			// stderr must NOT be inherited: the hermes engine logs diagnostics
			// there (e.g. the "Copilot token exchange degraded to RAW token"
			// warning when its token exchange is unreachable), and inherited
			// stderr prints those straight into the pi TUI as stray lines that
			// get wiped on the next redraw. Pipe it instead and drain it — the
			// engine keeps its own on-disk logs (agent.log / crash log).
			stdio: ["pipe", "pipe", "pipe"],
		});
		if (!proc.stdout || !proc.stdin) {
			throw new Error("hermes gateway failed to spawn (no stdio)");
		}
		// Consume the child's stderr so it never blocks on a full pipe.
		proc.stderr?.resume();
		const rl = createInterface({ input: proc.stdout, crlfDelay: Infinity });
		return [proc, rl];
	}

	private waitReady(): Promise<void> {
		if (this.ready) return Promise.resolve();
		return new Promise((resolve, reject) => {
			const waiter = (error?: Error) => {
				clearTimeout(timer);
				if (error) reject(error);
				else resolve();
			};
			const timer = setTimeout(() => {
				const index = this.readyWaiters.indexOf(waiter);
				if (index >= 0) this.readyWaiters.splice(index, 1);
				reject(new Error("hermes gateway did not become ready in time"));
			}, READY_TIMEOUT_MS);
			timer.unref();
			this.readyWaiters.push(waiter);
		});
	}

	private async ensureSession(cwd: string): Promise<void> {
		if (this.sessionId) return;
		const result = (await this.rpc("session.create", { cwd })) as
			| { session_id?: string; sid?: string }
			| undefined;
		const sid = result?.session_id ?? result?.sid;
		if (!sid) {
			throw new Error("hermes session.create returned no session id");
		}
		this.sessionId = sid;
	}

	private rpc(method: string, params: Record<string, unknown>): Promise<unknown> {
		const id = String(++this.seq);
		return new Promise((resolve, reject) => {
			const timer = setTimeout(() => {
				this.pendingRpc.delete(id);
				reject(new Error(`hermes RPC ${method} timed out`));
			}, RPC_TIMEOUT_MS);
			timer.unref();
			this.pendingRpc.set(id, {
				resolve: (value) => {
					clearTimeout(timer);
					resolve(value);
				},
				reject: (error) => {
					clearTimeout(timer);
					reject(error);
				},
			});
			if (!this.proc?.stdin?.writable) {
				this.pendingRpc.delete(id);
				clearTimeout(timer);
				reject(new Error("hermes gateway stdin closed"));
				return;
			}
			this.proc.stdin.write(JSON.stringify({ jsonrpc: "2.0", id, method, params }) + "\n");
		});
	}

	private failTurn(error: Error): void {
		const turn = this.turn;
		this.turn = undefined;
		turn?.resolve({ status: "error", error: error.message });
	}

	private handleLine(line: string): void {
		const raw = line.trim();
		if (!raw) return;
		let msg: { method?: string; params?: any; id?: unknown; error?: { message?: string }; result?: unknown };
		try {
			msg = JSON.parse(raw);
		} catch {
			return;
		}
		if (msg.method === "event") {
			const params = msg.params ?? {};
			gwDebug(`event ${params.type} ${JSON.stringify(params.payload ?? {}).slice(0, 300)}`);
			this.handleEvent(params.type, params.payload ?? {});
			return;
		}
		if (msg.error) {
			const message = String(msg.error.message ?? "rpc error");
			gwDebug(`rpc-error id=${msg.id} ${message}`);
			const holder = msg.id !== undefined ? this.pendingRpc.get(String(msg.id)) : undefined;
			if (holder) {
				this.pendingRpc.delete(String(msg.id));
				holder.reject(new Error(message));
			} else {
				this.failTurn(new Error(message));
			}
			return;
		}
		if (msg.id !== undefined) {
			const holder = this.pendingRpc.get(String(msg.id));
			if (holder) {
				this.pendingRpc.delete(String(msg.id));
				holder.resolve(msg.result);
			}
		}
	}

	private handleEvent(type: string, payload: any): void {
		switch (type) {
			case "gateway.ready":
				this.ready = true;
				for (const waiter of this.readyWaiters.splice(0)) waiter();
				break;
			case "thinking.delta": {
				// KawaiiSpinner status text, not reasoning (see onThinkingStatus).
				const text = firstText(payload?.text) ?? "";
				if (text && this.turn) {
					void this.turn.handlers.onThinkingStatus?.(text);
				}
				break;
			}
			case "reasoning.delta": {
				const text = firstText(payload?.text) ?? "";
				if (text && this.turn) {
					void this.turn.handlers.onReasoningDelta?.(text);
				}
				break;
			}
			case "message.delta": {
				const text = firstText(payload?.text) ?? payload?.rendered ?? "";
				if (text && this.turn) {
					void this.turn.handlers.onDelta?.(text);
				}
				break;
			}
			case "tool.start": {
				if (!this.turn) break;
				void this.turn.handlers.onToolStart?.({
					toolCallId: String(payload?.tool_id ?? `tool-${this.seq}`),
					name: String(payload?.name ?? "tool"),
					args: payload?.args ?? {},
				});
				break;
			}
			case "tool.complete": {
				if (!this.turn) break;
				const resultText =
					payload?.result_text ??
					(typeof payload?.result === "string" ? payload.result : firstText(payload?.summary)) ??
					(payload?.result === undefined ? "" : safeStringify(payload.result, 4_000));
				void this.turn.handlers.onToolEnd?.({
					toolCallId: String(payload?.tool_id ?? ""),
					name: String(payload?.name ?? "tool"),
					args: payload?.args ?? {},
					result: payload?.result,
					resultText,
					isError: Boolean(payload?.result && typeof payload.result === "object" && (payload.result as { error?: unknown }).error) || Boolean(payload?.error),
				});
				break;
			}
			case "message.complete": {
				const status = String(payload?.status ?? "complete");
				const turn = this.turn;
				if (!turn) break;
				this.turn = undefined;
				turn.resolve({
					status: status === "error" ? "error" : status === "interrupted" ? "interrupted" : "complete",
					error: payload?.error ?? (status === "error" ? payload?.text : undefined),
					usage: payload?.usage,
					reasoning: typeof payload?.reasoning === "string" ? payload.reasoning : undefined,
				});
				break;
			}
			case "turn.end": {
				const turn = this.turn;
				if (!turn) break;
				this.turn = undefined;
				turn.resolve({ status: "complete" });
				break;
			}
			case "error": {
				this.failTurn(new Error(String(payload?.text ?? payload?.message ?? "agent error")));
				break;
			}
			default:
				// Everything else (session lifecycle, approvals, clarify, ...)
				// is intentionally ignored by the bridge.
				break;
		}
	}
}

/**
 * Environment for the hermes gateway subprocess.
 *
 * The pi CLI exports PI_* + AI_AGENT vars into its own env; a naive
 * inheritance would leak them into every tool the hermes model runs, and
 * the model would (correctly, from its own evidence) conclude it is the
 * Pi agent. Strip pi-isms; keep HERMES_* (e.g. HERMES_YOLO_MODE) intact.
 */
function gatewayEnv(): NodeJS.ProcessEnv {
	const env: NodeJS.ProcessEnv = Object.create(null) as NodeJS.ProcessEnv;
	for (const [key, value] of Object.entries(process.env)) {
		if (value === undefined) continue;
		if (key.startsWith("PI_")) continue;
		if (key === "AI_AGENT") continue;
		env[key] = value;
	}
	return env;
}

function safeStringify(value: unknown, max = 4_000): string {
	try {
		const text = typeof value === "string" ? value : JSON.stringify(value);
		if (typeof text !== "string") return String(value);
		return text.length > max ? `${text.slice(0, max)}…` : text;
	} catch {
		return String(value);
	}
}