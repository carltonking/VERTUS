// /email command flow — triage recent mail across accounts, then draft-and-confirm replies. Read is
// safe and runs freely; sending is gated behind an explicit /email send after you see the draft (mirrors
// Alfred's "draft, then confirm" product rule). Per-chat list + pending draft live in Upstash.

import { llmText } from "./llm";
import { fetchAllRecent, sendMail } from "./mail";
import { mailConfigured } from "./accounts";
import { kvGet, kvSet, kvDel } from "./kv";
import type { Reply } from "./reply";

interface StoredMsg {
  n: number;
  account: string;
  from: string;
  fromAddress: string;
  subject: string;
  date: string;
  messageId?: string;
  snippet: string;
}

interface PendingDraft {
  account: string;
  to: string;
  subject: string;
  inReplyTo?: string;
  references?: string;
  body: string;
}

const listKey = (chatId: string) => `mail:list:${chatId}`;
const draftKey = (chatId: string) => `mail:draft:${chatId}`;

const EMAIL_HELP = [
  "Email — read & reply across your inboxes, even with your Mac off:",
  "/email — triage recent mail (what needs you)",
  "/email <n> — show message n",
  "/email reply <n> | <what to say> — draft a reply (you confirm before it sends)",
  "/email send — send the drafted reply",
  "/email cancel — discard the draft",
].join("\n");

const TRIAGE_SYSTEM =
  "You are Alfred triaging Carlton's inbox. Given recent messages across his accounts, write a short, " +
  "scannable triage: lead with anything time-sensitive or that needs a reply, then the rest briefly — one " +
  "line each, prefixed with the list number in brackets like [3]. Plain text, no markdown headers, " +
  "24-hour times. Downplay obvious promos/newsletters. If nothing needs action, say so in one line.";

/** Narrow natural-language trigger so "check my email" works without the slash. */
export function isEmailCheck(text: string): boolean {
  const q = text.toLowerCase();
  if (!/\b(inbox|e-?mails?|mail)\b/.test(q)) return false;
  return /\b(check|any|new|unread|important|what'?s?|show|read|triage|catch me up)\b/.test(q);
}

export async function handleEmail(args: string, reply: Reply, chatKey: string): Promise<void> {
  if (!(await mailConfigured())) {
    return reply("No mailbox is connected yet. Add one in the Alfred app (Email → Accounts), or on the server via APPLE_ID + APPLE_APP_PASSWORD / GMAIL_ADDRESS + GMAIL_APP_PASSWORD.");
  }
  const parts = args.split(/\s+/).filter(Boolean);
  const sub = (parts[0] || "").toLowerCase();

  if (sub === "send" || sub === "yes") return emailSend(reply, chatKey);
  if (sub === "cancel" || sub === "discard" || sub === "no") {
    await kvDel(draftKey(chatKey));
    return reply("Discarded the draft.");
  }
  if (sub === "help") return reply(EMAIL_HELP);
  if (sub === "reply" || sub === "re") return emailDraftReply(args.slice(sub.length).trim(), reply, chatKey);
  if (/^\d+$/.test(sub)) return emailShow(Number(sub), reply, chatKey);
  return emailTriage(reply, chatKey);
}

export async function emailTriage(reply: Reply, chatKey: string): Promise<void> {
  await reply("📬 Checking your inbox…");
  const msgs = await fetchAllRecent({ max: 10, sinceHours: 48 });
  if (!msgs.length) {
    return reply("Nothing in the last 48h — or I couldn't reach your inboxes (check the app-specific passwords).");
  }
  const list: StoredMsg[] = msgs.map((m, i) => ({
    n: i + 1, account: m.account, from: m.from, fromAddress: m.fromAddress,
    subject: m.subject, date: m.date, messageId: m.messageId, snippet: m.snippet,
  }));
  await kvSet(listKey(chatKey), JSON.stringify(list), 2 * 3600);

  const forModel = list
    .map((m) => `[${m.n}] (${m.account}) ${m.from} — ${m.subject}${m.snippet ? `\n    ${m.snippet}` : ""}`)
    .join("\n");
  const triage = await llmText(TRIAGE_SYSTEM, `Today is ${new Date().toISOString().slice(0, 10)}.\n\n${forModel}`, 0.4);
  const footer = "\n\nReply: /email reply <n> | your message · full: /email <n>";
  await reply((triage || `Recent mail:\n\n${forModel}`) + footer);
}

async function emailShow(n: number, reply: Reply, chatKey: string): Promise<void> {
  const list = await loadList(chatKey);
  const m = list.find((x) => x.n === n);
  if (!m) return reply(`I don't have message ${n} — run /email first.`);
  const body = [
    `[${m.n}] ${m.account}`,
    `From: ${m.from}${m.fromAddress ? ` <${m.fromAddress}>` : ""}`,
    `Subject: ${m.subject}`,
    `Date: ${m.date}`,
    "",
    m.snippet || "(no preview available)",
    "",
    `Reply: /email reply ${m.n} | your message`,
  ].join("\n");
  return reply(body);
}

async function emailDraftReply(rest: string, reply: Reply, chatKey: string): Promise<void> {
  const pipe = rest.indexOf("|");
  const nStr = (pipe >= 0 ? rest.slice(0, pipe) : rest).trim();
  const instruction = pipe >= 0 ? rest.slice(pipe + 1).trim() : "";
  const n = Number(nStr);
  if (!Number.isInteger(n)) {
    return reply("Which message? /email reply <number> | <what to say> (see /email).");
  }
  const list = await loadList(chatKey);
  const msg = list.find((x) => x.n === n);
  if (!msg) return reply(`I don't have message ${n} — run /email first.`);
  if (!msg.fromAddress) return reply("That message has no reply address I can use.");

  const system =
    "You are Alfred drafting an email reply for Carlton. Output ONLY the reply body — no subject line, no " +
    "'Draft:' label, no surrounding quotes. Concise and friendly-professional; keep it short unless asked " +
    "otherwise. Sign off as Carlton.";
  const user =
    `Reply to this email.\nFrom: ${msg.from} <${msg.fromAddress}>\nSubject: ${msg.subject}\n` +
    `Excerpt: ${msg.snippet || "(none)"}\n\nCarlton's instruction: ${instruction || "write an appropriate reply"}`;
  const body = ((await llmText(system, user, 0.5)) || "").trim();
  if (!body) return reply("Couldn't draft that just now — try again.");

  const subject = /^re:/i.test(msg.subject) ? msg.subject : `Re: ${msg.subject}`;
  const draft: PendingDraft = { account: msg.account, to: msg.fromAddress, subject, inReplyTo: msg.messageId, references: msg.messageId, body };
  await kvSet(draftKey(chatKey), JSON.stringify(draft), 3600);
  await reply(`📝 Draft reply to ${msg.from} (${msg.account})\nSubject: ${subject}\n\n${body}\n\n— Send it? /email send · redo: /email reply ${n} | <new instruction> · /email cancel`,
  );
}

async function emailSend(reply: Reply, chatKey: string): Promise<void> {
  const raw = await kvGet(draftKey(chatKey));
  if (!raw) return reply("No draft to send. Make one with /email reply <n> | <what to say>.");
  let d: PendingDraft;
  try {
    d = JSON.parse(raw) as PendingDraft;
  } catch {
    await kvDel(draftKey(chatKey));
    return reply("That draft got corrupted — start over with /email reply <n> | …");
  }
  try {
    await sendMail(d.account, { to: d.to, subject: d.subject, text: d.body, inReplyTo: d.inReplyTo, references: d.references });
    await kvDel(draftKey(chatKey));
    await reply(`✅ Sent to ${d.to}.`);
  } catch (e: any) {
    await reply(`Couldn't send: ${String(e?.message ?? e)}. Your draft is kept — try /email send again.`);
  }
}

async function loadList(chatKey: string): Promise<StoredMsg[]> {
  const raw = await kvGet(listKey(chatKey));
  if (!raw) return [];
  try {
    const list = JSON.parse(raw);
    return Array.isArray(list) ? (list as StoredMsg[]) : [];
  } catch {
    return [];
  }
}
