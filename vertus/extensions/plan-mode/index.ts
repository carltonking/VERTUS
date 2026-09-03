/**
 * Plan Mode for VERTUS
 *
 * A read-only operating state: VERTUS can analyze the codebase, search files,
 * and reason through problems, but cannot modify any files or run state-changing
 * commands until you toggle it off.
 *
 * Usage:
 *   /plan-mode            → toggles (also: `on` / `off` / `status` args)
 *   Ctrl+Alt+P            → toggles
 *   --plan-mode (CLI)     → start the session in plan mode
 *
 * The state shows only in the footer badge under the prompt bar
 * ("plan-mode: ON" / "plan-mode: OFF") — nothing is written to the visible
 * session transcript.
 *
 * How it enforces read-only:
 *   1. Write-capable tools are removed from the active tool set (edit, write,
 *      powershell, and every write-capable custom tool on this install: email
 *      sends, calendar mutations, browser interaction). read/grep/find/ls and
 *      the read-only custom tools (web search/fetch, email/calendar readers,
 *      ask-user) stay available.
 *   2. Every bash command is checked against a read-only classifier that
 *      splits the line on operators, resolves wrappers and command
 *      substitution, and allowlists read-only commands; anything that can
 *      modify files, install, send, or delete is blocked with a reason
 *      (no prompt — plan mode is a hard state, not a permission dialog).
 *   3. A hidden state notice is injected on turns so the model knows the
 *      CURRENT mode: an ACTIVE notice every turn while ON, and a one-shot
 *      OFF notice after toggling off that supersedes stale ACTIVE notices
 *      from history (older/duplicate notices are stripped before every LLM
 *      call). Toggling mid-session therefore takes effect for the model on
 *      its very next turn — it never has to guess or probe the filesystem.
 *
 * State persists across /reload and session resume via a custom session
 * entry (newest entry wins), but is naturally off in brand-new sessions.
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { isToolCallEventType } from "@mariozechner/pi-coding-agent";
import { Key, truncateToWidth, visibleWidth } from "@mariozechner/pi-tui";
import { isAbsolute, relative, resolve, sep } from "node:path";

// ============================================================================
// Pure classifier — is this shell command read-only?
// Marked region is extracted verbatim by the test harness.
// ============================================================================

// ---- plan-mode pure section (test-extract START) ----

const ENTRY_TYPE = "plan-mode-state";
const CONTEXT_TYPE = "plan-mode-context";

// ============================================================================
// State notices — every turn carries an explicit, current plan-mode marker so
// the model never has to guess (or probe the filesystem to learn) the state.
// ============================================================================

export const STATE_ON_MARKER = "[plan-mode: ACTIVE — READ-ONLY]";
export const STATE_OFF_MARKER = "[plan-mode: OFF — FULL WRITE ACCESS]";
/** Pre-2026-09 notices used this header; treat them as ON-era notices. */
const LEGACY_ON_MARKER = "[PLAN MODE ACTIVE";

export type PlanModeNoticeState = "on" | "off";

/** Classify a notice body: "on" / "off", or null if not a plan-mode notice. */
export function planModeNoticeState(text: string): PlanModeNoticeState | null {
	if (text.includes(STATE_ON_MARKER) || text.includes(LEGACY_ON_MARKER)) return "on";
	if (text.includes(STATE_OFF_MARKER)) return "off";
	return null;
}

function noticeText(m: unknown): string {
	const msg = m as { role?: string; customType?: string; content?: unknown };
	if (typeof msg.content === "string") return msg.content;
	if (Array.isArray(msg.content)) {
		return msg.content
			.map((c) => (c && typeof c === "object" && (c as { type?: string }).type === "text" ? String((c as { text?: string }).text ?? "") : ""))
			.join("\n");
	}
	return "";
}

function isPlanModeNotice(m: unknown): boolean {
	const msg = m as { role?: string; customType?: string };
	return msg.role === "custom" && msg.customType === CONTEXT_TYPE;
}

function noticeStateOf(m: unknown): PlanModeNoticeState | null {
	return isPlanModeNotice(m) ? planModeNoticeState(noticeText(m)) : null;
}

const ON_NOTICE = `${STATE_ON_MARKER}
Plan mode is ON right now. You can read, search, and analyze, but you must not modify anything:
- edit/write and other write-capable tools are disabled
- bash is restricted to read-only commands; anything that writes, installs, sends, or deletes will be blocked
- do not attempt workarounds. Analyze, reason, and propose a concrete plan instead of acting.
- when you have a proposal, present it and wait for the user (they can turn plan mode off with /plan-mode).
This notice is re-issued every turn while plan mode is on, and it supersedes any older plan-mode notice in this conversation.`;

const OFF_NOTICE = `${STATE_OFF_MARKER}
Plan mode is OFF right now. Write tools and state-changing commands are available — work normally.
Any older ACTIVE/READ-ONLY notices earlier in this conversation are stale and no longer in effect; do not refuse work because of them, and do not probe the filesystem to double-check.
(The user can turn plan mode back on with /plan-mode or Ctrl+Alt+P.)`;

/**
 * Keep only the newest notice matching the current state; drop everything else
 * (stale ON notices after toggle-off, stale OFF notices after toggle-on, and
 * duplicate same-state notices from earlier turns). Exported for tests.
 */
export function filterPlanModeNotices<T>(messages: T[], enabled: boolean): { messages: T[]; removed: number } {
	const wanted: PlanModeNoticeState = enabled ? "on" : "off";
	let newestMatching = -1;
	for (let i = messages.length - 1; i >= 0; i--) {
		if (noticeStateOf(messages[i]) === wanted) {
			newestMatching = i;
			break;
		}
	}
	const out: T[] = [];
	let removed = 0;
	messages.forEach((m, i) => {
		if (isPlanModeNotice(m)) {
			if (i === newestMatching) out.push(m);
			else removed++;
			return;
		}
		out.push(m);
	});
	return { messages: out, removed };
}


/** Commands whose first word alone makes the whole segment read-only. */
const SAFE_COMMANDS = new Set([
	// file reading / inspection
	"cat", "head", "tail", "less", "more", "grep", "rg", "find", "ls", "pwd",
	"echo", "printf", "wc", "sort", "uniq", "diff", "comm", "cmp", "file",
	"stat", "du", "df", "tree", "bat", "eza", "colordiff", "jq", "md5",
	"md5sum", "shasum", "sha256sum", "base64", "xxd", "hexdump", "strings",
	"readlink", "realpath", "dirname", "basename",
	// environment / system info (read-only)
	"which", "whereis", "type", "printenv", "uname", "whoami", "id", "date",
	"cal", "uptime", "ps", "top", "htop", "sw_vers", "system_profiler",
	"hostname", "tty", "true", "false", "test", "[",
	// structured reads with per-subcommand checks below
	"git", "npm", "gh", "curl", "wget", "sed", "awk", "yq",
	"defaults", "sysctl", "diskutil", "kubectl", "docker",
	"node", "python", "python3",
	// shell keywords: structural only — their bodies are classified as the
	// operator-split segments they contain (do/then blocks etc.)
	"for", "while", "if", "then", "else", "elif", "fi", "do", "done",
	"in", "case", "esac", "function",
]);

/** Wrappers that don't change what the wrapped command can do. */
const TRANSPARENT_WRAPPERS = new Set([
	"command", "nice", "nohup", "time", "watch", "xargs", "exec",
]);

/** First words that are never allowed in plan mode (privilege / danger). */
const BLOCKED_COMMANDS = new Set([
	"sudo", "doas", "su", "vim", "vi", "nano", "emacs", "code", "subl",
	"open", "tee", "touch", "mkdir", "rmdir", "rm", "mv", "cp", "ln",
	"chmod", "chown", "chgrp", "truncate", "dd", "shred", "mkfs", "kill",
	"pkill", "killall", "shutdown", "reboot", "make", "npx", "pip", "pip3",
	"brew", "apt", "apt-get", "yarn", "pnpm", "bundle", "gem", "cargo",
	"go", "rustup", "terraform", "ansible", "ssh", "scp", "rsync", "nc",
	"netcat", "osascript", "bash", "sh", "zsh", "fish", "ash", "dash",
	"source", ".", "eval", "screen", "tmux", "hdiutil", "softwareupdate",
]);

const GIT_READ_SUBCOMMANDS = new Set([
	"status", "log", "diff", "show", "branch", "remote", "rev-parse",
	"describe", "ls-files", "ls-remote", "blame", "shortlog", "reflog",
	"grep", "cat-file", "count-objects", "whatchanged", "merge-base",
	"cherry", "symbolic-ref", "worktree",
]);

const NPM_READ_SUBCOMMANDS = new Set(["ls", "list", "view", "search", "outdated", "audit"]);
const KUBECTL_READ_SUBCOMMANDS = new Set(["get", "describe", "logs", "explain"]);
const DOCKER_READ_SUBCOMMANDS = new Set(["ps", "images", "logs", "inspect", "version", "info"]);

const ASSIGNMENT_RE = /^[A-Za-z_][A-Za-z0-9_]*=/;

export interface ReadOnlyVerdict {
	ok: boolean;
	reason?: string;
}

const OK: ReadOnlyVerdict = { ok: true };
const blocked = (reason: string): ReadOnlyVerdict => ({ ok: false, reason });

/** Tokenize a command string into words, respecting quotes. */
function words(segment: string): string[] {
	const out: string[] = [];
	let cur = "";
	let quote: '"' | "'" | null = null;
	let escaped = false;
	let started = false;
	for (const ch of segment) {
		if (escaped) {
			cur += ch;
			escaped = false;
			continue;
		}
		if (ch === "\\" && quote !== "'") {
			escaped = true;
			started = true;
			continue;
		}
		if (quote) {
			if (ch === quote) {
				quote = null;
			} else {
				cur += ch;
			}
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			started = true;
			continue;
		}
		if (/\s/.test(ch)) {
			if (started || cur.length > 0) out.push(cur);
			cur = "";
			started = false;
			continue;
		}
		cur += ch;
		started = true;
	}
	if (started || cur.length > 0) out.push(cur);
	return out;
}

/**
 * Find the end of the first `$( ... )` or backtick group starting at/after
 * `from`; returns inner text and the index just past the group, or null.
 */
function nextCommandSubstitution(segment: string, from: number): { inner: string; end: number } | null {
	for (let i = from; i < segment.length; i++) {
		if (segment[i] === "$" && segment[i + 1] === "(") {
			let level = 1;
			let j = i + 2;
			while (j < segment.length && level > 0) {
				if (segment[j] === "(") level++;
				else if (segment[j] === ")") level--;
				j++;
			}
			// j is one past the closing paren
			return { inner: segment.slice(i + 2, j - 1), end: j };
		}
		if (segment[i] === "`") {
			const close = segment.indexOf("`", i + 1);
			if (close === -1) return null;
			return { inner: segment.slice(i + 1, close), end: close + 1 };
		}
	}
	return null;
}

/** Resolve leading assignments / wrappers down to the real command + args. */
function resolveCommand(tokens: string[]): { cmd: string; args: string[] } | null {
	let idx = 0;
	for (;;) {
		if (idx >= tokens.length) return null; // nothing but assignments
		const t = tokens[idx];
		if (ASSIGNMENT_RE.test(t)) {
			idx++;
			continue;
		}
		if (TRANSPARENT_WRAPPERS.has(t)) {
			idx++;
			// `command` may carry lookup flags: `command -v git`
			while (idx < tokens.length && tokens[idx].startsWith("-")) idx++;
			continue;
		}
		if ((t === "env" || t === "timeout") && idx + 1 < tokens.length) {
			const n = tokens[idx + 1];
			if (/^\d+$/.test(n) || ASSIGNMENT_RE.test(n) || n.startsWith("-")) {
				idx++;
				continue;
			}
		}
		return { cmd: t, args: tokens.slice(idx + 1) };
	}
}

/** Classify one segment (no top-level operators). */
function classifySegment(segment: string, depth: number): ReadOnlyVerdict {
	if (depth > 6) return blocked("command nesting too deep to analyze safely");

	// Command substitution runs code — classify the inner command text too.
	let searchFrom = 0;
	for (;;) {
		const sub = nextCommandSubstitution(segment, searchFrom);
		if (!sub) break;
		const verdict = classifyCommandLine(sub.inner, depth + 1);
		if (!verdict.ok) return verdict;
		searchFrom = sub.end;
	}

	const tokens = words(segment);
	const resolved = resolveCommand(tokens);
	if (!resolved) return OK; // assignments only — nothing executed

	const { cmd, args } = resolved;

	if (BLOCKED_COMMANDS.has(cmd)) {
		return blocked(`\`${cmd}\` can modify files, execute code, or change system state`);
	}
	if (!SAFE_COMMANDS.has(cmd)) {
		return blocked(`\`${cmd}\` is not on the plan-mode read-only allowlist`);
	}

	switch (cmd) {
		case "find":
			if (args.some((a) => /^--?(delete|exec|execdir|ok|okdir|fprintf)$/.test(a))) {
				return blocked("`find` with -delete/-exec modifies files");
			}
			return OK;
		case "sed":
			if (args.some((a) => a === "-i" || a.startsWith("-i"))) {
				return blocked("`sed -i` edits files in place");
			}
			if (!args.some((a) => a === "-n" || a.startsWith("-n"))) {
				return blocked("`sed` without -n implies editing; use `sed -n` or `grep` for read-only output");
			}
			return OK;
		case "awk":
			if (/system\s*\(|close\s*\(|getline|>\s*["']|\|\s*&/.test(segment)) {
				return blocked("`awk` script can execute commands or write files");
			}
			return OK;
		case "curl":
			if (
				args.some((a) =>
					/^(-o$|-O$|--output|-T$|--upload-file|-d$|--data|-F$|--form|-X$|--request|-x$|--proxy)/.test(a),
				)
			) {
				return blocked("`curl` with output/upload/method/proxy flags changes state");
			}
			return OK;
		case "wget":
			if (
				!args.some(
					(a) => a === "-" || a === "-O-" || a === "-qO-" || a === "--output-document=-" || a === "-O -",
				)
			) {
				return blocked("`wget` downloads (writes) files unless streaming to stdout");
			}
			return OK;
		case "git": {
			// Skip global flags before the subcommand: -C path, -c k=v, --no-pager, --git-dir=…
			let i = 0;
			while (i < args.length && (args[i] === "-C" || args[i] === "-c" || args[i] === "--no-pager" || ASSIGNMENT_RE.test(args[i]))) {
				i += args[i] === "-C" || args[i] === "-c" ? 2 : 1;
			}
			const sub = args[i];
			if (!sub) return OK;
			if (!GIT_READ_SUBCOMMANDS.has(sub)) {
				return blocked(`\`git ${sub}\` can modify the repo; only read subcommands are allowed in plan mode`);
			}
			const rest = args.slice(i + 1);
			if (sub === "branch" && rest.some((a) => /^-[dDmM]/.test(a) || a === "--delete" || a === "--move")) {
				return blocked("`git branch -d/-D/-m` modifies the repo");
			}
			if (sub === "stash" && rest[0] && rest[0] !== "list" && rest[0] !== "show") {
				return blocked("`git stash` (other than list/show) modifies the repo");
			}
			if (sub === "reflog" && rest[0] && rest[0] !== "show" && rest[0] !== "list") {
				return blocked("`git reflog " + rest[0] + "` can rewrite history");
			}
			if (sub === "tag" && rest[0] && !/^-l?$|^--list$/.test(rest[0])) {
				return blocked("`git tag` (other than listing) modifies the repo");
			}
			if (sub === "config" && !(rest[0] === "--get" || rest[0] === "--list")) {
				return blocked("`git config` (other than --get/--list) writes config");
			}
			if (sub === "worktree" && rest[0] !== "list") {
				return blocked("`git worktree " + (rest[0] ?? "") + "` modifies the repo");
			}
			return OK;
		}
		case "npm":
			if (args[0] && !NPM_READ_SUBCOMMANDS.has(args[0])) {
				return blocked(`\`npm ${args[0]}\` installs, writes, or executes code`);
			}
			return OK;
		case "gh": {
			const sub = args[0];
			const read: Record<string, Set<string>> = {
				repo: new Set(["list", "view"]),
				pr: new Set(["list", "view", "diff", "checks", "status"]),
				issue: new Set(["list", "view", "status"]),
				auth: new Set(["status"]),
				config: new Set(["get"]),
			};
			if (sub === "api") {
				if (args.some((a) => /^(-X$|--method|-f$|-F$|--field|--raw-field)/.test(a))) {
					return blocked("`gh api` with write method/fields changes state");
				}
				return OK;
			}
			if (!sub || !read[sub] || (args[1] && !read[sub].has(args[1]))) {
				return blocked(`\`gh ${sub ?? ""}\` is not a read-only GitHub query`);
			}
			return OK;
		}
		case "kubectl":
			if (args[0] && !KUBECTL_READ_SUBCOMMANDS.has(args[0])) {
				return blocked(`\`kubectl ${args[0]}\` changes cluster state`);
			}
			return OK;
		case "docker":
			if (args[0] && !DOCKER_READ_SUBCOMMANDS.has(args[0])) {
				return blocked(`\`docker ${args[0]}\` changes containers/images`);
			}
			return OK;
		case "defaults":
			if (args[0] !== "read") return blocked("only `defaults read` is allowed");
			return OK;
		case "sysctl":
			if (args.some((a) => a === "-w")) return blocked("`sysctl -w` writes kernel state");
			return OK;
		case "diskutil":
			if (!(args[0] === "list" || args[0] === "info")) {
				return blocked(`\`diskutil ${args[0] ?? ""}\` can modify disks`);
			}
			return OK;
		case "node":
		case "python":
		case "python3":
			// Only version probes; running code can write files.
			if (args.length === 0 || args.every((a) => /^(-{1,2})(version|V|v)$/.test(a))) return OK;
			return blocked(`\`${cmd}\` executes code, which can write files`);
		case "yq":
			if (args.some((a) => a === "-i" || a === "--inplace")) {
				return blocked("`yq -i` edits files");
			}
			return OK;
		default:
			return OK;
	}
}

/**
 * Classify a full command line (or a nested fragment): split on top-level
 * operators, classify every segment, and reject redirections that write to a
 * real file or smuggle a process substitution. `2>/dev/null`, `2>&1`, and
 * `< input` are fine.
 */
function classifyCommandLine(command: string, depth: number): ReadOnlyVerdict {
	if (depth > 6) return blocked("command nesting too deep to analyze safely");

	let cur = "";
	let quote: '"' | "'" | null = null;
	let escaped = false;

	const flush = (): ReadOnlyVerdict | null => {
		const seg = cur.trim();
		cur = "";
		if (!seg) return null;
		return classifySegment(seg, depth);
	};

	for (let i = 0; i < command.length; i++) {
		const ch = command[i];
		if (escaped) {
			cur += ch;
			escaped = false;
			continue;
		}
		if (ch === "\\" && quote !== "'") {
			cur += ch;
			escaped = true;
			continue;
		}
		if (quote) {
			cur += ch;
			if (ch === quote) quote = null;
			continue;
		}
		if (ch === '"' || ch === "'") {
			quote = ch;
			cur += ch;
			continue;
		}
		// Logical operators
		if ((ch === "&" && command[i + 1] === "&") || (ch === "|" && command[i + 1] === "|")) {
			const v = flush();
			if (v && !v.ok) return v;
			i++;
			continue;
		}
		if (ch === ";" || ch === "|" || ch === "\n" || ch === "&") {
			const v = flush();
			if (v && !v.ok) return v;
			continue;
		}
		// Process substitution — runs a command: classify its content.
		if ((ch === ">" || ch === "<") && command[i + 1] === "(") {
			let level = 1;
			let j = i + 2;
			while (j < command.length && level > 0) {
				if (command[j] === "(") level++;
				else if (command[j] === ")") level--;
				j++;
			}
			const verdict = classifyCommandLine(command.slice(i + 2, j - 1), depth + 1);
			if (!verdict.ok) return blocked(`process substitution: ${verdict.reason}`);
			i = j - 1;
			continue;
		}
		// Redirection
		if (ch === ">" || ch === "<") {
			const isInput = ch === "<";
			let j = i + 1;
			if (command[j] === ">") j++; // >>
			while (j < command.length && /\s/.test(command[j])) j++;
			// fd duplication: >&1, 2>&1, <&0 — no file touched
			if (command[j] === "&") {
				j++;
				while (j < command.length && /[0-9]/.test(command[j])) j++;
				i = j - 1;
				continue;
			}
			// here-string / heredoc marker: <<< "text", << EOF — no file touched
			if (isInput && (command[j] === "<" || (command[j] === "<" && command[j + 1] === "<"))) {
				i = j;
				continue;
			}
			let target = "";
			let tquote: '"' | "'" | null = null;
			while (j < command.length) {
				const t = command[j];
				if (tquote) {
					if (t === tquote) tquote = null;
					else target += t;
					j++;
					continue;
				}
				if (t === '"' || t === "'") {
					tquote = t as '"' | "'";
					j++;
					continue;
				}
				if (/\s/.test(t) || /[;|&()<>]/.test(t)) break;
				target += t;
				j++;
			}
			if (!isInput && target !== "/dev/null") {
				return blocked(`\`> ${target}\` writes to a file — not allowed in plan mode`);
			}
			i = j - 1;
			continue;
		}
		cur += ch;
	}
	const v = flush();
	if (v && !v.ok) return v;
	return OK;
}

/** Public entry: is this shell command read-only? */
export function isReadOnlyCommand(command: string): ReadOnlyVerdict {
	return classifyCommandLine(command, 0);
}

// ---- plan-mode pure section (test-extract END) ----

// ============================================================================
// Extension
// ============================================================================

/** Built-in tools that can modify the workspace (removed while in plan mode). */
const CORE_WRITE_TOOLS = new Set(["edit", "write", "powershell"]);
// bash stays ACTIVE in plan mode (guarded by the classifier above) —
// analysis often needs it.

/** Custom tools on this install that can change state outside the repo. */
const CUSTOM_WRITE_TOOLS = new Set([
	"compose_email", "send_email", "send_draft",
	"create_calendar_event", "cancel_calendar_event",
	"browser_goto", "browser_eval", "browser_fill", "browser_click",
	"browser_screenshot", "browser_close", "browser_network", "browser_console",
]);

const READ_ONLY_CORE = ["read", "grep", "find", "ls"];

export default function planModeExtension(pi: ExtensionAPI): void {
	let enabled = false;
	let toolsBeforePlanMode: string[] | undefined;
	/** Last plan-mode state the model was told about (per session). */
	let announced: PlanModeNoticeState | undefined;

	pi.registerFlag("plan-mode", {
		description: "Start the session in plan mode (read-only).",
		type: "boolean",
		default: false,
	});

	function applyToolGate(): void {
		if (enabled) {
			if (toolsBeforePlanMode === undefined) {
				toolsBeforePlanMode = pi.getActiveTools();
			}
			const kept = toolsBeforePlanMode.filter(
				(name) => !CORE_WRITE_TOOLS.has(name) && !CUSTOM_WRITE_TOOLS.has(name),
			);
			const merged = [...new Set([...READ_ONLY_CORE, ...kept])];
			pi.setActiveTools(merged);
		} else {
			if (toolsBeforePlanMode !== undefined) {
				pi.setActiveTools(toolsBeforePlanMode);
				toolsBeforePlanMode = undefined;
			}
		}
	}

	// ==========================================================================
	// Custom footer: pi's built-in footer with `plan-mode: ON/OFF` inserted
	// directly after the context percentage on the stats line.
	//
	// The factory below is a faithful port of pi's FooterComponent.render()
	// (token totals, cache-hit rate, cost, context %, model + thinking level,
	// git branch, provider count, extension statuses line). The only layout
	// change is the badge pushed onto statsParts right after the context %.
	//
	// The footer is re-registered on every session_start because captured
	// extension contexts go stale across session switches (/new, /fork,
	// /reload). A defensive try/catch degrades to a minimal badge-only line
	// rather than killing the TUI render loop.
	// ==========================================================================

	let footerRequestRender: (() => void) | undefined;

	function formatTokens(count: number): string {
		if (count < 1000) return count.toString();
		if (count < 10000) return `${(count / 1000).toFixed(1)}k`;
		if (count < 1000000) return `${Math.round(count / 1000)}k`;
		if (count < 10000000) return `${(count / 1000000).toFixed(1)}M`;
		return `${Math.round(count / 1000000)}M`;
	}

	function sanitizeStatusText(text: string): string {
		return text
			.replace(/[\r\n\t]/g, " ")
			.replace(/ +/g, " ")
			.trim();
	}

	function formatCwdForFooter(cwd: string, home: string | undefined): string {
		if (!home) return cwd;
		const resolvedCwd = resolve(cwd);
		const resolvedHome = resolve(home);
		const rel = relative(resolvedHome, resolvedCwd);
		const isInsideHome =
			rel === "" || (rel !== ".." && !rel.startsWith(`..${sep}`) && !isAbsolute(rel));
		if (!isInsideHome) return cwd;
		return rel === "" ? "~" : `~${sep}${rel}`;
	}

	function badgeText(theme: any): string {
		return enabled ? theme.fg("warning", theme.bold("plan-mode: ON")) : theme.fg("dim", "plan-mode: OFF");
	}

	function registerFooter(ctx: ExtensionContext): void {
		if (ctx.mode !== "tui" || !ctx.hasUI) return;
		const sessionCtx = ctx;
		ctx.ui.setFooter((tui, theme, footerData) => {
			const unsub = footerData.onBranchChange(() => tui.requestRender());
			footerRequestRender = () => tui.requestRender();

			return {
				dispose: () => {
					unsub();
					if (footerRequestRender) footerRequestRender = undefined;
				},
				invalidate() {},
				render(width: number): string[] {
					// Fallback line if the captured context has gone stale between
					// session switches (next session_start re-registers a fresh one).
					const minimal = (): string[] => {
						const statuses = Array.from(footerData.getExtensionStatuses().entries())
							.sort(([a], [b]) => a.localeCompare(b))
							.map(([, text]) => sanitizeStatusText(text));
						const line = `${badgeText(theme)}${statuses.length ? " " + statuses.join(" ") : ""}`;
						return [truncateToWidth(line, width, theme.fg("dim", "..."))];
					};

					try {
						// --- usage totals over all session entries (same as built-in) ---
						let input = 0,
							output = 0,
							cacheRead = 0,
							cacheWrite = 0,
							cost = 0;
						let latestCacheHitRate: number | undefined;
						const entries = sessionCtx.sessionManager.getEntries() as Array<any>;
						for (const entry of entries) {
							if (entry.type === "message" && entry.message?.role === "assistant") {
								const usage = entry.message.usage;
								if (!usage || typeof usage.input !== "number") continue;
								input += usage.input;
								output += usage.output ?? 0;
								cacheRead += usage.cacheRead ?? 0;
								cacheWrite += usage.cacheWrite ?? 0;
								cost += usage.cost?.total ?? 0;
								const latestPromptTokens = usage.input + (usage.cacheRead ?? 0) + (usage.cacheWrite ?? 0);
								latestCacheHitRate =
									latestPromptTokens > 0 ? ((usage.cacheRead ?? 0) / latestPromptTokens) * 100 : undefined;
							} else if (entry.type === "message" && entry.message?.role === "toolResult" && entry.message.usage) {
								const usage = entry.message.usage;
								input += usage.input ?? 0;
								output += usage.output ?? 0;
								cacheRead += usage.cacheRead ?? 0;
								cacheWrite += usage.cacheWrite ?? 0;
								cost += usage.cost?.total ?? 0;
							} else if ((entry.type === "branch_summary" || entry.type === "compaction") && entry.usage) {
								const usage = entry.usage;
								input += usage.input ?? 0;
								output += usage.output ?? 0;
								cacheRead += usage.cacheRead ?? 0;
								cacheWrite += usage.cacheWrite ?? 0;
								cost += usage.cost?.total ?? 0;
							}
						}

						// --- context usage (handles compaction) ---
						const contextUsage = sessionCtx.getContextUsage() as
							| { tokens: number | null; contextWindow: number; percent: number | null }
							| undefined;
						const model = sessionCtx.model as { id?: string; provider?: string; contextWindow?: number; reasoning?: boolean } | undefined;
						const contextWindow = contextUsage?.contextWindow ?? model?.contextWindow ?? 0;
						const contextPercentValue = contextUsage?.percent ?? 0;
						const contextPercent =
							contextUsage?.percent !== null && contextUsage !== undefined ? contextPercentValue.toFixed(1) : "?";

						// --- pwd + branch + session name ---
						let pwd = formatCwdForFooter(
							sessionCtx.sessionManager.getCwd(),
							process.env.HOME || process.env.USERPROFILE,
						);
						const branch = footerData.getGitBranch();
						if (branch) pwd = `${pwd} (${branch})`;
						const sessionName = sessionCtx.sessionManager.getSessionName();
						if (sessionName) pwd = `${pwd} • ${sessionName}`;

						// --- stats parts ---
						const statsParts: string[] = [];
						if (input) statsParts.push(`↑${formatTokens(input)}`);
						if (output) statsParts.push(`↓${formatTokens(output)}`);
						if (cacheRead) statsParts.push(`R${formatTokens(cacheRead)}`);
						if (cacheWrite) statsParts.push(`W${formatTokens(cacheWrite)}`);
						if ((cacheRead > 0 || cacheWrite > 0) && latestCacheHitRate !== undefined) {
							statsParts.push(`CH${latestCacheHitRate.toFixed(1)}%`);
						}
						// (The built-in also appends `$cost` / kimi subscription info; the
						// subscription runtime check is not exposed to extensions, and cost
						// display was not present in this user's footer.)
						if (cost) statsParts.push(`$${cost.toFixed(3)}`);

						let contextPercentStr: string;
						// compaction.enabled defaults to true; cosmetic (auto) indicator.
						const autoIndicator = " (auto)";
						const contextPercentDisplay =
							contextPercent === "?"
								? `?/${formatTokens(contextWindow)}${autoIndicator}`
								: `${contextPercent}%/${formatTokens(contextWindow)}${autoIndicator}`;
						if (contextPercentValue > 90) {
							contextPercentStr = theme.fg("error", contextPercentDisplay);
						} else if (contextPercentValue > 70) {
							contextPercentStr = theme.fg("warning", contextPercentDisplay);
						} else {
							contextPercentStr = contextPercentDisplay;
						}
						statsParts.push(contextPercentStr);

						// >>> THE BADGE: immediately right of the context percentage <<<
						statsParts.push(badgeText(theme));

						let statsLeft = statsParts.join(" ");
						let statsLeftWidth = visibleWidth(statsLeft);
						if (statsLeftWidth > width) {
							statsLeft = truncateToWidth(statsLeft, width, "...");
							statsLeftWidth = visibleWidth(statsLeft);
						}

						// --- right side: model + thinking level ---
						const modelName = model?.id || "no-model";
						const minPadding = 2;
						let rightSideWithoutProvider = modelName;
						if (model?.reasoning) {
							const thinkingLevel = (sessionCtx.thinkingLevel as string | undefined) || "off";
							rightSideWithoutProvider =
								thinkingLevel === "off" ? `${modelName} • thinking off` : `${modelName} • ${thinkingLevel}`;
						}
						let rightSide = rightSideWithoutProvider;
						if (footerData.getAvailableProviderCount() > 1 && model) {
							rightSide = `(${model.provider}) ${rightSideWithoutProvider}`;
							if (statsLeftWidth + minPadding + visibleWidth(rightSide) > width) {
								rightSide = rightSideWithoutProvider;
							}
						}

						const rightSideWidth = visibleWidth(rightSide);
						const totalNeeded = statsLeftWidth + minPadding + rightSideWidth;

						let statsLine: string;
						if (totalNeeded <= width) {
							const padding = " ".repeat(width - statsLeftWidth - rightSideWidth);
							statsLine = statsLeft + padding + rightSide;
						} else {
							const availableForRight = width - statsLeftWidth - minPadding;
							if (availableForRight > 0) {
								const truncatedRight = truncateToWidth(rightSide, availableForRight, "");
								const truncatedRightWidth = visibleWidth(truncatedRight);
								const padding = " ".repeat(Math.max(0, width - statsLeftWidth - truncatedRightWidth));
								statsLine = statsLeft + padding + truncatedRight;
							} else {
								statsLine = statsLeft;
							}
						}

						// Dim each part separately so the colored context % survives.
						const dimStatsLeft = theme.fg("dim", statsLeft);
						const remainder = statsLine.slice(statsLeft.length);
						const dimRemainder = theme.fg("dim", remainder);

						const pwdLine = truncateToWidth(theme.fg("dim", pwd), width, theme.fg("dim", "..."));
						const lines = [pwdLine, dimStatsLeft + dimRemainder];

						// --- extension statuses line (other extensions keep theirs) ---
						const extensionStatuses = footerData.getExtensionStatuses();
						if (extensionStatuses.size > 0) {
							const sortedStatuses = Array.from(extensionStatuses.entries())
								.sort(([a], [b]) => a.localeCompare(b))
								.map(([, text]) => sanitizeStatusText(text));
							const statusLine = sortedStatuses.join(" ");
							lines.push(truncateToWidth(statusLine, width, theme.fg("dim", "...")));
						}

						return lines;
					} catch {
						return minimal();
					}
				},
			};
		});
	}

	function persist(): void {
		pi.appendEntry(ENTRY_TYPE, { enabled });
	}

	function setEnabled(next: boolean, ctx: ExtensionContext | undefined): void {
		if (enabled === next) {
			if (ctx) {
				ctx.ui?.notify?.(enabled ? "Plan mode is already ON (read-only)." : "Plan mode is already OFF (full access).", "info");
			}
			return;
		}
		enabled = next;
		announced = undefined; // next turn re-announces the new state
		applyToolGate();
		footerRequestRender?.();
		persist();
		if (ctx) {
			ctx.ui?.notify?.(
				enabled
					? "Plan mode ON — read-only. Write tools disabled; bash restricted."
					: "Plan mode OFF — full write access restored.",
			);
		}
	}

	function toggle(ctx: ExtensionContext): void {
		setEnabled(!enabled, ctx);
	}

	pi.registerCommand("plan-mode", {
		description:
			"Toggle plan mode — a read-only state for codebase analysis (no file changes, no destructive commands). Args: on | off | status.",
		handler: async (args, ctx) => {
			const arg = (args ?? "").trim().toLowerCase();
			if (arg === "on") setEnabled(true, ctx);
			else if (arg === "off") setEnabled(false, ctx);
			else if (arg === "status") {
				ctx.ui?.notify?.(enabled ? "plan-mode: ON (read-only)" : "plan-mode: OFF (full write access)", "info");
			} else toggle(ctx);
		},
	});

	pi.registerShortcut(Key.ctrlAlt("p"), {
		description: "Toggle plan mode",
		handler: async (ctx) => toggle(ctx),
	});

	// Restore persisted state on session start / resume / reload, and (re)
	// register the custom footer with this session's fresh context.
	pi.on("session_start", async (_event, ctx) => {
		// Flag name is the registered name ("plan-mode"), not "--plan-mode".
		let want = pi.getFlag("plan-mode") === true;
		const entries = ctx.sessionManager.getEntries() as Array<{
			type: string;
			customType?: string;
			data?: { enabled?: boolean };
		}>;
		for (const entry of entries) {
			if (entry.type === "custom" && entry.customType === ENTRY_TYPE && typeof entry.data?.enabled === "boolean") {
				want = entry.data.enabled;
			}
		}
		enabled = want;
		announced = undefined;
		applyToolGate();
		registerFooter(ctx);
		if (enabled && ctx.hasUI) {
			ctx.ui?.notify?.("Plan mode restored: ON (read-only). /plan-mode to toggle.", "info");
		}
	});

	// Keep the model informed of the CURRENT state on every turn:
	// - ON: re-assert the restriction each turn (it is easy to drift).
	// - OFF: announce once after a change/resume so stale ACTIVE notices in
	//   history are explicitly superseded — then stay quiet.
	pi.on("before_agent_start", async () => {
		const want: PlanModeNoticeState = enabled ? "on" : "off";
		if (!enabled && announced === "off") return;
		announced = want;
		return {
			message: {
				customType: CONTEXT_TYPE,
				display: false,
				content: want === "on" ? ON_NOTICE : OFF_NOTICE,
			},
		};
	});

	// Keep the LLM-facing context clean: exactly one notice — the newest one
	// matching the current state — survives; stale/duplicate notices are
	// stripped before every LLM call (works on live turns and on resume).
	pi.on("context", async (event) => {
		const result = filterPlanModeNotices(event.messages, enabled);
		if (result.removed === 0) return;
		return { messages: result.messages };
	});

	// Hard block for anything that slipped past the tool gate (e.g. tools
	// registered after plan mode enabled) and for state-changing shell.
	pi.on("tool_call", async (event) => {
		if (!enabled) return;

		if (isToolCallEventType("bash", event) || isToolCallEventType("powershell", event)) {
			const command = String(event.input.command ?? "");
			const verdict = isReadOnlyCommand(command);
			if (verdict.ok) return;
			return {
				block: true,
				terminate: true,
				reason:
					`Blocked by plan mode: ${verdict.reason}.\n` +
					"Plan mode is read-only — analyze and propose instead, or ask the user to run /plan-mode to toggle it off.",
			};
		}

		if (CUSTOM_WRITE_TOOLS.has(event.toolName) || CORE_WRITE_TOOLS.has(event.toolName)) {
			return {
				block: true,
				terminate: true,
				reason:
					`Blocked by plan mode: \`${event.toolName}\` modifies state.\n` +
					"Plan mode is read-only — analyze and propose instead, or ask the user to run /plan-mode to toggle it off.",
			};
		}
	});
}
