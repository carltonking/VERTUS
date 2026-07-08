// "Time to leave" watcher — the cloud twin of the Mac's DepartureWatcher, so leave-by nudges fire even
// when the Mac is off. Each tick: read the latest phone location (shared via Telegram Live Location),
// look at upcoming located calendar events (CalDAV), estimate travel time (Google Routes), and text ONE
// nudge per event when it's time to start wrapping up (leave-by − pack-up lead). Never sends anything
// outward beyond the owner's own Telegram, and only reads the calendar.
//
// This has no Vercel cron entry (Hobby can't run per-few-minutes) — an external pinger hits it every
// ~1-5 min. Auth mirrors cron-briefing: `CRON_SECRET` bearer if set, else a manual ?run=<OWNER>.
//
// Tunables (env, all optional): DEPART_MODE (transit|driving|walking|bicycling, default transit),
// DEPART_ARRIVE_EARLY_MIN (default 5), DEPART_PACKUP_LEAD_MIN (default 10), DEPART_WINDOW_HOURS (3),
// DEPART_LOCATION_MAX_AGE_MIN (how fresh the phone fix must be, default 30), USER_TZ.

import type { IncomingMessage, ServerResponse } from "http";
import { sendMessage } from "./_lib/telegram";
import { listUpcomingLocatedEvents } from "./_lib/caldav";
import { estimateTravel, parseMode } from "./_lib/travel";
import { getLocation } from "./_lib/location";
import { kvGet, kvSet, kvConfigured } from "./_lib/kv";

const TZ = process.env.USER_TZ || "America/New_York";
const MODE = parseMode(process.env.DEPART_MODE);
const ARRIVE_EARLY_MS = num(process.env.DEPART_ARRIVE_EARLY_MIN, 5) * 60_000;
const PACKUP_LEAD_MS = num(process.env.DEPART_PACKUP_LEAD_MIN, 10) * 60_000;
const WINDOW_HOURS = num(process.env.DEPART_WINDOW_HOURS, 3);
const LOC_MAX_AGE_MS = num(process.env.DEPART_LOCATION_MAX_AGE_MIN, 30) * 60_000;
// Don't price a route until an event is within this lead (bounds Google Routes calls). Bump it if you
// ever have a commute+prep longer than this.
const MAX_LEAD_MS = num(process.env.DEPART_MAX_LEAD_MIN, 120) * 60_000;

function num(v: string | undefined, dflt: number): number {
  const n = Number(v);
  return Number.isFinite(n) && n >= 0 ? n : dflt;
}

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

/** Local HH:MM for the leave-by time. */
function hhmm(d: Date): string {
  return new Intl.DateTimeFormat("en-GB", { timeZone: TZ, hour: "2-digit", minute: "2-digit", hour12: false }).format(d);
}

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const token = process.env.CLOUD_BOT_TOKEN;
  const owner = process.env.OWNER_CHAT_ID;
  const secret = process.env.CRON_SECRET;
  const runParam = /[?&]run=([^&]+)/.exec(req.url || "")?.[1];

  // Same auth model as cron-briefing: manual owner test, Vercel cron bearer, or the vercel-cron UA.
  const manual = !!owner && runParam === owner;
  const cronUA = /vercel-cron/i.test(String(req.headers["user-agent"] || ""));
  const cronAuthed = secret ? req.headers["authorization"] === `Bearer ${secret}` : cronUA;
  if (!manual && !cronAuthed) return json(res, 401, { ok: false, error: "unauthorized" });
  if (!token || !owner) return json(res, 500, { ok: false, error: "missing CLOUD_BOT_TOKEN/OWNER_CHAT_ID" });
  if (!kvConfigured()) return json(res, 200, { ok: false, error: "location store (Upstash) not configured" });

  const fix = await getLocation(LOC_MAX_AGE_MS);
  if (!fix) return json(res, 200, { ok: true, skipped: "no fresh location — share Live Location with the bot" });

  const events = await listUpcomingLocatedEvents(WINDOW_HOURS);
  if (!events.length) return json(res, 200, { ok: true, skipped: "no upcoming located events" });

  const now = Date.now();
  const sent: string[] = [];
  const checked: string[] = [];

  for (const ev of events) {
    const startMs = ev.start.getTime();
    if (startMs <= now || startMs - now > MAX_LEAD_MS) continue; // past, or too far out to price yet
    checked.push(ev.title);

    const dedupeKey = `depart:sent:${ev.uid}@${startMs}`;
    if (await kvGet(dedupeKey)) continue; // already nudged for this occurrence

    const est = await estimateTravel({ lat: fix.lat, lng: fix.lng }, ev.location, MODE);
    if (!est || est.seconds < 120) continue; // no route, or basically already there

    const leaveBy = startMs - est.seconds * 1000 - ARRIVE_EARLY_MS;
    const nudgeAt = leaveBy - PACKUP_LEAD_MS;
    if (now < nudgeAt || now >= startMs) continue; // outside the "start wrapping up" window

    const mins = Math.max(1, Math.round(est.seconds / 60));
    const via = est.usedMode === "transit" ? " by transit" : est.usedMode === "driving" ? " driving" : est.usedMode === "bicycling" ? " by bike" : " on foot";
    const body = `🚶 ~${mins} min${via} to ${ev.title} — leave by ${hhmm(new Date(leaveBy))} to arrive early. Start wrapping up.`;
    await sendMessage(token, owner, body);

    // Keep the marker until ~1h past start so we never re-nudge the same occurrence.
    await kvSet(dedupeKey, "1", Math.ceil((startMs - now) / 1000) + 3600);
    sent.push(ev.title);
  }

  return json(res, 200, { ok: true, locationAgeMin: Math.round((now - fix.at) / 60000), checked, sent });
}
