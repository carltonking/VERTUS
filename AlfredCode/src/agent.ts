/**
 * agent.ts — the ACP (Agent Client Protocol) subprocess client.
 *
 * Speaks the same wire protocol HermesSession.swift uses, verified live
 * against the opencode fork and freebuff:
 *
 *   * launch   `<binary> acp` with cwd = the project folder
 *   * framing  newline-delimited JSON-RPC 2.0 on stdout; stderr is logs only
 *   * startup  initialize → session/new (cwd + optional mcpServers)
 *   * turns    session/prompt resolves ONLY when the turn ends; streaming
 *              text/tool/usage arrives out-of-band as session/update
 *              notifications that must be consumed concurrently
 *   * calls    session/request_permission is a server→client REQUEST; the
 *              turn deadlocks until answered
 */

import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

// ---------------------------------------------------------------------------
// Events
// ---------------------------------------------------------------------------

export type AgentEvent =
  | { kind: "text"; text: string }
  | { kind: "thought"; text: string }
  | { kind: "toolStart"; id: string; title: string; toolKind: string }
  | { kind: "toolUpdate"; id: string; status?: string; title?: string }
  | { kind: "usage"; used: number; size: number }
  | { kind: "finished"; stopReason: string }
  | { kind: "failed"; message: string }
  | { kind: "log"; line: string }
  | { kind: "permission"; requestId: unknown; title: string; options: PermissionOption[]; respond: (optionId: string | null) => void };

export interface PermissionOption {
  optionId: string;
  kind: string;
  title?: string;
}

export interface AgentInfo {
  serverName: string;
  serverVersion: string;
  model: string;
  sessionId: string;
  provider: string;
}

export interface AgentOptions {
  binary: string;
  args: string[];
  cwd: string;
  env?: Record<string, string>;
  /** Agent display name, e.g. "freebuff" or "opencode". */
  name: string;
  /** Turn deadline in seconds; a turn that goes silent this long is torn
   *  down. The spec's 5-minute default, configurable. */
  turnTimeout?: number;
  onEvent: (ev: AgentEvent) => void;
}

const DEFAULT_TURN_TIMEOUT = 300;

// ---------------------------------------------------------------------------
// Launch resolution
// ---------------------------------------------------------------------------

export interface Launcher {
  binary: string;
  args: string[];
  name: string;
}

/** Resolve which agent to launch: explicit flag/env wins, then freebuff, then
 *  opencode. Mirrors the resolution order in HermesSession. */
export function resolveLauncher(force?: string): Launcher {
  const forced = force ?? process.env.ALFRED_AGENT;
  if (forced && forced !== "auto" && forced !== "opencode" && forced !== "freebuff") {
    return { binary: forced, args: ["acp"], name: forced };
  }
  if (forced === "freebuff") {
    return { binary: process.env.ALFRED_FREEBUFF_BIN ?? "freebuff", args: ["acp"], name: "freebuff" };
  }
  // opencode (the fork) is the default: the freebuff CLI currently exposes no
  // `acp` subcommand (only `login`), so a freebuff default would fail out of
  // the box. Mirrors HermesSession: env bin wins, then the fork's dev path
  // (verified live), then a bare PATH lookup as the last resort.
  if (process.env.ALFRED_OPENCODE_BIN) return { binary: process.env.ALFRED_OPENCODE_BIN, args: ["acp"], name: "opencode" };
  const home = homedir();
  const forkRepo = process.env.ALFRED_OPENCODE_REPO ?? join(home, "02 - REPOS", "opencode");
  const forkEntry = join(forkRepo, "packages", "opencode", "src", "index.ts");
  if (existsSync(forkEntry)) {
    const bun = process.env.ALFRED_OPENCODE_BUN ?? join(home, ".bun", "bin", "bun");
    if (existsSync(bun)) {
      return {
        binary: bun,
        args: ["run", "--cwd", join(forkRepo, "packages", "opencode"), "--conditions=browser", "src/index.ts", "acp"],
        name: "opencode",
      };
    }
  }
  if (process.env.ALFRED_FREEBUFF_BIN) return { binary: process.env.ALFRED_FREEBUFF_BIN, args: ["acp"], name: "freebuff" };
  return { binary: "opencode", args: ["acp"], name: "opencode" };
}

/** The child inherits our env plus the usual user bins on PATH, so agents
 *  find node/bun/opencode even when the TUI was launched from a bare shell. */
function childEnv(name: string): Record<string, string> {
  const env: Record<string, string> = { ...process.env as Record<string, string> };
  const home = homedir();
  const extra = `${home}/.local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin`;
  env["PATH"] = `${extra}:${env["PATH"] ?? "/usr/bin:/bin"}`;

  if (name === "opencode" && !env["OPENCODE_CONFIG_CONTENT"]) {
    // Same task posture Hermes injects: mutating tools allowed, a short
    // destructive deny-list, and a free-tier model so the agent boots with a
    // working brain. The user can override with their own config.
    env["OPENCODE_CONFIG_CONTENT"] = JSON.stringify({
      model: "opencode/deepseek-v4-flash-free",
      permission: {
        bash: {
          "rm -rf /": "deny", "rm -rf /*": "deny", "rm -rf ~": "deny",
          "sudo *": "deny", "sudo rm *": "deny",
          "git push --force*": "deny", "git push -f*": "deny",
          "git reset --hard*": "deny", "git clean -fdx*": "deny",
          "curl * | sh": "deny", "curl * | bash": "deny",
          "wget * | sh": "deny", "wget * | bash": "deny",
          "shutdown*": "deny", "reboot*": "deny",
        },
        read: "allow", edit: "allow", glob: "allow", grep: "allow",
        list: "allow", webfetch: "allow", websearch: "allow",
      },
    });
  }
  return env;
}

/** ~/.alfred/agent-servers.json — external MCP capability bridges declared by
 *  the Alfred install (odysseus memory/rag, omp, openswarm, …). The macOS app
 *  injects them into every Hermes session; the TUI deliberately does NOT by
 *  default: several of these servers stall startup with connection retries,
 *  and a coding session shouldn't depend on Alfred's assistant bridges.
 *  Opt in with ALFRED_MCP_SERVERS=1. */
function externalMCPServers(): Array<Record<string, unknown>> {
  if (!process.env.ALFRED_MCP_SERVERS) return [];
  const path = join(homedir(), ".alfred", "agent-servers.json");
  try {
    if (!existsSync(path)) return [];
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { servers?: Array<{ name?: string; command?: string; args?: string[]; env?: Array<{ name: string; value: string }> }> };
    return (parsed.servers ?? []).flatMap((s) => {
      if (!s.name || !s.command) return [];
      // The fork's McpServerStdio schema requires every field to be present
      // (an omitted `headers` rejects the whole session/new with -32602), so
      // always emit the full shape with empty arrays.
      return [{
        name: s.name,
        command: s.command,
        args: s.args ?? [],
        env: (s.env ?? []).map(({ name, value }) => ({ name, value })),
        headers: [],
      }];
    });
  } catch {
    return [];
  }
}

// ---------------------------------------------------------------------------
// The client
// ---------------------------------------------------------------------------

export class AgentClient {
  readonly name: string;

  /** Swappable event sink — the UI installs its own after construction. */
  onEvent: (ev: AgentEvent) => void;

  private child: ChildProcessWithoutNullStreams | null = null;
  private stdinOpen = false;
  private sessionId: string | null = null;
  private nextID = 0;
  private pending = new Map<number, { resolve: (v: unknown) => void; reject: (e: Error) => void; timer: NodeJS.Timeout }>();
  private readBuffer = "";
  private turnActive = false;
  private turnTimer: NodeJS.Timeout | null = null;
  private stoppedByUser = false;

  info: AgentInfo | null = null;
  lastUsage = { used: 0, size: 0, cost: 0 };

  private readonly opts: AgentOptions;
  private readonly launcher: Launcher;

  constructor(launcher: Launcher, opts: AgentOptions) {
    this.launcher = launcher;
    this.opts = opts;
    this.name = opts.name;
    this.onEvent = opts.onEvent;
  }

  get isRunning(): boolean {
    return this.child !== null && !this.child.killed;
  }

  get isTurnActive(): boolean {
    return this.turnActive;
  }

  private emit(ev: AgentEvent) {
    try {
      this.onEvent(ev);
    } catch {
      /* never let a renderer bug kill the protocol pump */
    }
  }

  // -- lifecycle -----------------------------------------------------------

  /** Spawn the agent and complete initialize + session/new. */
  async start(): Promise<AgentInfo> {
    if (this.child) return this.info as AgentInfo;

    const child = spawn(this.launcher.binary, this.launcher.args, {
      cwd: this.opts.cwd,
      env: childEnv(this.launcher.name),
      stdio: ["pipe", "pipe", "pipe"],
    });

    this.child = child;
    this.stdinOpen = true;
    this.stoppedByUser = false;
    this.attachStdinGuard();

    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.ingest(chunk));
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk: string) => this.ingestLog(chunk));
    child.on("error", (err: NodeJS.ErrnoException) => {
      if (err.code === "ENOENT") {
        this.failAll(`Agent binary "${this.launcher.binary}" not found. Install it on PATH or set ALFRED_AGENT.`);
      } else {
        this.failAll(`Agent process error: ${err.message}`);
      }
      this.child = null;
      this.stdinOpen = false;
    });
    child.on("close", (code, signal) => {
      this.stdinOpen = false;
      if (this.turnActive && !this.stoppedByUser) {
        this.emit({ kind: "failed", message: `Agent exited unexpectedly (${signal ?? `code ${code ?? "?"}`})` });
      }
      this.turnActive = false;
      this.clearTurnTimer();
      this.child = null;
    });

    let serverInfo: Record<string, unknown> = {};
    let provider = "";
    let model = "";

    // initialize — advertise no filesystem capability; Alfred reaches the Mac
    // through its own tools, not ACP's fs hooks (same as Hermes).
    try {
      const init = await this.request("initialize", {
        protocolVersion: 1,
        clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
        clientInfo: { name: "alfred-code", version: "1.0.0" },
      }) as Record<string, unknown>;
      serverInfo = (init["serverInfo"] as Record<string, unknown>) ?? {};
      if (typeof init["model"] === "string") model = init["model"];
      if (typeof init["provider"] === "string") provider = init["provider"];
    } catch (err) {
      // Some ACP servers only accept the string protocol version
      // ("2025-06-18" style). Retry once before giving up.
      const msg = err instanceof Error ? err.message : String(err);
      if (/protocol|version/i.test(msg)) {
        const init = await this.request("initialize", {
          protocolVersion: "2025-06-18",
          clientCapabilities: { fs: { readTextFile: false, writeTextFile: false } },
          clientInfo: { name: "alfred-code", version: "1.0.0" },
        }) as Record<string, unknown>;
        serverInfo = (init["serverInfo"] as Record<string, unknown>) ?? {};
        if (typeof init["model"] === "string") model = init["model"];
        if (typeof init["provider"] === "string") provider = init["provider"];
      } else {
        throw err;
      }
    }

    const session = await this.request("session/new", {
      cwd: this.opts.cwd,
      mcpServers: externalMCPServers(),
    }) as Record<string, unknown>;
    const sessionId = session["sessionId"];
    if (typeof sessionId !== "string" || !sessionId) {
      throw new Error("session/new returned no sessionId");
    }
    this.sessionId = sessionId;

    this.info = {
      serverName: (serverInfo["name"] as string) ?? this.launcher.name,
      serverVersion: (serverInfo["version"] as string) ?? "",
      model: model || (session["model"] as string) || "",
      provider: provider || (session["provider"] as string) || "",
      sessionId,
    };
    return this.info;
  }

  /** Kill the subprocess. Safe to call repeatedly. */
  stop() {
    this.stoppedByUser = true;
    this.turnActive = false;
    this.clearTurnTimer();
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new Error("Agent stopped"));
    }
    this.pending.clear();
    if (this.child) {
      this.child.stdin.end();
      this.child.kill();
      this.child = null;
    }
    this.stdinOpen = false;
    this.sessionId = null;
  }

  // -- turns ---------------------------------------------------------------

  /** Send a prompt and stream the turn. Resolves when the turn finishes or
   *  fails. Only one turn at a time. */
  async prompt(text: string, planMode = false): Promise<string> {
    if (this.turnActive) throw new Error("A turn is already running");
    if (!this.child) await this.start();
    if (!this.sessionId) throw new Error("No active session");

    this.turnActive = true;
    this.stoppedByUser = false;
    this.armTurnTimer();

    const body = planMode
      ? `[PLAN MODE — read-only. Do NOT create, edit, or delete files; do not run mutating commands. Analyze, propose and report only.]\n\n${text}`
      : text;

    try {
      const result = await this.request("session/prompt", {
        sessionId: this.sessionId,
        prompt: [{ type: "text", text: body }],
      }, (this.opts.turnTimeout ?? DEFAULT_TURN_TIMEOUT) * 1000);
      const stop = (result as Record<string, unknown>)["stopReason"] as string | undefined;
      this.emit({ kind: "finished", stopReason: stop ?? "end_turn" });
      return stop ?? "end_turn";
    } catch (err) {
      if (this.stoppedByUser) {
        this.emit({ kind: "failed", message: "Interrupted by user" });
        return "interrupted";
      }
      this.emit({ kind: "failed", message: err instanceof Error ? err.message : String(err) });
      return "error";
    } finally {
      this.turnActive = false;
      this.clearTurnTimer();
    }
  }

  /** Interrupt the running turn (Esc). opencode and friends implement
   *  session/cancel; if the agent doesn't stop within the grace period we
   *  escalate to SIGINT, then SIGKILL. */
  cancel() {
    if (!this.child || !this.turnActive) return;
    this.stoppedByUser = true;
    this.emit({ kind: "failed", message: "Interrupted by user" });
    this.notify("session/cancel", { sessionId: this.sessionId });
    const child = this.child;
    setTimeout(() => {
      if (child && !child.killed && this.turnActive) {
        child.kill("SIGINT");
        setTimeout(() => {
          if (child && !child.killed) child.kill("SIGKILL");
        }, 4000);
      }
    }, 1500);
  }

  // -- JSON-RPC plumbing ---------------------------------------------------

  private request(method: string, params: Record<string, unknown>, timeoutMs = 30_000): Promise<unknown> {
    const id = ++this.nextID;
    return new Promise<unknown>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`Request "${method}" timed out`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      if (!this.writeFrame({ jsonrpc: "2.0", id, method, params })) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(new Error("Agent stdin is closed"));
      }
    });
  }

  private notify(method: string, params: Record<string, unknown>) {
    this.writeFrame({ jsonrpc: "2.0", method, params });
  }

  private writeFrame(frame: Record<string, unknown>): boolean {
    if (!this.child || !this.stdinOpen) return false;
    try {
      this.child.stdin.write(JSON.stringify(frame) + "\n");
      return true;
    } catch {
      return false;
    }
  }

  private attachStdinGuard() {
    if (!this.child) return;
    // A dying agent can EPIPE mid-write; without this the 'error' event is
    // unhandled and takes down the whole TUI. Mark stdin closed instead.
    this.child.stdin.on("error", () => {
      this.stdinOpen = false;
    });
  }

  private ingest(chunk: string) {
    this.readBuffer += chunk;
    let nl: number;
    while ((nl = this.readBuffer.indexOf("\n")) >= 0) {
      const line = this.readBuffer.slice(0, nl);
      this.readBuffer = this.readBuffer.slice(nl + 1);
      if (!line.trim()) continue;
      let frame: Record<string, unknown>;
      try {
        frame = JSON.parse(line) as Record<string, unknown>;
      } catch {
        // A few agents print startup banners to stdout; surface them as logs
        // rather than crashing the parser.
        this.emit({ kind: "log", line: line.slice(0, 200) });
        continue;
      }
      this.handleFrame(frame);
    }
  }

  private ingestLog(chunk: string) {
    for (const line of chunk.split("\n")) {
      const t = line.trim();
      if (!t) continue;
      if (/\b(ERROR|FATAL|Traceback|CRITICAL)\b/.test(t) || /error/i.test(t)) {
        this.emit({ kind: "log", line: t.slice(0, 200) });
      }
    }
  }

  private handleFrame(frame: Record<string, unknown>) {
    const method = typeof frame["method"] === "string" ? frame["method"] : undefined;

    // Server → client request: must be answered or the turn deadlocks.
    if (method && frame["id"] !== undefined) {
      this.handleServerRequest(method, frame);
      return;
    }

    // Notification.
    if (method) {
      if (method === "session/update") {
        const params = frame["params"] as Record<string, unknown> | undefined;
        const update = params?.["update"] as Record<string, unknown> | undefined;
        if (update) this.handleUpdate(update);
      }
      return;
    }

    // Response to one of ours.
    const id = frame["id"];
    if (typeof id === "number") {
      const entry = this.pending.get(id);
      if (entry) {
        this.pending.delete(id);
        clearTimeout(entry.timer);
        if (frame["error"] !== undefined) {
          const err = frame["error"] as Record<string, unknown>;
          entry.reject(new Error(typeof err["message"] === "string" ? err["message"] : "RPC error"));
        } else {
          entry.resolve(frame["result"]);
        }
      }
    }
  }

  private handleServerRequest(method: string, frame: Record<string, unknown>) {
    const id = frame["id"];

    if (!method.endsWith("request_permission")) {
      // Unknown client method — answer with an empty result so the agent is
      // never left blocking on us.
      this.writeFrame({ jsonrpc: "2.0", id, result: {} });
      return;
    }

    const params = frame["params"] as Record<string, unknown> | undefined;
    const rawOptions = (params?.["options"] as Array<Record<string, unknown>> | undefined) ?? [];
    const options: PermissionOption[] = rawOptions.flatMap((o) => {
      if (typeof o["optionId"] !== "string") return [];
      return [{ optionId: o["optionId"], kind: String(o["kind"] ?? ""), title: typeof o["title"] === "string" ? o["title"] : undefined }];
    });
    const title = typeof params?.["title"] === "string" ? params["title"] : "Alfred wants to run an action";

    this.emit({
      kind: "permission",
      requestId: id,
      title,
      options,
      respond: (optionId: string | null) => {
        if (optionId) {
          this.writeFrame({ jsonrpc: "2.0", id, result: { outcome: { outcome: "selected", optionId } } });
        } else {
          this.writeFrame({ jsonrpc: "2.0", id, result: { outcome: { outcome: "cancelled" } } });
        }
      },
    });
  }

  private handleUpdate(update: Record<string, unknown>) {
    const kind = update["sessionUpdate"];
    switch (kind) {
      case "agent_message_chunk": {
        const t = textIn(update);
        if (t) this.emit({ kind: "text", text: t });
        break;
      }
      case "agent_thought_chunk": {
        const t = textIn(update);
        if (t) this.emit({ kind: "thought", text: t });
        break;
      }
      case "tool_call": {
        const id = update["toolCallId"];
        if (typeof id !== "string") break;
        this.emit({
          kind: "toolStart",
          id,
          title: typeof update["title"] === "string" ? update["title"] : "Working…",
          toolKind: typeof update["kind"] === "string" ? update["kind"] : "",
        });
        break;
      }
      case "tool_call_update": {
        const id = update["toolCallId"];
        if (typeof id !== "string") break;
        this.emit({
          kind: "toolUpdate",
          id,
          status: typeof update["status"] === "string" ? update["status"] : undefined,
          title: typeof update["title"] === "string" ? update["title"] : undefined,
        });
        break;
      }
      case "usage_update": {
        this.lastUsage = {
          used: typeof update["used"] === "number" ? update["used"] : this.lastUsage.used,
          size: typeof update["size"] === "number" ? update["size"] : this.lastUsage.size,
          cost: this.lastUsage.cost,
        };
        const cost = update["cost"] as Record<string, unknown> | undefined;
        const amount = cost?.["amount"];
        if (typeof amount === "number" && amount > 0) this.lastUsage.cost = amount;
        this.emit({ kind: "usage", ...this.lastUsage });
        break;
      }
      default:
        // plan / current_mode_update / session_info_update / … — not surfaced.
        break;
    }
  }

  // -- watchdog ------------------------------------------------------------

  private armTurnTimer() {
    const ms = (this.opts.turnTimeout ?? DEFAULT_TURN_TIMEOUT) * 1000;
    this.turnTimer = setTimeout(() => {
      this.emit({ kind: "failed", message: `Turn timed out after ${this.opts.turnTimeout ?? DEFAULT_TURN_TIMEOUT}s` });
      this.turnActive = false;
      this.stop();
    }, ms);
  }

  private clearTurnTimer() {
    if (this.turnTimer) {
      clearTimeout(this.turnTimer);
      this.turnTimer = null;
    }
  }

  private failAll(message: string) {
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new Error(message));
    }
    this.pending.clear();
  }
}

function textIn(update: Record<string, unknown>): string | null {
  const content = update["content"] as Record<string, unknown> | undefined;
  const text = content?.["text"];
  return typeof text === "string" && text.length > 0 ? text : null;
}
