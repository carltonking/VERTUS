// Alfred's push-device registration.
//
//   POST /api/device
//   Authorization: Bearer <APP_TOKEN>
//   { "token": "<apns device token hex>" }
//   → 200 { "ok": true } | 400/401/503
//
// The iOS app calls this on launch (and whenever the device token changes) so
// cron-departure can nudge the owner via APNs instead of only over Telegram.
// Auth mirrors api/app.ts: the same APP_TOKEN, compared in constant time. The
// token is stored in KV; without a KV store the endpoint still answers OK so a
// fresh deploy without Upstash doesn't brick the app's launch flow.

import type { IncomingMessage, ServerResponse } from "http";
import { timingSafeEqual } from "crypto";
import { registerDeviceToken, pushConfigured } from "./_lib/push";
import { kvConfigured } from "./_lib/kv";

const MAX_BODY_BYTES = 8 * 1024;

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

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

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (req.method !== "POST") return json(res, 405, { ok: false, error: "POST only" });

  const expected = process.env.APP_TOKEN;
  if (!expected) return json(res, 503, { ok: false, error: "APP_TOKEN is not configured" });

  const header = String(req.headers["authorization"] ?? "");
  const presented = header.startsWith("Bearer ") ? header.slice(7) : "";
  if (!presented || !secretsMatch(presented, expected)) {
    return json(res, 401, { ok: false, error: "unauthorized" });
  }

  let token: string;
  try {
    const parsed = JSON.parse((await readBody(req)) || "{}");
    if (typeof parsed?.token !== "string" || !parsed.token) {
      return json(res, 400, { ok: false, error: "expected { token: string }" });
    }
    token = parsed.token;
  } catch {
    return json(res, 400, { ok: false, error: "invalid JSON body" });
  }

  if (!/^[0-9a-fA-F]{32,200}$/.test(token.trim())) {
    return json(res, 400, { ok: false, error: "token is not a valid APNs device token" });
  }
  if (!kvConfigured()) return json(res, 200, { ok: true, stored: false, reason: "no KV store" });

  const stored = await registerDeviceToken(token);
  if (!stored) return json(res, 500, { ok: false, error: "could not store device token" });

  return json(res, 200, { ok: true, stored: true, pushReady: pushConfigured() });
}