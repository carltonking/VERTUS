// The relay that lets the iOS app talk to Alfred running on the Mac.
//
// Why a relay at all: the Mac sits behind a home router, so a phone on cellular
// cannot open a connection to it. The old Telegram bot solved this without any
// port forwarding or VPN by having the Mac *long-poll outbound* to Telegram's
// servers. This keeps that shape and swaps Telegram for infrastructure already in
// place — this function plus Upstash KV — so the client can be Alfred's own app
// instead of Telegram.
//
//   iPhone ──POST /api/mac──▶ [ KV mailbox ] ◀──GET /api/mac?wait──── Mac
//          ◀─────────────────────────────────── POST /api/mac/reply ──┘
//
// Nothing here understands what Alfred does. It moves opaque strings between two
// clients and forgets them. The thinking happens on the Mac, in Hermes, with the
// local model — which is the entire point of routing here rather than answering
// in the cloud.
//
// Auth is the same shared APP_TOKEN the app already uses. Alfred is single-owner;
// there are no accounts to model.

import type { IncomingMessage, ServerResponse } from "http";
import { timingSafeEqual } from "crypto";
import { kvGet, kvSet, kvDel, kvConfigured } from "./_lib/kv";

const MAX_BODY_BYTES = 64 * 1024;

/** How long a queued message waits for the Mac before it is considered stale. */
const REQUEST_TTL_S = 300;
/** How long an answer waits for the phone to collect it. */
const REPLY_TTL_S = 300;

/**
 * How long the Mac's poll holds open before returning empty.
 *
 * Short on purpose. Vercel serverless functions cap concurrent invocations low
 * (roughly 2 in practice), and the Mac reconnects instantly after every poll —
 * so a long hold would permanently occupy one of those slots and starve the
 * phone's POST (and the Mac's own reply POST) until Vercel kills them at the
 * max-duration ceiling. A short hold frees a slot every few seconds and costs
 * nothing: the phone wait and the Mac are independent invocations, and the
 * Mac reconnects immediately.
 */
const GET_POLL_HOLD_MS = 4_000;
const POLL_INTERVAL_MS = 500;

/**
 * How long the phone's POST waits for the Mac to answer, capped under the
 * function's 60s max duration. The local model takes 10-50s on an M1 Pro, so
 * 25s was too tight — the phone gave up and reported "your Mac didn't answer"
 * mid-thought. 45s fits both the model and the ceiling.
 */
const PHONE_WAIT_MS = 45_000;

const QUEUE_KEY = "mac:inbox";
const replyKey = (id: string) => `mac:reply:${id}`;

interface QueuedMessage {
  id: string;
  text: string;
  at: number;
}

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

function secretsMatch(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) {
    timingSafeEqual(ab, ab); // burn a comparison so length isn't a timing oracle
    return false;
  }
  return timingSafeEqual(ab, bb);
}

function authorized(req: IncomingMessage): boolean {
  const expected = process.env.APP_TOKEN;
  if (!expected) return false; // unset means closed, never open
  const header = String(req.headers.authorization ?? "");
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  return presented.length > 0 && secretsMatch(presented, expected);
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    let size = 0;
    req.on("data", (c: Buffer) => {
      size += c.length;
      if (size > MAX_BODY_BYTES) reject(new Error("body too large"));
      else chunks.push(c);
    });
    req.on("end", () => resolve(Buffer.concat(chunks).toString("utf8")));
    req.on("error", reject);
  });
}

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

/** Non-cryptographic id; it only has to be unique among in-flight messages. */
function newId(): string {
  return `${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (!authorized(req)) return json(res, 401, { ok: false, error: "unauthorized" });
  if (!kvConfigured()) return json(res, 503, { ok: false, error: "KV is not configured" });

  const url = new URL(req.url ?? "/", "http://localhost");
  const path = url.pathname.replace(/\/+$/, "");
  const isReply = path.endsWith("/reply");

  // ── POST: either the Mac delivering an answer, or the phone asking something ──
  //
  // The reply is identified by body shape, not path: Vercel mounts this function
  // at exactly /api/mac, so /api/mac/reply matches no route and 404s before
  // reaching here. The body is read exactly once, then branched on — the stream
  // is consumed, so any second read would hang until the function's ceiling.
  if (req.method === "POST") {
    let body: { id?: string; reply?: string; text?: string };
    try {
      body = JSON.parse(await readBody(req));
    } catch {
      return json(res, 400, { ok: false, error: "invalid JSON body" });
    }

    // Mac → relay: deliver an answer.
    if (typeof body.reply === "string" && body.id) {
      const id = body.id.trim();
      if (!id) return json(res, 400, { ok: false, error: "id is required" });
      await kvSet(replyKey(id), body.reply, REPLY_TTL_S);
      return json(res, 200, { ok: true });
    }
    if (isReply) return json(res, 400, { ok: false, error: "id is required" });

    // Phone → relay: ask something, wait for the Mac to answer. A local model on
    // an M1 Pro can take ~10-50s, so returning immediately and making the app
    // poll would just move the waiting somewhere less convenient.
    const text = String(body.text ?? "").trim();
    if (!text) return json(res, 400, { ok: false, error: "text is required" });

    const id = newId();
    await kvSet(QUEUE_KEY, JSON.stringify({ id, text, at: Date.now() } satisfies QueuedMessage), REQUEST_TTL_S);

    const deadline = Date.now() + PHONE_WAIT_MS;
    while (Date.now() < deadline) {
      const reply = await kvGet(replyKey(id));
      if (reply !== null) {
        await kvDel(replyKey(id));
        return json(res, 200, { ok: true, reply });
      }
      await sleep(POLL_INTERVAL_MS);
    }

    // Distinguish "your Mac is off" from "it's thinking" — the app shows a very
    // different message for each, and guessing wrong is worse than saying so.
    return json(res, 202, {
      ok: false,
      pending: true,
      id,
      error: "Alfred on your Mac didn't answer in time. It may be asleep, or still working.",
    });
  }

  // ── Mac → relay: wait for work ────────────────────────────────────────────
  //
  // Held open rather than answered immediately so the Mac isn't hammering this
  // endpoint, and so a message reaches it within a few hundred ms of being sent.
  if (req.method === "GET") {
    const deadline = Date.now() + GET_POLL_HOLD_MS;
    while (Date.now() < deadline) {
      const raw = await kvGet(QUEUE_KEY);
      if (raw) {
        // Claim it before answering: two Macs (or a stale duplicate poller) must
        // not both take the same message and answer twice.
        await kvDel(QUEUE_KEY);
        try {
          const msg = JSON.parse(raw) as QueuedMessage;
          if (Date.now() - msg.at < REQUEST_TTL_S * 1000) {
            return json(res, 200, { ok: true, message: msg });
          }
          // Too old to be worth answering — the phone has long since given up.
        } catch {
          // Unparseable entry: dropped above, so it can't wedge the queue.
        }
      }
      await sleep(POLL_INTERVAL_MS);
    }
    return json(res, 200, { ok: true, message: null });
  }

  res.setHeader("Allow", "GET, POST");
  return json(res, 405, { ok: false, error: "method not allowed" });
}
