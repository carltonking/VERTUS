// Agent-finished push: lets the Mac send a one-shot APNs push to the Alfred
// iOS app — used when a coding agent (Claude Code / opencode) finishes a job,
// so Carlton sees "your agent is done" even away from the Mac.
//
//   Mac ──POST /api/notify──▶ sendApnsPush ──▶ iPhone
//
// Auth mirrors mac.ts: APP_TOKEN bearer. Returns `pushed:false` (200) when
// APNs isn't configured rather than erroring — the Mac already showed the
// local notification, so the push is best-effort by design.

import type { IncomingMessage, ServerResponse } from "http";
import { timingSafeEqual } from "crypto";
import { sendApnsPush } from "./_lib/push";

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

function authorized(req: IncomingMessage): boolean {
  const expected = process.env.APP_TOKEN;
  if (!expected) return false;
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

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return json(res, 405, { ok: false, error: "method not allowed" });
  }
  if (!authorized(req)) return json(res, 401, { ok: false, error: "unauthorized" });

  let body: { title?: string; body?: string };
  try {
    body = JSON.parse(await readBody(req));
  } catch {
    return json(res, 400, { ok: false, error: "invalid JSON body" });
  }

  const title = String(body.title ?? "").trim().slice(0, 200);
  const text = String(body.body ?? "").trim().slice(0, 500);
  if (!title || !text) return json(res, 400, { ok: false, error: "title and body are required" });

  const pushed = await sendApnsPush({ title, body: text });
  return json(res, 200, { ok: true, pushed });
}