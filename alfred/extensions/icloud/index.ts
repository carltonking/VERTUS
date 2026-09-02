/**
 * ALFRED iCloud Extension — Calendar (EventKit) + Mail (Mail.app scripting).
 *
 * Gives the ALFRED CLI read/write access to the user's calendars and email
 * through the accounts configured on this Mac (iCloud, Exchange, Gmail, …).
 * No credentials are stored; the OS handles authorization per account.
 *
 * Design:
 *  - Calendar: a small EventKit CLI (`src/alfred-events.swift`) compiled once
 *    to ~/.pi/agent/bin/alfred-events on first use. ALL calendar mutations are
 *    sandboxed in native code to a dedicated calendar (default "ALFRED") that
 *    is auto-created on first use — the agent can never touch real calendars.
 *  - Email: Apple Mail automation via `osascript -l JavaScript`. A one-time
 *    automation permission prompt is shown by macOS on first use.
 *
 * Config: ~/.pi/agent/icloud.json  →  { "calendarName": "ALFRED" }
 */

import type { ExtensionAPI, ExtensionContext } from "@mariozechner/pi-coding-agent";
import { Type } from "typebox";
import { Text } from "@mariozechner/pi-tui";
import * as os from "node:os";
import * as path from "node:path";
import * as fs from "node:fs";
import { execFile } from "node:child_process";

// ── Paths & config ──────────────────────────────────────────────────────────
const AGENT_DIR = path.join(os.homedir(), ".pi", "agent");
const BIN_DIR = path.join(AGENT_DIR, "bin");
const HELPER_BIN = path.join(BIN_DIR, "alfred-events");

let PKG_DIR = "";
try {
	// Modules are imported from their real path via jiti; fall back to the
	// standard install location if the URL is unavailable.
	const url = (import.meta as unknown as { url?: string }).url;
	if (url) PKG_DIR = path.dirname(url.replace(/^file:\/\//, ""));
} catch {
	/* ignore */
}
if (!PKG_DIR || !fs.existsSync(PKG_DIR)) {
	PKG_DIR = path.join(AGENT_DIR, "extensions", "icloud");
}

const HELPER_SRC = path.join(PKG_DIR, "src", "alfred-events.swift");

interface Config {
	calendarName: string;
}
function loadConfig(): Config {
	try {
		const raw = JSON.parse(fs.readFileSync(path.join(AGENT_DIR, "icloud.json"), "utf8")) as Partial<Config>;
		return { calendarName: typeof raw.calendarName === "string" && raw.calendarName.trim() ? raw.calendarName.trim() : "ALFRED" };
	} catch {
		return { calendarName: "ALFRED" };
	}
}

// ── Command runner (pi.exec with child_process fallback) ────────────────────
interface RunResult {
	stdout: string;
	stderr: string;
	code: number;
}
function runCmd(cmd: string, args: string[], timeoutMs: number): Promise<RunResult> {
	return new Promise<RunResult>((resolve) => {
		execFile(cmd, args, { timeout: timeoutMs, maxBuffer: 32 * 1024 * 1024 }, (err, stdout, stderr) => {
			if (!err) {
				resolve({ stdout: stdout || "", stderr: stderr || "", code: 0 });
			} else {
				const e = err as NodeJS.ErrnoException & { killed?: boolean; signal?: string };
				resolve({
					stdout: stdout || "",
					stderr: stderr || (e.message || "command failed"),
					code: typeof e.code === "number" ? e.code : e.killed ? 124 : 1,
				});
			}
		});
	});
}

async function ensureHelper(): Promise<string> {
	if (fs.existsSync(HELPER_BIN)) {
		const binMtime = fs.statSync(HELPER_BIN).mtimeMs;
		const needRebuild = [HELPER_SRC, path.join(AGENT_DIR, "extensions", "icloud", "src", "alfred-events.swift")]
			.filter((p) => fs.existsSync(p))
			.some((p) => fs.statSync(p).mtimeMs > binMtime);
		if (!needRebuild) return HELPER_BIN;
	}
	if (!fs.existsSync(HELPER_SRC)) {
		throw new Error(
			`calendar helper source not found at ${HELPER_SRC}. Reinstall the icloud extension (or run /reload).`,
		);
	}
	fs.mkdirSync(BIN_DIR, { recursive: true });
	const res = await runCmd("swiftc", ["-O", "-o", HELPER_BIN, HELPER_SRC], 180_000);
	if (res.code !== 0 || !fs.existsSync(HELPER_BIN)) {
		throw new Error(`could not compile calendar helper: ${res.stderr.trim() || res.stdout.trim()}`);
	}
	return HELPER_BIN;
}

interface HelperResult {
	ok: boolean;
	error?: string;
	data: Record<string, unknown>;
}
async function runHelper(args: string[]): Promise<HelperResult> {
	try {
		const bin = await ensureHelper();
		const res = await runCmd(bin, args, 60_000);
		if (res.code !== 0) {
			const msg = res.stderr.trim() || res.stdout.trim() || "helper failed";
			return { ok: false, error: msg, data: {} };
		}
		const parsed = JSON.parse(res.stdout) as Record<string, unknown>;
		if (typeof parsed?.error === "string" && parsed.error) {
			return { ok: false, error: parsed.error, data: parsed };
		}
		return { ok: true, error: undefined, data: parsed };
	} catch (e) {
		return { ok: false, error: (e as Error).message, data: {} };
	}
}

// ── Mail JXA scripts (run via osascript -l JavaScript) ──────────────────────
const JXA_SNIPPET_COMMON = `
function plain(html) {
  return (html || "").replace(/<style[\\s\\S]*?<\\/style>/gi, " ").replace(/<script[\\s\\S]*?<\\/script>/gi, " ")
    .replace(/<[^>]+>/g, " ").replace(/&nbsp;/gi, " ").replace(/&amp;/gi, "&").replace(/&lt;/gi, "<")
    .replace(/&gt;/gi, ">").replace(/&quot;/gi, '"').replace(/\\s+/g, " ").trim();
}
`;

const JXA_LIST = `
function run(argv) {
  const p = JSON.parse(argv[0]);
  const Mail = Application("Mail");
  const query = (p.query || "").toLowerCase();
  const unreadOnly = !!p.unreadOnly;
  const withSnippet = !!p.withSnippet;
  const limit = Math.min(p.limit || 10, 50);
  const wantMailbox = (p.mailbox || "INBOX").toLowerCase();
  const wantAccount = (p.account || "").toLowerCase();
  const results = [];
  const seen = new Set();
  ${JXA_SNIPPET_COMMON}
  function add(m, accName, boxName) {
    let id; try { id = m.id(); } catch (e) { return; }
    if (!id || seen.has(id)) return;
    let subject, from, unread, date;
    try { subject = m.subject() || ""; } catch (e) { return; }
    try { from = m.sender() || ""; } catch (e) { from = ""; }
    try { unread = !m.read(); } catch (e) { unread = true; }
    if (unreadOnly && !unread) return;
    try { date = (m.dateReceived() || new Date(0)).toISOString(); } catch (e) { date = ""; }
    let hay = (subject + " " + from).toLowerCase();
    if (query && !hay.includes(query)) {
      let body; try { body = plain(m.content()); } catch (e) { return; }
      if (!body.toLowerCase().includes(query)) return;
      if (withSnippet) { const rec = { id, subject, from, date, unread, account: accName, mailbox: boxName, snippet: body.slice(0, 300) }; results.push(rec); seen.add(id); }
      return;
    }
    seen.add(id);
    const rec = { id, subject, from, date, unread, account: accName, mailbox: boxName };
    if (withSnippet) { let body; try { body = plain(m.content()); } catch (e) { body = ""; } rec.snippet = body.slice(0, 300); }
    results.push(rec);
  }
  const accounts = Mail.accounts();
  for (const acc of accounts) {
    if (wantAccount && acc.name().toLowerCase() !== wantAccount) continue;
    let found = 0;
    for (const box of acc.mailboxes()) {
      if (box.name().toLowerCase() !== wantMailbox) continue;
      const msgs = box.messages();
      const n = Math.min(msgs.length, 400);
      for (let i = 0; i < n; i++) {
        try { add(msgs[i], acc.name(), box.name()); } catch (e) { continue; }
        if (results.length >= limit * 3) break;
      }
      found = 1;
      break;
    }
    void found;
    if (results.length >= limit * 3) break;
  }
  results.sort((a, b) => (a.date < b.date ? 1 : -1));
  const out = results.slice(0, limit);
  return JSON.stringify({ messages: out, count: out.length });
}
`;

const JXA_GET = `
function run(argv) {
  const p = JSON.parse(argv[0]);
  const Mail = Application("Mail");
  ${JXA_SNIPPET_COMMON}
  const wantMailbox = (p.mailbox || "").toLowerCase();
  const wantAccount = (p.account || "").toLowerCase();
  const defaults = wantMailbox ? [wantMailbox] : ["inbox", "drafts", "sent", "archive", "all mail", "junk", "trash"];
  for (const acc of Mail.accounts()) {
    if (wantAccount && acc.name().toLowerCase() !== wantAccount) continue;
    for (const box of acc.mailboxes()) {
      if (!defaults.includes(box.name().toLowerCase())) continue;
      try {
        const m = box.messages.byId(p.messageId);
        if (m && m.exists()) {
          let to = "", cc = "";
          try { to = (m.toRecipients() || []).map((r) => { try { return r.address(); } catch (e) { return ""; } }).filter(Boolean).join(", "); } catch (e) {}
          try { cc = (m.ccRecipients() || []).map((r) => { try { return r.address(); } catch (e) { return ""; } }).filter(Boolean).join(", "); } catch (e) {}
          return JSON.stringify({
            id: m.id(), subject: m.subject() || "", from: m.sender() || "", to, cc,
            date: (m.dateReceived() || new Date(0)).toISOString(),
            account: acc.name(), mailbox: box.name(),
            body: plain(m.content())
          });
        }
      } catch (e) { continue; }
    }
  }
  return JSON.stringify({ error: true, message: "message not found (id may be stale)" });
}
`;

function jxaRecipientsCode(): string {
	return `
  const addRec = (list, who) => {
    for (const raw of (who || "").split(",")) {
      const addr = raw.trim();
      if (!addr) continue;
      try { list.push(Mail.Recipient({ address: addr })); } catch (e) { throw new Error("could not add recipient " + addr + ": " + e.message); }
    }
  };
`;
}

const JXA_SEND = `
function run(argv) {
  const p = JSON.parse(argv[0]);
  const Mail = Application("Mail");
  const msg = Mail.OutgoingMessage({ subject: p.subject, content: p.body });
  Mail.outgoingMessages.push(msg);
  ${jxaRecipientsCode()}
  addRec(msg.toRecipients, p.to);
  if (p.cc) addRec(msg.ccRecipients, p.cc);
  let id = null; try { id = msg.id(); } catch (e) {}
  try { msg.send(); } catch (e) { return JSON.stringify({ error: true, message: "send failed: " + e.message }); }
  return JSON.stringify({ sent: true, id: id, subject: p.subject });
}
`;

const JXA_DRAFT = `
function run(argv) {
  const p = JSON.parse(argv[0]);
  const Mail = Application("Mail");
  const msg = Mail.OutgoingMessage({ subject: p.subject, content: p.body });
  Mail.outgoingMessages.push(msg);
  ${jxaRecipientsCode()}
  addRec(msg.toRecipients, p.to);
  if (p.cc) addRec(msg.ccRecipients, p.cc);
  let id = null; try { id = msg.id(); } catch (e) {}
  try { msg.visible = false; } catch (e) {}
  return JSON.stringify({ drafted: true, id: id, subject: p.subject, mailbox: "Drafts" });
}
`;

const JXA_SEND_DRAFT = `
function run(argv) {
  const p = JSON.parse(argv[0]);
  const Mail = Application("Mail");
  const wantMailbox = (p.mailbox || "").toLowerCase();
  const wantAccount = (p.account || "").toLowerCase();
  let draft = null, draftBox = null, draftAcc = null;
  const tryById = () => {
    for (const acc of Mail.accounts()) {
      if (wantAccount && acc.name().toLowerCase() !== wantAccount) continue;
      for (const box of acc.mailboxes()) {
        if (wantMailbox && box.name().toLowerCase() !== wantMailbox) continue;
        try {
          const m = box.messages.byId(p.messageId);
          if (m && m.exists()) { draft = m; draftBox = box; draftAcc = acc; return true; }
        } catch (e) { continue; }
      }
    }
    return false;
  };
  if (!tryById() && p.subject) {
    for (const acc of Mail.accounts()) {
      for (const box of acc.mailboxes()) {
        if (!/draft/i.test(box.name())) continue;
        const msgs = box.messages();
        const n = Math.min(msgs.length, 30);
        for (let i = 0; i < n; i++) {
          try {
            const m = msgs[i];
            if ((m.subject() || "").toLowerCase() === p.subject.toLowerCase()) { draft = m; draftBox = box; draftAcc = acc; break; }
          } catch (e) { continue; }
        }
        if (draft) break;
      }
      if (draft) break;
    }
  }
  if (!draft) return JSON.stringify({ error: true, message: "draft not found" });
  try {
    // Mail's send verb only works on outgoing-message objects, so rebuild a
    // fresh OutgoingMessage from the draft's properties, then send it.
    const msg = Mail.OutgoingMessage({ subject: draft.subject() || "", content: draft.content() || "" });
    Mail.outgoingMessages.push(msg);
    const addressList = (list) => { try { return (list() || []).map((r) => { try { return r.address(); } catch (e) { return ""; } }).filter(Boolean).join(", "); } catch (e) { return ""; } };
    const to = addressList(draft.toRecipients);
    const cc = addressList(draft.ccRecipients);
    const addRec = (list, who) => { for (const raw of (who || "").split(",")) { const addr = raw.trim(); if (!addr) continue; try { list.push(Mail.Recipient({ address: addr })); } catch (e) { throw new Error("could not add recipient " + addr + ": " + e.message); } } };
    addRec(msg.toRecipients, to);
    addRec(msg.ccRecipients, cc);
    msg.send();
    let id = null; try { id = msg.id(); } catch (e) {}
    return JSON.stringify({ sent: true, id: id, to: to, cc: cc, mailbox: draftBox.name(), account: draftAcc.name(), matchedBy: "id" });
  } catch (e) {
    return JSON.stringify({ error: true, message: "send failed: " + e.message });
  }
}
`;

let osaCounter = 0;
async function runOSA(script: string, payload: unknown, timeoutMs = 90_000): Promise<Record<string, unknown>> {
	const tmpDir = os.tmpdir();
	const file = path.join(tmpDir, `alfred-mail-${process.pid}-${osaCounter++}.js`);
	fs.writeFileSync(file, script, "utf8");
	try {
		const res = await runCmd("/usr/bin/osascript", ["-l", "JavaScript", file, JSON.stringify(payload)], timeoutMs);
		if (res.code !== 0) {
			const err = res.stderr.trim() || res.stdout.trim() || "osascript failed";
			throw new Error(mailErrorHint(err));
		}
		const raw = res.stdout.trim();
		if (!raw) return {};
		const parsed = JSON.parse(raw) as Record<string, unknown>;
		if (typeof parsed?.error === "string" && parsed.error) {
			throw new Error(String(parsed.error));
		}
		if (typeof parsed?.message === "string" && parsed?.error === true) {
			throw new Error(String(parsed.message));
		}
		return parsed;
	} finally {
		try {
			fs.unlinkSync(file);
		} catch {
			/* ignore */
		}
	}
}

function mailErrorHint(raw: string): string {
	const lower = raw.toLowerCase();
	if (lower.includes("-1743") || lower.includes("not allowed assistive") || lower.includes("not authorized")) {
		return (
			"Mail automation permission not granted. On first use macOS prompts for it — click OK.\n" +
			"If no prompt appeared, enable it: System Settings → Privacy & Security → Automation → allow the app that runs the terminal to control Mail."
		);
	}
	if (lower.includes("-1719")) {
		return raw + "\n(Tip: open Mail.app once so it can start its engine, then retry.)";
	}
	return raw;
}

// ── Shared tool plumbing ─────────────────────────────────────────────────────
interface ToolResult {
	content: { type: "text"; text: string }[];
	details?: Record<string, unknown>;
}

function textResult(text: string, details?: Record<string, unknown>): ToolResult {
	return { content: [{ type: "text", text }], details };
}

function summarize(args: Record<string, unknown>, key: string): string {
	const v = args[key];
	return typeof v === "string" ? (v.length > 60 ? v.slice(0, 57) + "..." : v) : "";
}

function makeRender(label: string, key: string) {
	return {
		renderCall(args: Record<string, unknown>, theme: any, context: any) {
			const t = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const what = summarize(args, key);
			t.setText(theme.fg("toolTitle", theme.bold(label)) + (what ? theme.fg("accent", ` ${what}`) : ""));
			return t;
		},
		renderResult(result: any, { expanded }: { expanded: boolean }, theme: any, context: any) {
			const t = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			if (context.isError) {
				const msg = result.content[0]?.type === "text" ? result.content[0].text : "error";
				t.setText(theme.fg("error", msg.split("\n")[0] || "error"));
				return t;
			}
			const first = result.content[0]?.type === "text" ? result.content[0].text : "";
			const headline = first.split("\n")[0] || "done";
			if (!expanded) {
				t.setText(theme.fg("success", headline));
				return t;
			}
			t.setText(theme.fg("success", headline) + "\n" + theme.fg("dim", first.split("\n").slice(1, 8).join("\n")));
			return t;
		},
	};
}

// ── Extension entry ──────────────────────────────────────────────────────────
export default function (pi: ExtensionAPI) {
	// ── Calendar tools ────────────────────────────────────────────────────────
	pi.registerTool({
		...makeRender("calendar", "calendar"),
		name: "list_calendars",
		label: "List Calendars",
		description:
			"List all calendars visible to this Mac (iCloud, Exchange, Gmail, local…). Read-only — use to discover calendar titles, then query or create events. Mutations always go to the dedicated 'ALFRED' calendar, never real ones.",
		promptSnippet: "List the user's calendars (read-only).",
		parameters: Type.Object({}),
		async execute() {
			const r = await runHelper(["list-calendars"]);
			if (!r.ok) throw new Error(r.error);
			const cals = (r.data.calendars as Array<Record<string, unknown>>) ?? [];
			const lines = cals.map((c) => `- **${c.title}** (${c.source})${c.editable === false ? " — read-only" : ""}`);
			return textResult(
				`${cals.length} calendar(s):\n${lines.join("\n")}\n\nCalendar mutations are sandboxed to the "${loadConfig().calendarName}" calendar (auto-created on first write).`,
				{ count: cals.length, calendars: cals },
			);
		},
	});

	pi.registerTool({
		...makeRender("events", "calendar"),
		name: "read_calendar_events",
		label: "Read Calendar Events",
		description:
			"Read calendar events in a date range. Returns id, calendar, title, start, end, location, notes for each event. Use for scheduling, availability checks, 'what's on my calendar' questions. Read-only.",
		promptSnippet:
			"Read the user's calendar events in a date range (id, title, start, end, location, notes).",
		parameters: Type.Object({
			from: Type.Optional(Type.String({ description: 'Start of range, "yyyy-MM-dd" (all-day) or ISO datetime. Default: today.' })),
			to: Type.Optional(Type.String({ description: 'End of range (inclusive), "yyyy-MM-dd" or ISO datetime. Default: +7 days.' })),
			calendar: Type.Optional(Type.String({ description: "Restrict to one calendar title (e.g. 'ALFRED', 'Personal', 'School'). Default: all calendars." })),
			max: Type.Optional(Type.Number({ description: "Maximum events to return (default 50)." })),
		}),
		async execute(_id, params) {
			const args = ["events"];
			if (params.from) args.push("--from", params.from);
			if (params.to) args.push("--to", params.to);
			if (params.calendar) args.push("--calendar", params.calendar);
			if (params.max) args.push("--max", String(Math.floor(params.max)));
			const r = await runHelper(false, args);
			if (!r.ok) throw new Error(r.error);
			const events = (r.data.events as Array<Record<string, unknown>>) ?? [];
			if (events.length === 0) {
				return textResult(`No events from ${r.data.from} to ${r.data.to}.`, { count: 0 });
			}
			const lines = events.map(
				(e) =>
					`- ${e.allDay ? `[all-day]` : `${e.start} → ${e.end}`} **${e.title}** (${e.calendar})${e.location ? ` @ ${e.location}` : ""}${e.notes ? ` — ${String(e.notes).slice(0, 120)}` : ""} — id: \`${e.id}\``,
			);
			return textResult(`${events.length} event(s) ${r.data.from} → ${r.data.to}:\n${lines.join("\n")}`, {
				count: events.length,
				events,
			});
		},
	});

	const calendarMutationsGuideline =
		"Calendar mutations (create/cancel) are sandboxed to the dedicated 'ALFRED' calendar and enforced in native code — never create or cancel events in the user's real calendars.";

	pi.registerTool({
		...makeRender("+event", "title"),
		name: "create_calendar_event",
		label: "Create Calendar Event",
		description:
			`Create an event in the dedicated '${loadConfig().calendarName}' calendar (auto-created on first use) with a default 10-minute reminder. Use for scheduling, reminders, and follow-ups the user asks for. Never creates events in real calendars.`,
		promptSnippet:
			`Create an event (with default reminder) in the sandboxed '${loadConfig().calendarName}' calendar.`,
		promptGuidelines: [calendarMutationsGuideline, "If the user asks to change or remove an event from a real calendar, tell them it must be done in the Calendar app."],
		parameters: Type.Object({
			title: Type.String({ description: "Event summary/title." }),
			start: Type.String({ description: 'Start: "yyyy-MM-dd" for all-day, or "yyyy-MM-ddTHH:mm" / ISO datetime.' }),
			end: Type.String({ description: 'End: same format as start (must be after start).' }),
			location: Type.Optional(Type.String({ description: "Optional location string." })),
			notes: Type.Optional(Type.String({ description: "Optional notes/description." })),
			alarmMinutes: Type.Optional(Type.Number({ description: "Reminder minutes before start (default 10, 0 = none)." })),
		}),
		async execute(_id, params) {
			const cfg = loadConfig();
			const args = ["create-event", "--calendar", cfg.calendarName, "--title", params.title, "--start", params.start, "--end", params.end];
			if (params.location) args.push("--location", params.location);
			if (params.notes) args.push("--notes", params.notes);
			if (params.alarmMinutes !== undefined) args.push("--alarm-minutes", String(Math.floor(params.alarmMinutes)));
			const r = await runHelper(false, args);
			if (!r.ok) throw new Error(r.error);
			return textResult(
				`Created in "${r.data.calendar}": **${r.data.title}** (${r.data.start} → ${r.data.end})${r.data.allDay ? " [all-day]" : ""}, reminder ${r.data.alarmMinutes} min before. id: \`${r.data.id}\``,
				{ event: r.data },
			);
		},
	});

	pi.registerTool({
		...makeRender("−event", "id"),
		name: "cancel_calendar_event",
		label: "Cancel Calendar Event",
		description:
			`Cancel an event previously created in the '${loadConfig().calendarName}' calendar (by its id from read_calendar_events or create_calendar_event). Hard-refuses to touch events in any other calendar. Use to fix mistakes or move a sandboxed event.`,
		promptSnippet: `Cancel an event in the sandboxed '${loadConfig().calendarName}' calendar by id.`,
		promptGuidelines: [calendarMutationsGuideline],
		parameters: Type.Object({
			eventId: Type.String({ description: "The event id (from read_calendar_events / create_calendar_event)." }),
		}),
		async execute(_id, params) {
			const cfg = loadConfig();
			const r = await runHelper(["cancel-event", "--calendar", cfg.calendarName, "--id", params.eventId]);
			if (!r.ok) throw new Error(r.error);
			return textResult(`Cancelled "${r.data.title}" from "${r.data.calendar}".`, { event: r.data });
		},
	});

	// ── Email tools ───────────────────────────────────────────────────────────
	const emailGuidelines = [
		"Never send email without explicit user confirmation of the recipients, subject, and content.",
		"Never fabricate message content or invent senders/recipients; quote what the user actually wrote.",
		"Prefer compose_email (a draft the user can review) over send_email unless the user explicitly asked to send now.",
	];

	pi.registerTool({
		...makeRender("emails", "mailbox"),
		name: "list_emails",
		label: "List Emails",
		description:
			"List recent emails (newest first) from a mailbox — default INBOX. Returns id, subject, sender, date, unread flag, account, mailbox. Read-only. Use for 'any new mail', 'what's in my inbox', triage.",
		promptSnippet: "List recent emails from a mailbox (newest first, read-only).",
		parameters: Type.Object({
			mailbox: Type.Optional(Type.String({ description: "Mailbox name, e.g. INBOX, Sent, Archive. Default INBOX." })),
			account: Type.Optional(Type.String({ description: "Restrict to one account (e.g. 'iCloud', 'School'). Default: all accounts." })),
			limit: Type.Optional(Type.Number({ description: "How many to return (default 10, max 30)." })),
			unreadOnly: Type.Optional(Type.Boolean({ description: "Only unread messages." })),
		}),
		async execute(_id, params) {
			const r = await runOSA(JXA_LIST, {
				query: "",
				mailbox: params.mailbox ?? "INBOX",
				account: params.account,
				limit: params.limit ?? 10,
				unreadOnly: params.unreadOnly,
				withSnippet: false,
			});
			const msgs = (r.messages as Array<Record<string, unknown>>) ?? [];
			if (msgs.length === 0) return textResult(`No messages in ${params.mailbox ?? "INBOX"}.`, { count: 0 });
			const lines = msgs.map(
				(m) => `- ${m.unread ? "●" : "·"} **[${m.subject || "(no subject)"}](id:\`${m.id}\`)** — ${m.from} — ${String(m.date).slice(0, 10)} (${m.account}/${m.mailbox})`,
			);
			return textResult(`${msgs.length} message(s):\n${lines.join("\n")}`, { count: msgs.length, messages: msgs });
		},
	});

	pi.registerTool({
		...makeRender("search", "query"),
		name: "search_emails",
		label: "Search Emails",
		description:
			"Search emails by text across subject, sender, and body — e.g. 'flight confirmation', 'invoice'. Returns id, subject, sender, date, account, mailbox, optional snippet. Read-only. Use to find a specific email the user references.",
		promptSnippet: "Search emails by text across subject, sender, and body (read-only).",
		parameters: Type.Object({
			query: Type.String({ description: "Free-text search term (case-insensitive)." }),
			mailbox: Type.Optional(Type.String({ description: "Restrict to one mailbox (default INBOX)." })),
			account: Type.Optional(Type.String({ description: "Restrict to one account." })),
			limit: Type.Optional(Type.Number({ description: "How many to return (default 10, max 30)." })),
			withSnippet: Type.Optional(Type.Boolean({ description: "Include a body snippet in results." })),
		}),
		async execute(_id, params) {
			const r = await runOSA(JXA_LIST, {
				query: params.query,
				mailbox: params.mailbox ?? "INBOX",
				account: params.account,
				limit: params.limit ?? 10,
				unreadOnly: false,
				withSnippet: params.withSnippet ?? false,
			});
			const msgs = (r.messages as Array<Record<string, unknown>>) ?? [];
			if (msgs.length === 0) return textResult(`No matches for "${params.query}".`, { count: 0 });
			const lines = msgs.map((m) => {
				let line = `- **[${m.subject || "(no subject)"}](id:\`${m.id}\`)** — ${m.from} — ${String(m.date).slice(0, 10)} (${m.account}/${m.mailbox})`;
				if (typeof m.snippet === "string" && m.snippet) line += `\n  > ${m.snippet}`;
				return line;
			});
			return textResult(`${msgs.length} match(es) for "${params.query}":\n${lines.join("\n")}`, { count: msgs.length, messages: msgs });
		},
	});

	pi.registerTool({
		...makeRender("read", "messageId"),
		name: "read_email",
		label: "Read Email",
		description:
			"Read a full email by id (from list_emails/search_emails). Returns subject, from, to, cc, date, and the plain-text body. Read-only.",
		promptSnippet: "Read the full body of an email by id.",
		parameters: Type.Object({
			messageId: Type.String({ description: "The message id returned by list_emails or search_emails." }),
			mailbox: Type.Optional(Type.String({ description: "Mailbox the message lives in (speeds lookup; will search common mailboxes if omitted)." })),
			account: Type.Optional(Type.String({ description: "Account the message lives in." })),
		}),
		async execute(_id, params) {
			const r = await runOSA(JXA_GET, {
				messageId: params.messageId,
				mailbox: params.mailbox,
				account: params.account,
			});
			const body = (r.body as string) || "";
			return textResult(
				`**${r.subject ?? "(no subject)"}**\nFrom: ${r.from ?? "?"}\nTo: ${r.to ?? ""}${r.cc ? `\nCc: ${r.cc}` : ""}\nDate: ${(r.date as string)?.slice(0, 16) ?? "?"}\nAccount: ${r.account}/${r.mailbox}\n\n${body.slice(0, 12_000)}${body.length > 12_000 ? "\n… [truncated]" : ""}`,
				{ message: r },
			);
		},
	});

	pi.registerTool({
		...makeRender("compose", "subject"),
		name: "compose_email",
		label: "Compose Email Draft",
		description:
			"Create an email draft (NOT sent) so the user can review it before sending. Returns the draft's id for send_draft. Use for any email the agent writes on the user's behalf.",
		promptSnippet: "Draft an email for the user to review (never sends).",
		promptGuidelines: emailGuidelines,
		parameters: Type.Object({
			to: Type.String({ description: "Comma-separated recipient addresses." }),
			subject: Type.String({ description: "Subject line." }),
			body: Type.String({ description: "Plain-text body." }),
			cc: Type.Optional(Type.String({ description: "Comma-separated CC addresses." })),
		}),
		async execute(_id, params) {
			const r = await runOSA(JXA_DRAFT, { to: params.to, subject: params.subject, body: params.body, cc: params.cc });
			return textResult(
				`Draft created (not sent): **${r.subject}**\nTo: ${params.to}\nDraft id: \`${r.id}\` (send with send_draft, or review/edit in Mail.app itself)`,
				{ draft: r },
			);
		},
	});

	pi.registerTool({
		...makeRender("send", "subject"),
		name: "send_draft",
		label: "Send Draft",
		description:
			"Send a previously composed draft by its id (from compose_email). Only use when the user explicitly confirms sending. Returns success/failure.",
		promptSnippet: "Send a compose_email draft by id (only with explicit user confirmation).",
		promptGuidelines: emailGuidelines,
		parameters: Type.Object({
			messageId: Type.String({ description: "The draft id from compose_email." }),
			subject: Type.Optional(Type.String({ description: "Fallback: subject of the draft to match if the id can't be found." })),
			account: Type.Optional(Type.String({ description: "Account holding the draft (optional)." })),
			mailbox: Type.Optional(Type.String({ description: "Mailbox holding the draft (optional)." })),
		}),
		async execute(_id, params) {
			const r = await runOSA(JXA_SEND_DRAFT, {
				messageId: params.messageId,
				subject: params.subject,
				account: params.account,
				mailbox: params.mailbox,
			});
			return textResult(`Sent: id \`${r.id}\` (${r.mailbox ?? "?"}/${r.account ?? "?"})${r.matchedBy ? " [matched by subject]" : ""}`, { sent: r });
		},
	});

	pi.registerTool({
		...makeRender("send", "to"),
		name: "send_email",
		label: "Send Email",
		description:
			"Send an email immediately from the user's default Mail account. ONLY for cases where the user explicitly asked to send right now — otherwise compose_email first and let them review.",
		promptSnippet: "Send an email immediately (only with explicit user request).",
		promptGuidelines: emailGuidelines,
		parameters: Type.Object({
			to: Type.String({ description: "Comma-separated recipient addresses." }),
			subject: Type.String({ description: "Subject line." }),
			body: Type.String({ description: "Plain-text body." }),
			cc: Type.Optional(Type.String({ description: "Comma-separated CC addresses." })),
		}),
		async execute(_id, params) {
			const r = await runOSA(JXA_SEND, { to: params.to, subject: params.subject, body: params.body, cc: params.cc });
			return textResult(`Sent: **${r.subject}** to ${params.to}`, { sent: r });
		},
	});

	// ── Diagnostics command: /icloud-status ───────────────────────────────────
	pi.registerCommand("icloud-status", {
		description: "Check ALFRED calendar + email integration (helper build, permissions, config)",
		handler: async (_args, ctx) => {
			const cfg = loadConfig();
			const lines: string[] = [];
			lines.push(`Config: calendarName=${cfg.calendarName}`);
			lines.push(`Helper: ${HELPER_BIN} ${fs.existsSync(HELPER_BIN) ? "(compiled)" : "(not compiled yet — will build on first use)"}`);
			const cal = await runHelper(["list-calendars"]);
			if (cal.ok) {
				lines.push(`Calendar access: OK (${(cal.data.calendars as unknown[]).length} calendars)`);
			} else {
				lines.push(`Calendar access: ${cal.error}`);
			}
			try {
				const mail = await runOSA(JXA_LIST, { query: "", mailbox: "INBOX", limit: 1 });
				const n = (mail.messages as unknown[])?.length ?? 0;
				lines.push(`Mail access: OK (INBOX readable, ${n} sampled)`);
			} catch (e) {
				lines.push(`Mail access: ${(e as Error).message.split("\n")[0]}`);
			}
			lines.push(`Setup docs: ${PKG_DIR}/README.md`);
			ctx.ui.setWidget("icloud-status", lines, { placement: "belowEditor" });
		},
	});
}
