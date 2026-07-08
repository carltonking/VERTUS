// Multi-account mail — the cloud stand-in for the Mac's Apple Mail reader. Reads recent INBOX messages
// over IMAP and sends replies over SMTP, for one or more accounts configured by env. iCloud and personal
// Gmail both work with an app-specific password (no OAuth): iCloud reuses the same APPLE_APP_PASSWORD as
// CalDAV; Gmail needs 2-Step Verification + an app password.
//
// Env:
//   iCloud → APPLE_ID + APPLE_APP_PASSWORD (or MAIL_ICLOUD_APP_PASSWORD to use a different one)
//   Gmail  → GMAIL_ADDRESS + GMAIL_APP_PASSWORD
//   extra  → MAIL_ACCOUNTS = JSON array of {label,user,pass,imapHost,imapPort?,smtpHost?,smtpPort?}

import { ImapFlow } from "imapflow";
import nodemailer from "nodemailer";

export interface MailAccount {
  label: string;
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
  user: string; // full email address
  pass: string; // app-specific password
}

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

export function getAccounts(): MailAccount[] {
  const accts: MailAccount[] = [];

  const appleUser = process.env.APPLE_ID;
  const applePass = process.env.MAIL_ICLOUD_APP_PASSWORD || process.env.APPLE_APP_PASSWORD;
  if (appleUser && applePass) {
    accts.push({ label: "iCloud", imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587, user: appleUser, pass: applePass });
  }

  const gUser = process.env.GMAIL_ADDRESS;
  const gPass = process.env.GMAIL_APP_PASSWORD;
  if (gUser && gPass) {
    accts.push({ label: "Gmail", imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 587, user: gUser, pass: gPass });
  }

  try {
    const extra = process.env.MAIL_ACCOUNTS ? JSON.parse(process.env.MAIL_ACCOUNTS) : [];
    if (Array.isArray(extra)) {
      for (const a of extra) {
        if (a?.user && a?.pass && a?.imapHost) {
          accts.push({
            label: a.label || a.user,
            imapHost: a.imapHost,
            imapPort: a.imapPort || 993,
            smtpHost: a.smtpHost || a.imapHost.replace(/^imap/, "smtp"),
            smtpPort: a.smtpPort || 587,
            user: a.user,
            pass: a.pass,
          });
        }
      }
    }
  } catch {
    /* ignore malformed MAIL_ACCOUNTS */
  }

  return accts;
}

export function mailConfigured(): boolean {
  return getAccounts().length > 0;
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

/** Recent messages across ALL configured accounts, newest first. Per-account failures are skipped. */
export async function fetchAllRecent(opts: { max?: number; sinceHours?: number; unseenOnly?: boolean } = {}): Promise<MailMsg[]> {
  const results = await Promise.all(
    getAccounts().map((a) => fetchRecent(a, opts).catch(() => [] as MailMsg[])),
  );
  return results.flat().sort((a, b) => b.date.localeCompare(a.date));
}

/** Send a reply from `accountLabel` (defaults to the first account). Throws on SMTP failure. */
export async function sendMail(
  accountLabel: string,
  opts: { to: string; subject: string; text: string; inReplyTo?: string; references?: string },
): Promise<void> {
  const acct = getAccounts().find((a) => a.label === accountLabel) || getAccounts()[0];
  if (!acct) throw new Error("no mail account configured");
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
