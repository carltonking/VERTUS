// The IMAP operations a real mail client needs: folders, paged listing, search, full bodies with
// attachments, flag changes, and moves.
//
// Separate from mail.ts on purpose. mail.ts serves the Telegram triage flow — "the last 12 things,
// summarised" — and its shape is right for that. A message list needs to page arbitrarily far back,
// address any mailbox rather than just INBOX, and act on messages, which is a different job.
//
// Nothing here expunges. Every destructive-looking action is a move to Trash, matching what Mail's
// bin button actually does, because a swipe is far too cheap a gesture to be irreversible.

import { ImapFlow } from "imapflow";
import nodemailer from "nodemailer";
import { resolveAccounts, type MailAccount } from "./accounts";
import { googleAccessToken } from "./oauth";
import { vipAddresses } from "./vip";

export interface MailboxInfo {
  account: string;
  path: string;
  name: string;
  role: string;
  unseen: number;
  total: number;
}

export interface MessageInfo {
  account: string;
  mailbox: string;
  uid: number;
  from: string;
  fromAddress: string;
  to: string[];
  subject: string;
  date: string;
  messageId?: string;
  snippet: string;
  seen: boolean;
  flagged: boolean;
  hasAttachments: boolean;
}

export interface AttachmentInfo {
  part: string;
  filename: string;
  size: number;
  mime: string;
}

export interface Failure {
  account: string;
  error: string;
}

const SNIPPET_BYTES = 4096;
const BODY_BYTES = 512 * 1024;

// MARK: - Connections

/** How one account logs in: XOAUTH2 for Google-signed accounts, a password for anything else. */
async function imapAuth(acct: MailAccount): Promise<{ user: string; pass?: string; accessToken?: string }> {
  if (acct.auth === "oauth" && acct.refreshToken) {
    return { user: acct.user, accessToken: await googleAccessToken(acct.refreshToken) };
  }
  return { user: acct.user, pass: acct.pass };
}

async function withClient<T>(acct: MailAccount, fn: (c: ImapFlow) => Promise<T>): Promise<T> {
  const auth = await imapAuth(acct);
  const client = new ImapFlow({
    host: acct.imapHost,
    port: acct.imapPort,
    secure: true,
    auth,
    logger: false,
  });
  await client.connect();
  try {
    return await fn(client);
  } finally {
    try {
      await client.logout();
    } catch {
      /* best effort — the answer is already in hand */
    }
  }
}

async function accountFor(label: string): Promise<MailAccount> {
  const accounts = await resolveAccounts();
  const found = accounts.find((a) => a.label === label);
  if (!found) throw new Error(`no account called “${label}”`);
  return found;
}

// MARK: - Parsing helpers

async function streamToString(stream: NodeJS.ReadableStream, maxBytes: number): Promise<string> {
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

function stripHtml(s: string): string {
  return s
    .replace(/<style[\s\S]*?<\/style>/gi, " ")
    .replace(/<script[\s\S]*?<\/script>/gi, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/&nbsp;/g, " ")
    .replace(/&amp;/g, "&")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/\s+/g, " ")
    .trim();
}

interface PartRef {
  part: string;
  type: string;
  filename?: string;
  size: number;
  isAttachment: boolean;
}

/** Flatten a bodyStructure into the leaf parts, tagging which are attachments. */
function collectParts(node: any, out: PartRef[] = []): PartRef[] {
  if (!node) return out;
  const type = typeof node.type === "string" ? node.type.toLowerCase() : "";

  if (Array.isArray(node.childNodes) && node.childNodes.length) {
    for (const child of node.childNodes) collectParts(child, out);
    return out;
  }

  const filename = node.dispositionParameters?.filename || node.parameters?.name;
  const disposition = String(node.disposition || "").toLowerCase();
  out.push({
    part: node.part || "1",
    type,
    filename,
    size: Number(node.size || 0),
    // Inline images with no filename are part of the body, not something to list as an attachment.
    isAttachment: disposition === "attachment" || (!!filename && !type.startsWith("multipart")),
  });
  return out;
}

function addressList(list: any): string[] {
  if (!Array.isArray(list)) return [];
  return list.map((a: any) => a?.name || a?.address || "").filter(Boolean);
}

/**
 * The body parts worth asking for alongside the envelope. Covers a single-part message ("1") and the
 * first branches of a multipart/alternative, which between them are nearly every real email. A
 * message whose text lives somewhere stranger simply gets no preview — cheaper than a second round
 * trip per message, which is exactly what this replaced.
 */
const PREVIEW_PARTS = ["1", "1.1", "1.2"];

function previewFrom(msg: any): string {
  const map: Map<string, Buffer> | undefined = msg.bodyParts;
  if (!map || !map.size) return "";

  const parts = collectParts(msg.bodyStructure);
  const text =
    parts.find((p) => p.type === "text/plain" && !p.isAttachment) ??
    parts.find((p) => p.type.startsWith("text/") && !p.isAttachment);

  const buf =
    (text ? map.get(text.part) : undefined) ?? map.get("1") ?? map.get("1.1") ?? map.get("1.2");
  if (!buf) return "";

  const raw = buf.toString("utf8").slice(0, SNIPPET_BYTES);
  const isHtml = text?.type === "text/html" || /<[a-z][\s\S]*>/i.test(raw);
  return (isHtml ? stripHtml(raw) : raw).replace(/\s+/g, " ").trim().slice(0, 300);
}

/** A message plus where it sat, so the cursor can resume from whatever survived the merge. */
interface Positioned extends MessageInfo {
  pos: number;
}

function toMessageInfo(msg: any, account: string, mailbox: string, snippet: string, pos = 0): Positioned {
  const env = msg.envelope ?? {};
  const fromAddr = env.from?.[0];
  const parts = collectParts(msg.bodyStructure);
  return {
    account,
    mailbox,
    uid: Number(msg.uid),
    from: fromAddr?.name || fromAddr?.address || "unknown",
    fromAddress: fromAddr?.address || "",
    to: addressList(env.to),
    subject: env.subject || "(no subject)",
    date: (env.date instanceof Date ? env.date : new Date()).toISOString(),
    messageId: env.messageId,
    snippet,
    seen: msg.flags?.has("\\Seen") ?? false,
    flagged: msg.flags?.has("\\Flagged") ?? false,
    hasAttachments: parts.some((p) => p.isAttachment),
    pos,
  };
}

// MARK: - Mailboxes

function roleFor(path: string, specialUse?: string): string {
  if (path.toUpperCase() === "INBOX") return "inbox";
  switch (specialUse) {
    case "\\Sent": return "sent";
    case "\\Drafts": return "drafts";
    case "\\Trash": return "trash";
    case "\\Junk": return "junk";
    case "\\Archive": return "archive";
    default: return "folder";
  }
}

export async function listMailboxes(): Promise<{ mailboxes: MailboxInfo[]; failures: Failure[] }> {
  const accounts = await resolveAccounts();
  const failures: Failure[] = [];

  const perAccount = await Promise.all(
    accounts.map(async (acct) => {
      try {
        return await withClient(acct, async (client) => {
          const listed = await client.list();
          const out: MailboxInfo[] = [];

          for (const box of listed) {
            // \Noselect folders are pure containers ("[Gmail]") — opening one is an error, and
            // showing a row that can't be tapped is worse than not showing it.
            if (box.flags?.has("\\Noselect")) continue;

            let unseen = 0;
            let total = 0;
            try {
              const status = await client.status(box.path, { unseen: true, messages: true });
              unseen = Number(status.unseen || 0);
              total = Number(status.messages || 0);
            } catch {
              /* a folder that won't report counts is still worth listing */
            }

            out.push({
              account: acct.label,
              path: box.path,
              name: box.name || box.path,
              role: roleFor(box.path, box.specialUse),
              unseen,
              total,
            });
          }
          return out;
        });
      } catch (e: any) {
        failures.push({ account: acct.label, error: String(e?.message ?? e) });
        return [] as MailboxInfo[];
      }
    }),
  );

  return { mailboxes: perAccount.flat(), failures };
}

export interface SmartCounts {
  flaggedUnseen: number;
  vipUnseen: number;
  accusedFault?: string;
}

/**
 * Unread counts for the two smart mailboxes, summed across INBOX of every account — the same rows
 * the mailbox list shows them in. Failures are per-count and non-fatal: a single flaky account
 * shouldn't blank the numbers the rest could produce.
 */
export async function smartCounts(): Promise<SmartCounts> {
  const accounts = await resolveAccounts();
  const vips = await vipAddresses();
  const results = await Promise.all(
    accounts.map(async (acct) => {
      const out = { flaggedUnseen: 0, vipUnseen: 0 };
      try {
        return await withClient(acct, async (client) => {
          const lock = await client.getMailboxLock("INBOX");
          try {
            const critFlagged: Record<string, unknown> = { seen: false, flagged: true };
            const flagged = await client.search(critFlagged, { uid: true });
            out.flaggedUnseen = Array.isArray(flagged) ? flagged.length : 0;

            if (vips.length) {
              const critVip: Record<string, unknown> = {
                seen: false,
                or: vips.map((address) => ({ from: address })),
              };
              const vip = await client.search(critVip, { uid: true });
              out.vipUnseen = Array.isArray(vip) ? vip.length : 0;
            }
            return out;
          } finally {
            lock.release();
          }
        });
      } catch {
        return out;
      }
    }),
  );

  return results.reduce(
    (acc, r) => ({
      flaggedUnseen: acc.flaggedUnseen + r.flaggedUnseen,
      vipUnseen: acc.vipUnseen + r.vipUnseen,
    }),
    { flaggedUnseen: 0, vipUnseen: 0 },
  );
}

// MARK: - Listing messages

/**
 * The paging cursor: one position per account, meaning "the next page ends here".
 *
 * Opaque to the client by design — it holds a position per account, and All Inboxes advances those
 * at different rates depending on which account the merged page actually drew from.
 *
 * What the number *means* depends on how the page was gathered. A plain listing walks backwards
 * through sequence numbers; a search walks backwards through the UIDs it matched. Both stay
 * consistent for the life of one scroll, and a pull-to-refresh throws the cursor away, so the two
 * interpretations never meet.
 */
type Cursor = Record<string, number>;

function decodeCursor(raw?: string): Cursor {
  if (!raw) return {};
  try {
    const parsed = JSON.parse(Buffer.from(raw, "base64").toString("utf8"));
    return parsed && typeof parsed === "object" ? (parsed as Cursor) : {};
  } catch {
    return {};
  }
}

function encodeCursor(cursor: Cursor): string {
  return Buffer.from(JSON.stringify(cursor), "utf8").toString("base64");
}

export interface ListOptions {
  account?: string;
  mailbox?: string;
  limit: number;
  cursor?: string;
  search?: string;
  unreadOnly?: boolean;
  flaggedOnly?: boolean;
  /** Filter to senders on the VIP list. Matched by the server, since the phone shouldn't have to
   *  carry (or be trusted with) the VIP list to ask for it. */
  vipOnly?: boolean;
}

export async function listMessages(opts: ListOptions): Promise<{
  messages: MessageInfo[];
  failures: Failure[];
  hasMore: boolean;
  cursor: string | null;
}> {
  const all = await resolveAccounts();
  const accounts = opts.account ? all.filter((a) => a.label === opts.account) : all;
  const limit = Math.min(Math.max(opts.limit || 50, 1), 100);
  const incoming = decodeCursor(opts.cursor);
  const failures: Failure[] = [];

  // Only the unified view spans accounts; a named mailbox belongs to exactly one.
  const mailboxPath = opts.mailbox || "INBOX";

  const results = await Promise.all(
    accounts.map(async (acct) => {
      try {
        return await withClient(acct, async (client) => {
          const lock = await client.getMailboxLock(mailboxPath);
          try {
            const from = incoming[acct.label];
            const filtered = !!(opts.search || opts.unreadOnly || opts.flaggedOnly || opts.vipOnly);

            let range: string;
            let byUid: boolean;
            let remaining: number;

            if (filtered) {
              const criteria: Record<string, unknown> = {};
              if (opts.unreadOnly) criteria.seen = false;
              if (opts.flaggedOnly) criteria.flagged = true;

              // Both criteria can be essential: a VIP search narrows by sender, and the subject/from/... 
              // OR below broadens for text search. ImapFlow folds an "or" list together with AND, so
              // sending both means VIP AND (subject OR from OR …) — exactly the smart-mailbox shape.
              const orClauses: Record<string, unknown>[] = [];
              if (opts.vipOnly) {
                const vips = await vipAddresses();
                if (!vips.length) return { messages: [] as Positioned[], remaining: 0, account: acct.label, byUid: true };
                for (const address of vips) orClauses.push({ from: address });
              }

              if (opts.search) {
                orClauses.push(
                  { subject: opts.search },
                  { from: opts.search },
                  { to: opts.search },
                  { body: opts.search },
                );
              }

              const found = await client.search({ ...criteria, or: orClauses }, { uid: true });
              let uids = (Array.isArray(found) ? found : []).slice().sort((a, b) => a - b);
              // UIDs rise strictly with arrival, so "below the cursor" is exactly "older than the
              // last page" without having to know any message's date.
              if (typeof from === "number") uids = uids.filter((u) => u < from);
              if (!uids.length) return { messages: [] as Positioned[], remaining: 0, account: acct.label, byUid: filtered };

              const window = uids.slice(-limit);
              remaining = uids.length - window.length;
              range = window.join(",");
              byUid = true;
            } else {
              // No SEARCH at all for the ordinary case. Asking a 20,000-message inbox to enumerate
              // every UID just to keep the last fifty is what made this time out; sequence numbers
              // are already ordered oldest-to-newest, so the newest page is simply the tail.
              const total = Number((client.mailbox as any)?.exists || 0);
              const end = typeof from === "number" ? Math.min(from, total) : total;
              if (end <= 0) return { messages: [] as Positioned[], remaining: 0, account: acct.label, byUid: filtered };

              const start = Math.max(1, end - limit + 1);
              remaining = start - 1;
              range = `${start}:${end}`;
              byUid = false;
            }

            const messages: Positioned[] = [];
            // One FETCH for everything, previews included. Downloading each body separately was the
            // other half of the timeout: fifty messages meant fifty extra round trips.
            for await (const msg of client.fetch(
              range,
              { uid: true, envelope: true, flags: true, bodyStructure: true, bodyParts: PREVIEW_PARTS },
              byUid ? { uid: true } : undefined,
            )) {
              messages.push(
                toMessageInfo(msg, acct.label, mailboxPath, previewFrom(msg), byUid ? Number(msg.uid) : Number(msg.seq)),
              );
            }

            return { messages, remaining, account: acct.label, byUid };
          } finally {
            lock.release();
          }
        });
      } catch (e: any) {
        failures.push({ account: acct.label, error: String(e?.message ?? e) });
        return { messages: [] as Positioned[], remaining: 0, account: acct.label, byUid: false };
      }
    }),
  );

  // Merge newest-first, then cut to one page. Each account contributed up to `limit`, so the merged
  // set can be larger; the cursor below records only what actually survived the cut, which is what
  // stops the next page from skipping whatever got trimmed here.
  const merged = results
    .flatMap((r) => r.messages)
    .sort((a, b) => b.date.localeCompare(a.date));
  const page = merged.slice(0, limit);

  const outgoing: Cursor = { ...incoming };
  for (const result of results) {
    const returned = page.filter((m) => m.account === result.account);
    if (!returned.length) continue;
    const oldest = Math.min(...returned.map((m) => m.pos));
    // UID paging filters strictly below the cursor, so the oldest UID kept is already the right
    // exclusive bound. Sequence paging treats the cursor as an inclusive upper bound, so it has to
    // step one past the oldest row — otherwise every page would repeat its last message forever.
    outgoing[result.account] = result.byUid ? oldest : oldest - 1;
  }

  const trimmed = merged.length > page.length;
  const hasMore = trimmed || results.some((r) => r.remaining > 0);

  // `pos` is bookkeeping, not something the client should see or come to depend on.
  const messages: MessageInfo[] = page.map(({ pos, ...rest }) => rest);

  return { messages, failures, hasMore, cursor: hasMore ? encodeCursor(outgoing) : null };
}

// MARK: - One message

export async function readMessage(
  accountLabel: string,
  mailbox: string,
  uid: number,
): Promise<{ message: MessageInfo; html: string | null; text: string; attachments: AttachmentInfo[] }> {
  const acct = await accountFor(accountLabel);
  return withClient(acct, async (client) => {
    const lock = await client.getMailboxLock(mailbox);
    try {
      const msg = await client.fetchOne(
        String(uid),
        { uid: true, envelope: true, flags: true, bodyStructure: true },
        { uid: true },
      );
      if (!msg) throw new Error("that message is no longer there");

      const parts = collectParts((msg as any).bodyStructure);
      const htmlPart = parts.find((p) => p.type === "text/html" && !p.isAttachment);
      const textPart = parts.find((p) => p.type === "text/plain" && !p.isAttachment);

      const download = async (part?: PartRef): Promise<string> => {
        if (!part) return "";
        try {
          const dl = await client.download(String(uid), part.part, { uid: true });
          return dl?.content ? await streamToString(dl.content, BODY_BYTES) : "";
        } catch {
          return "";
        }
      };

      const html = await download(htmlPart);
      const rawText = await download(textPart);
      // Plain text is always produced, even for HTML-only mail: replies quote it, and Alfred drafts
      // from it. Falling back to stripped HTML beats quoting an empty string.
      const text = (rawText || stripHtml(html) || "(no readable text in this message)").replace(/\r\n/g, "\n");

      const attachments: AttachmentInfo[] = parts
        .filter((p) => p.isAttachment)
        .map((p) => ({
          part: p.part,
          filename: p.filename || "attachment",
          size: p.size,
          mime: p.type || "application/octet-stream",
        }));

      const snippet = (rawText ? rawText : stripHtml(html)).replace(/\s+/g, " ").trim().slice(0, 300);
      const { pos, ...message } = toMessageInfo(msg, accountLabel, mailbox, snippet);

      return {
        message,
        html: html || null,
        text,
        attachments,
      };
    } finally {
      lock.release();
    }
  });
}

// MARK: - Acting

export async function setFlags(
  accountLabel: string,
  mailbox: string,
  uids: number[],
  flags: { seen?: boolean; flagged?: boolean },
): Promise<void> {
  if (!uids.length) return;
  const acct = await accountFor(accountLabel);
  await withClient(acct, async (client) => {
    const lock = await client.getMailboxLock(mailbox);
    try {
      const range = uids.join(",");
      if (flags.seen === true) await client.messageFlagsAdd(range, ["\\Seen"], { uid: true });
      if (flags.seen === false) await client.messageFlagsRemove(range, ["\\Seen"], { uid: true });
      if (flags.flagged === true) await client.messageFlagsAdd(range, ["\\Flagged"], { uid: true });
      if (flags.flagged === false) await client.messageFlagsRemove(range, ["\\Flagged"], { uid: true });
    } finally {
      lock.release();
    }
  });
}

/** Resolve where "trash"/"archive"/"junk" actually live for this account — providers disagree. */
async function pathForRole(client: ImapFlow, role: string): Promise<string | null> {
  const wanted: Record<string, string> = {
    trash: "\\Trash",
    archive: "\\Archive",
    junk: "\\Junk",
    sent: "\\Sent",
    drafts: "\\Drafts",
  };
  const flag = wanted[role];
  const listed = await client.list();

  const bySpecialUse = listed.find((b) => b.specialUse === flag);
  if (bySpecialUse) return bySpecialUse.path;

  // Gmail exposes Archive as "All Mail"; several providers just name the folder in English.
  const byName = listed.find((b) => b.name.toLowerCase() === role || b.path.toLowerCase().endsWith(role));
  if (byName) return byName.path;
  if (role === "archive") {
    const allMail = listed.find((b) => b.specialUse === "\\All" || /all mail/i.test(b.name));
    if (allMail) return allMail.path;
  }
  return null;
}

export async function moveMessages(
  accountLabel: string,
  mailbox: string,
  uids: number[],
  role: string,
): Promise<void> {
  if (!uids.length) return;
  const acct = await accountFor(accountLabel);
  await withClient(acct, async (client) => {
    const target = await pathForRole(client, role);
    if (!target) throw new Error(`${acct.label} has no ${role} folder`);
    if (target === mailbox) return;

    const lock = await client.getMailboxLock(mailbox);
    try {
      await client.messageMove(uids.join(","), target, { uid: true });
    } finally {
      lock.release();
    }
  });
}

// MARK: - Sending

async function smtpAuth(acct: MailAccount): Promise<object> {
  if (acct.auth === "oauth" && acct.refreshToken) {
    return { type: "OAuth2", user: acct.user, accessToken: await googleAccessToken(acct.refreshToken) };
  }
  return { user: acct.user, pass: acct.pass };
}

export async function sendMessage(
  accountLabel: string,
  opts: { to: string; cc?: string; subject: string; text: string; inReplyTo?: string },
): Promise<void> {
  const acct = await accountFor(accountLabel);
  const transport = nodemailer.createTransport({
    host: acct.smtpHost,
    port: acct.smtpPort,
    secure: false, // 587 → STARTTLS
    requireTLS: true,
    auth: await smtpAuth(acct),
  });

  await transport.sendMail({
    from: acct.user,
    to: opts.to,
    cc: opts.cc || undefined,
    subject: opts.subject,
    text: opts.text,
    inReplyTo: opts.inReplyTo,
    references: opts.inReplyTo,
  });
}
