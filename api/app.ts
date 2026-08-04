// Alfred's JSON front door for the iOS app. The Telegram webhook speaks Telegram's protocol and can
// only be driven by Telegram; this is the same brain reached over plain HTTP so a native client can
// talk to it.
//
//   POST /api/app
//   Authorization: Bearer <APP_TOKEN>
//   { "text": "what's on my calendar tomorrow?" }
//   → 200 { "ok": true, "reply": "..." }
//
// Auth is a single shared secret rather than real accounts: Alfred is a personal assistant with one
// owner, and the Telegram side is already gated the same way (owner chat id / CRON_SECRET). The token
// still guards calendar writes and the LLM budget, so it's compared in constant time and the endpoint
// refuses to serve at all when APP_TOKEN is unset — no accidental open door on a fresh deploy.

import type { IncomingMessage, ServerResponse } from "http";
import { timingSafeEqual } from "crypto";
import { routeText } from "./_lib/route";

const MAX_BODY_BYTES = 64 * 1024;

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

/** Constant-time string compare that doesn't leak length through an early return. */
function secretsMatch(a: string, b: string): boolean {
  const ab = Buffer.from(a, "utf8");
  const bb = Buffer.from(b, "utf8");
  if (ab.length !== bb.length) {
    // Still burn a comparison so a wrong-length guess isn't measurably faster than a wrong-value one.
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

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (req.method !== "POST") return json(res, 405, { ok: false, error: "POST only" });

  const expected = process.env.APP_TOKEN;
  if (!expected) return json(res, 503, { ok: false, error: "APP_TOKEN is not configured" });

  const header = String(req.headers["authorization"] ?? "");
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!presented || !secretsMatch(presented, expected)) {
    return json(res, 401, { ok: false, error: "unauthorized" });
  }

  let text: string;
  try {
    const parsed = JSON.parse((await readBody(req)) || "{}");
    if (typeof parsed?.text !== "string") return json(res, 400, { ok: false, error: "expected { text: string }" });
    text = parsed.text;
  } catch {
    return json(res, 400, { ok: false, error: "invalid JSON body" });
  }

  try {
    const reply = await routeText(text);
    return json(res, 200, { ok: true, reply });
  } catch (e: any) {
    // Surface the reason: this endpoint has exactly one consumer, and a silent 500 on a phone is
    // far harder to debug than an honest message on screen.
    return json(res, 500, { ok: false, error: String(e?.message ?? e) });
  }
}
