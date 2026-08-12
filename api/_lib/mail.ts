// Multi-account mail — the cloud stand-in for the Mac's Apple Mail reader. Reads recent INBOX messages
// over IMAP and sends replies over SMTP. iCloud and personal Gmail both work with an app-specific
// password (no OAuth): iCloud reuses the same APPLE_APP_PASSWORD as CalDAV; Gmail needs 2-Step
// Verification + an app password.
//
// *Which* mailboxes exist is accounts.ts's problem (env-deployed plus the ones added from the phone);
// this file only knows how to talk to one once it's handed over.

import { ImapFlow } from "imapflow";
import nodemailer from "nodemailer";
import { resolveAccounts, type MailAccount } from "./accounts";

export type { MailAccount };

export interface MailMsg {
  account: string; // account label
  uid: number;
  from: string; // display name or address
  fromAddress: string;
  subject: string;
  date: string; // ISO
  messageId?: string;
  snippet: string;
  seen: boolean;
}

async function withClient<T>(acct: MailAccount, fn: (c: ImapFlow) => Promise<T>): Promise<T> {
  const client = new ImapFlow({
    host: acct.imapHost,
    port: acct.imapPort,
    secure: true,
    auth: { user: acct.user, pass: acct.pass },
    logger: false,
  });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    try {
      await client.logout();
    } catch {
      /* best effort */
    }
  }
}

async function streamToString(stream: NodeJS.ReadableStream, maxBytes = 4096): Promise<string> {
  const chunks: Buffer[] = [];
  let total = 0;
  for await (const c of stream) {
    const buf = Buffer.isBuffer(c) ? c : Buffer.from(c as any);
    chunks.push(buf);
    total += buf.length;
    if (total >= maxBytes) break;
  }
  return Buffer.concat(chunks).toString("utf8");
}

/** Walk a bodyStructure for the first usable text part (prefer text/plain, else text/html). */
function firstTextPart(node: any): { part: string; type: string } | null {
  if (!node) return null;
  const type = typeof node.type === "string" ? node.type.toLowerCase() : "";
  if (type.startsWith("text/")) return { part: node.part || "1", type };
  if (Array.isArray(node.childNodes)) {
    for (const c of node.childNodes) {
      const r = firstTextPart(c);
      if (r && r.type === "text/plain") return r;
    }
    for (const c of node.childNodes) {
      const r = firstTextPart(c);
      if (r) return r;
    }
  }
  return null;
}

function stripHtml(s: string): string {
  return s.replace(/<style[\s\S]*?<\/style>/gi, " ").replace(/<[^>]+>/g, " ").replace(/&nbsp;/g, " ").replace(/&amp;/g, "&").replace(/\s+/g, " ").trim();
}

/** Recent INBOX messages for one account, newest first. Best-effort snippet; never throws per-message. */
export async function fetchRecent(acct: MailAccount, opts: { max?: number; sinceHours?: number; unseenOnly?: boolean } = {}): Promise<MailMsg[]> {
  const max = opts.max ?? 12;
  const sinceHours = opts.sinceHours ?? 48;
  return withClient(acct, async (client) => {
    const lock = await client.getMailboxLock("INBOX");
    try {
      const criteria: Record<string, unknown> = { since: new Date(Date.now() - sinceHours * 3600_000) };
      if (opts.unseenOnly) criteria.seen = false;
      const found = await client.search(criteria, { uid: true });
      const uids = (Array.isArray(found) ? found : []).slice(-max);
      if (!uids.length) return [];

      const out: MailMsg[] = [];
      for await (const msg of client.fetch(uids, { uid: true, envelope: true, flags: true, bodyStructure: true }, { uid: true })) {
        const env = msg.envelope;
        const fromAddr = env?.from?.[0];
        let snippet = "";
        try {
          const tp = firstTextPart(msg.bodyStructure);
          if (tp) {
            const dl = await client.download(String(msg.uid), tp.part, { uid: true });
            if (dl?.content) {
              const raw = await streamToString(dl.content);
              snippet = (tp.type === "text/html" ? stripHtml(raw) : raw).replace(/\s+/g, " ").trim().slice(0, 300);
            }
          }
        } catch {
          /* snippet is optional */
        }
        out.push({
          account: acct.label,
          uid: Number(msg.uid),
          from: fromAddr?.name || fromAddr?.address || "unknown",
          fromAddress: fromAddr?.address || "",
          subject: env?.subject || "(no subject)",
          date: (env?.date instanceof Date ? env.date : new Date()).toISOString(),
          messageId: env?.messageId,
          snippet,
          seen: msg.flags?.has("\\Seen") ?? false,
        });
      }
      return out.reverse(); // newest first
    } finally {
      lock.release();
    }
  });
}

export interface AccountFailure {
  account: string;
  error: string;
}

/**
 * Recent messages across ALL accounts, newest first, *with* the per-account failures.
 *
 * The failures matter: one bad app password silently contributing zero messages looks exactly like a
 * quiet inbox, and the owner has no way to tell those apart from a phone. Callers that genuinely
 * don't care can use `fetchAllRecent`.
 */
export async function fetchAllRecentDetailed(
  opts: { max?: number; sinceHours?: number; unseenOnly?: boolean } = {},
): Promise<{ messages: MailMsg[]; failures: AccountFailure[] }> {
  const accounts = await resolveAccounts();
  const failures: AccountFailure[] = [];

  const results = await Promise.all(
    accounts.map((a) =>
      fetchRecent(a, opts).catch((e: any) => {
        failures.push({ account: a.label, error: String(e?.message ?? e) });
        return [] as MailMsg[];
      }),
    ),
  );

  return { messages: results.flat().sort((a, b) => b.date.localeCompare(a.date)), failures };
}

/** Recent messages across ALL configured accounts, newest first. Per-account failures are skipped. */
export async function fetchAllRecent(opts: { max?: number; sinceHours?: number; unseenOnly?: boolean } = {}): Promise<MailMsg[]> {
  return (await fetchAllRecentDetailed(opts)).messages;
}

async function accountByLabel(label: string): Promise<MailAccount> {
  const accounts = await resolveAccounts();
  const acct = accounts.find((a) => a.label === label) || accounts[0];
  if (!acct) throw new Error("no mail account configured");
  return acct;
}

/**
 * The readable body of one message. Kept separate from `fetchRecent` because pulling full bodies for
 * a whole inbox is slow and mostly wasted — the list only ever shows the snippet.
 */
export async function fetchBody(accountLabel: string, uid: number): Promise<string> {
  const acct = await accountByLabel(accountLabel);
  return withClient(acct, async (client) => {
    const lock = await client.getMailboxLock("INBOX");
    try {
      const msg = await client.fetchOne(String(uid), { uid: true, bodyStructure: true }, { uid: true });
      if (!msg) throw new Error("that message is no longer in the inbox");

      const part = firstTextPart((msg as any).bodyStructure);
      if (!part) return "(this message has no text part — it's probably an attachment or an image-only mail)";

      const dl = await client.download(String(uid), part.part, { uid: true });
      if (!dl?.content) return "(couldn't download the message body)";

      const raw = await streamToString(dl.content, 256 * 1024);
      const text = part.type === "text/html" ? stripHtml(raw) : raw;
      return text.replace(/\r\n/g, "\n").trim() || "(empty message)";
    } finally {
      lock.release();
    }
  });
}

/** Mark a message read, so opening it on the phone agrees with every other mail client. */
export async function markSeen(accountLabel: string, uid: number): Promise<void> {
  const acct = await accountByLabel(accountLabel);
  await withClient(acct, async (client) => {
    const lock = await client.getMailboxLock("INBOX");
    try {
      await client.messageFlagsAdd(String(uid), ["\\Seen"], { uid: true });
    } finally {
      lock.release();
    }
  });
}

/** Send a reply from `accountLabel` (defaults to the first account). Throws on SMTP failure. */
export async function sendMail(
  accountLabel: string,
  opts: { to: string; subject: string; text: string; inReplyTo?: string; references?: string },
): Promise<void> {
  const acct = await accountByLabel(accountLabel);
  const transport = nodemailer.createTransport({
    host: acct.smtpHost,
    port: acct.smtpPort,
    secure: false, // 587 → STARTTLS
    requireTLS: true,
    auth: { user: acct.user, pass: acct.pass },
  });
  await transport.sendMail({
    from: acct.user,
    to: opts.to,
    subject: opts.subject,
    text: opts.text,
    inReplyTo: opts.inReplyTo,
    references: opts.references,
  });
}
