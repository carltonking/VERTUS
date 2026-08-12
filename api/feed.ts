// Calendar subscription support for the iOS app.
//
// The phone sends a feed URL (webcal:// or https://...ics); this function fetches
// and parses it, expanding recurring events into a two-year horizon, and returns
// a flat event list the phone mirrors into a local EventKit calendar. The phone
// owns the list of subscriptions; this endpoint is stateless — feed in, events
// out — so a sync is nothing more than "fetch the feed again".
//
//   POST /api/feed
//   Authorization: Bearer <APP_TOKEN>
//   { "url": "webcal://example.com/calendar.ics" }
//   → 200 { "ok": true, "events": [...] }
//
// Auth is the same shared APP_TOKEN as everything else in this deployment.
// Fetching an arbitrary URL on the owner's behalf is exactly the kind of thing
// an unguarded endpoint shouldn't do, so it refuses to serve without the token
// and caps both fetch size and parse horizon.

import type { IncomingMessage, ServerResponse } from "http";
import { timingSafeEqual } from "crypto";
import { fetchFeed, normalizeFeedUrl, parseIcs } from "./_lib/ics";

const MAX_BODY_BYTES = 16 * 1024;

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

  let url: string;
  try {
    const parsed = JSON.parse((await readBody(req)) || "{}");
    if (typeof parsed?.url !== "string" || !parsed.url.trim()) {
      return json(res, 400, { ok: false, error: "expected { url: string }" });
    }
    url = parsed.url;
  } catch {
    return json(res, 400, { ok: false, error: "invalid JSON body" });
  }

  const normalized = normalizeFeedUrl(url);
  if (!normalized) {
    return json(res, 400, { ok: false, error: "That doesn't look like a calendar feed URL. Paste a webcal:// or https:// link ending in .ics." });
  }

  try {
    const text = await fetchFeed(normalized);
    const events = parseIcs(text);
    if (!events.length) {
      return json(res, 422, { ok: false, error: "The feed is valid but contains no events in the next two years." });
    }
    return json(res, 200, { ok: true, count: events.length, events });
  } catch (e: any) {
    return json(res, 422, { ok: false, error: String(e?.message ?? e) });
  }
}
