// Alfred's mail front door for the iOS app.
//
//   GET  /api/mail?action=accounts|mailboxes|messages|message
//   POST /api/mail  { "action": "addAccount"|"removeAccount"|"flags"|"move"|"send"|"draft", ... }
//   Authorization: Bearer <APP_TOKEN>
//
// Separate from /api/app because the two answer different questions. /api/app returns one prose
// string meant for a chat bubble; a message list needs rows it can render and act on — senders,
// dates, read state, and the (account, mailbox, uid) triple every subsequent action is addressed by.
// Asking a language model to emit that as JSON would be slower, costlier and less reliable than
// simply reading it off IMAP.
//
// Auth is the same shared secret as /api/app: Alfred has one owner, and this endpoint reaches his
// mailboxes, so it refuses to serve at all when APP_TOKEN is unset.

import type { IncomingMessage, ServerResponse } from "http";
import { randomUUID, timingSafeEqual } from "crypto";
import { accountSummaries, addAccount, removeAccount, addOAuthAccount, PROVIDERS } from "./_lib/accounts";
import { listMailboxes, listMessages, readMessage, setFlags, moveMessages, sendMessage, smartCounts } from "./_lib/mailbox";
import { vipAddresses, setVipAddress } from "./_lib/vip";
import { llmText } from "./_lib/llm";
import { kvGet, kvSet, kvDel } from "./_lib/kv";
import { exchangeOAuthCode, googleAuthUrl, googleUserEmail, googleOAuthConfigured, oauthRedirectUri } from "./_lib/oauth";

const MAX_BODY_BYTES = 256 * 1024;
const OAUTH_STATE_TTL_SECONDS = 30 * 60;

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

function fail(res: ServerResponse, code: number, error: string): void {
  json(res, code, { ok: false, error });
}

/** Constant-time compare that doesn't leak length through an early return. */
function secretsMatch(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) {
    timingSafeEqual(ab, ab);
    return false;
  }
  return timingSafeEqual(ab, bb);
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) {
        reject(new Error("body too large"));
        req.destroy();
        return;
      }
      chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

function uidList(raw: unknown): number[] {
  const list = Array.isArray(raw) ? raw : [raw];
  return list.map((v) => Number(v)).filter((n) => Number.isInteger(n) && n > 0);
}

const DRAFT_SYSTEM =
  "You are Alfred drafting an email reply for Carlton. Output ONLY the reply body — no subject line, " +
  "no 'Draft:' label, no surrounding quotes, no signature block beyond signing off as Carlton. " +
  "Concise and friendly-professional; keep it short unless asked otherwise.";

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  try {
    const url = new URL(req.url || "/", "http://localhost");
    const action = url.searchParams.get("action") || "accounts";

    // Google's consent flows back to this exact endpoint straight from their servers, so it can't
    // carry our Bearer token. It proves its provenance with the one-time `state` we minted behind
    // auth and stored in KV — an origin-less request can't replay it.
    if (action === "googleCallback") return await handleOAuthCallback(req, res);

    const expected = process.env.APP_TOKEN;
    if (!expected) return fail(res, 503, "APP_TOKEN is not configured");

    const header = String(req.headers["authorization"] ?? "");
    const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
    if (!presented || !secretsMatch(presented, expected)) return fail(res, 401, "unauthorized");

    if (req.method === "GET") return await handleGet(req, res);
    if (req.method === "POST") return await handlePost(req, res);
    return fail(res, 405, "GET or POST only");
  } catch (e: any) {
    // This endpoint has exactly one consumer, and a bare 500 on a phone is unfixable. IMAP's own
    // errors ("Invalid credentials", "Mailbox doesn't exist") are the most actionable thing there is.
    return fail(res, 500, String(e?.message ?? e));
  }
}

// MARK: - Reading

async function handleGet(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url || "/", "http://localhost");
  const q = url.searchParams;
  const action = q.get("action") || "accounts";

  switch (action) {
    case "accounts": {
      return json(res, 200, {
        ok: true,
        accounts: await accountSummaries(),
        providers: PROVIDERS,
      });
    }

    case "googleLogin": {
      if (!googleOAuthConfigured()) {
        return fail(res, 503, "Google sign-in isn't configured on the server yet (GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET)");
      }
      const state = randomUUID();
      const redirectUri = oauthRedirectUri(String(req.headers["x-forwarded-host"] || req.headers.host));
      // One-time state: proves the callback came from a flow this deployment minted behind auth, so
      // a stranger can't run their own Google login through our callback and store their mailbox here.
      await kvSet(`google:oauth:${state}`, "1", OAUTH_STATE_TTL_SECONDS);
      const url = googleAuthUrl({ state, redirectUri });
      return json(res, 200, { ok: true, url });
    }

    case "mailboxes": {
      const { mailboxes, failures } = await listMailboxes();
      const smart = await smartCounts();
      return json(res, 200, { ok: true, mailboxes, failures, smart });
    }

    case "messages": {
      const result = await listMessages({
        account: q.get("account") || undefined,
        mailbox: q.get("mailbox") || undefined,
        limit: Number(q.get("limit")) || 50,
        cursor: q.get("cursor") || undefined,
        search: q.get("search") || undefined,
        unreadOnly: q.get("unread") === "1",
        flaggedOnly: q.get("flagged") === "1",
        vipOnly: q.get("vips") === "1",
      });
      return json(res, 200, { ok: true, ...result });
    }

    case "vips": {
      return json(res, 200, { ok: true, vips: await vipAddresses() });
    }

    case "message": {
      const account = q.get("account");
      const mailbox = q.get("mailbox") || "INBOX";
      const uid = Number(q.get("uid"));
      if (!account || !Number.isInteger(uid)) return fail(res, 400, "account and uid are required");

      const { message, html, text, attachments } = await readMessage(account, mailbox, uid);
      return json(res, 200, { ok: true, message, body: { html, text, attachments } });
    }

    default:
      return fail(res, 400, `unknown action “${action}”`);
  }
}

// MARK: - Google OAuth callback

function oauthPage(res: ServerResponse, status: number, heading: string, body: string): void {
  res.statusCode = status;
  res.setHeader("Content-Type", "text/html; charset=utf-8");
  // Escaped before it reaches the page, so nothing Google hands back already reflects.
  const esc = (s: string) => s.replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c] as string));
  res.end(
    `<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">` +
      `<title>Alfred</title></head><body style="font-family:-apple-system,Segoe UI,Roboto,sans-serif;background:#121212;color:#f5f5f7;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0">` +
      `<div style="text-align:center;max-width:420px;padding:24px"><h1 style="font-size:26px">Alfred · Mail</h1>` +
      `<h2 style="font-weight:600;font-size:19px">${esc(heading)}</h2><p style="color:#a1a1a6;font-size:15px;line-height:1.5">${esc(body)}</p>` +
      `<p style="color:#8e8e93;font-size:13px;margin-top:24px">You can close this tab and return to Alfred.</p></div></body></html>`,
  );
}

/** The consent round-trip. Validates the one-time state, then swaps the code for a refresh token and
 *  stores the approved mailbox exactly like a password account would. */
async function handleOAuthCallback(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const url = new URL(req.url || "/", "http://localhost");
  const q = url.searchParams;

  if (q.get("error")) {
    const reason = q.get("error_description") || q.get("error");
    return oauthPage(res, 400, "Sign-in not completed", reason ? `Google said: ${reason}` : "No account was connected.");
  }

  const state = q.get("state") || "";
  const code = q.get("code") || "";
  if (!state || !code) return oauthPage(res, 400, "Incomplete sign-in", "Alfred didn't get a callback from Google.");

  const stateKey = `google:oauth:${state}`;
  const expected = await kvGet(stateKey);
  if (expected !== "1") {
    return oauthPage(res, 400, "That sign-in already finished", "Each sign-in can only be used once — start it again from Alfred.");
  }
  await kvDel(stateKey);

  if (!googleOAuthConfigured()) return oauthPage(res, 503, "Not configured", "Google sign-in isn't set up on the server yet.");

  try {
    const redirectUri = oauthRedirectUri(String(req.headers["x-forwarded-host"] || req.headers.host));
    const tokens = await exchangeOAuthCode(code, redirectUri);
    const email = await googleUserEmail(tokens.accessToken);
    await addOAuthAccount({ email, refreshToken: tokens.refreshToken });
    return oauthPage(res, 200, "Mailbox connected", `${email} is now syncing into Alfred.`);
  } catch (e: any) {
    return oauthPage(res, 500, "Couldn't connect that account", String(e?.message ?? e));
  }
}

// MARK: - Writing

async function handlePost(req: IncomingMessage, res: ServerResponse): Promise<void> {
  let payload: any;
  try {
    payload = JSON.parse((await readBody(req)) || "{}");
  } catch {
    return fail(res, 400, "invalid JSON body");
  }

  const action = String(payload?.action || "");

  switch (action) {
    case "addAccount": {
      const result = await addAccount({
        provider: String(payload.provider || "custom"),
        address: String(payload.address || ""),
        password: String(payload.password || ""),
        label: payload.label ? String(payload.label) : undefined,
        imapHost: payload.imapHost ? String(payload.imapHost) : undefined,
        smtpHost: payload.smtpHost ? String(payload.smtpHost) : undefined,
      });
      return json(res, 200, { ok: true, account: result.account, warning: result.warning });
    }

    case "removeAccount": {
      const id = String(payload.id || "");
      if (!id) return fail(res, 400, "id is required");
      const removed = await removeAccount(id);
      if (!removed) return fail(res, 404, "no such account — accounts set on the server can't be removed here");
      return json(res, 200, { ok: true });
    }

    case "flags": {
      const account = String(payload.account || "");
      const mailbox = String(payload.mailbox || "INBOX");
      const uids = uidList(payload.uids ?? payload.uid);
      if (!account || !uids.length) return fail(res, 400, "account and uids are required");

      await setFlags(account, mailbox, uids, {
        seen: typeof payload.seen === "boolean" ? payload.seen : undefined,
        flagged: typeof payload.flagged === "boolean" ? payload.flagged : undefined,
      });
      return json(res, 200, { ok: true });
    }

    case "move": {
      const account = String(payload.account || "");
      const mailbox = String(payload.mailbox || "INBOX");
      const uids = uidList(payload.uids ?? payload.uid);
      const to = String(payload.to || "");
      if (!account || !uids.length || !to) return fail(res, 400, "account, uids and to are required");

      await moveMessages(account, mailbox, uids, to);
      return json(res, 200, { ok: true });
    }

    case "vip": {
      const address = String(payload.address || "").trim().toLowerCase();
      if (!address) return fail(res, 400, "address is required");
      await setVipAddress(address, payload.set === true);
      return json(res, 200, { ok: true, vips: await vipAddresses() });
    }

    case "send": {
      const account = String(payload.account || "");
      const to = String(payload.to || "");
      const text = String(payload.body || "");
      if (!account || !to || !text) return fail(res, 400, "account, to and body are required");

      await sendMessage(account, {
        to,
        cc: payload.cc ? String(payload.cc) : undefined,
        subject: String(payload.subject || "(no subject)"),
        text,
        inReplyTo: payload.inReplyTo ? String(payload.inReplyTo) : undefined,
      });
      return json(res, 200, { ok: true });
    }

    case "draft": {
      const account = String(payload.account || "");
      const mailbox = String(payload.mailbox || "INBOX");
      const uid = Number(payload.uid);
      if (!account || !Number.isInteger(uid)) return fail(res, 400, "account and uid are required");

      const { message, text } = await readMessage(account, mailbox, uid);
      const instruction = String(payload.instruction || "").trim();

      const prompt =
        `Reply to this email.\nFrom: ${message.from} <${message.fromAddress}>\n` +
        `Subject: ${message.subject}\n\n${text.slice(0, 6000)}\n\n` +
        `Carlton's instruction: ${instruction || "write an appropriate reply"}`;

      const drafted = ((await llmText(DRAFT_SYSTEM, prompt, 0.5)) || "").trim();
      if (!drafted) return fail(res, 502, "Alfred couldn't draft that just now — the AI backend didn't answer.");

      const subject = /^re:/i.test(message.subject) ? message.subject : `Re: ${message.subject}`;
      return json(res, 200, { ok: true, to: message.fromAddress, subject, body: drafted });
    }

    default:
      return fail(res, 400, `unknown action “${action}”`);
  }
}
