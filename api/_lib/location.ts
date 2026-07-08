// Latest known phone location — the cloud stand-in for the Mac's CoreLocation. The Telegram webhook
// writes it whenever the owner shares (live) location with the bot; the departure cron reads it to
// compute "time to leave". When the Mac is off, this is the ONLY way the cloud knows where you are.

import { kvGet, kvSet } from "./kv";

const KEY = "loc:latest";
const STORE_TTL_S = 12 * 3600;          // drop the fix after 12h of silence
const DEFAULT_MAX_AGE_MS = 30 * 60_000; // a fix older than 30 min is too stale to nudge on

export interface Fix {
  lat: number;
  lng: number;
  at: number; // epoch ms when recorded
}

/** Record the newest location fix (from a Telegram live/shared-location update). */
export async function setLocation(lat: number, lng: number, at: number = Date.now()): Promise<void> {
  await kvSet(KEY, JSON.stringify({ lat, lng, at }), STORE_TTL_S);
}

/** The latest fix if it's fresher than `maxAgeMs`, else null (caller should then skip the nudge). */
export async function getLocation(maxAgeMs: number = DEFAULT_MAX_AGE_MS): Promise<Fix | null> {
  const raw = await kvGet(KEY);
  if (!raw) return null;
  try {
    const f = JSON.parse(raw) as Fix;
    if (typeof f?.lat !== "number" || typeof f?.lng !== "number" || typeof f?.at !== "number") return null;
    if (Date.now() - f.at > maxAgeMs) return null;
    return f;
  } catch {
    return null;
  }
}
