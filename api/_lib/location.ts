// Latest known phone location — the cloud stand-in for the Mac's CoreLocation. The Telegram webhook
// writes it whenever the owner shares (live) location with the bot; the departure cron reads it to
// compute "time to leave"; the chat brain resolves it to a timezone for "what time is it". When the
// Mac is off, this is the ONLY way the cloud knows where you are.

import { kvGet, kvSet } from "./kv";

const KEY = "loc:latest";
const TZ_KEY = "loc:timezone";
const STORE_TTL_S = 12 * 3600;          // drop the fix after 12h of silence
const TZ_TTL_S = 6 * 3600;              // timezone is tied to travel, not to the wall clock
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

/**
 * IANA timezone ("America/New_York") for the latest fresh location fix, or null.
 *
 * The KV store holds the resolved name (cached for TZ_TTL_S) so chat turns do
 * not re-query a geocoder on every message, and so the bot keeps answering
 * "what time is it" from the right zone while travelling.
 */
export async function getLocationTimezone(maxAgeMs: number = DEFAULT_MAX_AGE_MS): Promise<string | null> {
  const fix = await getLocation(maxAgeMs);
  if (!fix) return null;
  const cached = await kvGet(TZ_KEY);
  if (cached) return cached;
  const tz = await resolveTimezone(fix.lat, fix.lng);
  if (!tz) return null;
  await kvSet(TZ_KEY, tz, TZ_TTL_S);
  return tz;
}

/**
 * Reverse-geocode lat/lng to an IANA timezone name using BigDataCloud's free
 * timezone API (no key, flood-guarded to a handful of requests per day by the
 * KV cache above). Returns null on any failure — callers fall back to USER_TZ.
 */
async function resolveTimezone(lat: number, lng: number): Promise<string | null> {
  try {
    const res = await fetch(
      `https://api.bigdatacloud.net/data/timezone?latitude=${lat}&longitude=${lng}`,
      { signal: AbortSignal.timeout(5_000) },
    );
    if (!res.ok) return null;
    const data: any = await res.json();
    return (data?.ianaTimeZone ?? data?.timeZone ?? null) || null;
  } catch {
    return null;
  }
}
