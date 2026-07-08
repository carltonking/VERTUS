// Cloud routine runner — fires the always-on routines (authored via /routine on Telegram) so they run
// even when the Mac is off. The Mac's RoutineScheduler ticks every 60s and matches the exact minute;
// this is driven by an external pinger on an arbitrary cadence, so it matches each routine's cron
// against the (lastTick, now] WINDOW via cron.dueSince, and de-dupes per fired occurrence in Upstash.
//
// No Vercel cron entry (Hobby can't run per-few-minutes) — an external pinger hits it every ~1-5 min.
// Auth mirrors cron-briefing: CRON_SECRET bearer if set, else a manual ?run=<OWNER>.

import type { IncomingMessage, ServerResponse } from "http";
import { sendMessage } from "./_lib/telegram";
import { geminiText } from "./_lib/gemini";
import { getRoutines, CloudRoutine } from "./_lib/routines";
import { dueSince } from "./_lib/cron";
import { searchHeadlines } from "./_lib/news";
import { kvGet, kvSet, kvConfigured } from "./_lib/kv";

const LAST_TICK_KEY = "routines:lastTick";
const DEFAULT_LOOKBACK_MS = 6 * 60_000; // first run with no prior tick: look back one pinger interval

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

function friendlyDate(tz: string, now: Date): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "long", month: "long", day: "numeric" }).format(now);
}

async function runRoutine(r: CloudRoutine, now: Date): Promise<string> {
  let context = "";
  if (r.web) {
    const heads = await searchHeadlines(r.title || r.prompt, 10);
    if (heads.length) context = `\n\nCurrent headlines (may help — ignore if irrelevant):\n${heads.join("\n")}`;
  }
  const system =
    "You are Alfred, Carlton's assistant, delivering a scheduled routine to his phone. Answer the routine " +
    "directly — no greeting, no preamble, no sign-off, plain text (no markdown headers). Be concise and " +
    "useful. 24-hour times. If you can't do something without his Mac (reading his files, iMessage, or " +
    `screen), say so briefly. Today is ${friendlyDate(r.tz, now)}.`;
  const out = await geminiText(system, r.prompt + context, 0.5);
  return (out ?? "").trim() || "(no response)";
}

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const token = process.env.CLOUD_BOT_TOKEN;
  const owner = process.env.OWNER_CHAT_ID;
  const secret = process.env.CRON_SECRET;
  const runParam = /[?&]run=([^&]+)/.exec(req.url || "")?.[1];

  const manual = !!owner && runParam === owner;
  const cronUA = /vercel-cron/i.test(String(req.headers["user-agent"] || ""));
  const cronAuthed = secret ? req.headers["authorization"] === `Bearer ${secret}` : cronUA;
  if (!manual && !cronAuthed) return json(res, 401, { ok: false, error: "unauthorized" });
  if (!token || !owner) return json(res, 500, { ok: false, error: "missing CLOUD_BOT_TOKEN/OWNER_CHAT_ID" });
  if (!kvConfigured()) return json(res, 200, { ok: false, error: "routine store (Upstash) not configured" });

  const routines = (await getRoutines()).filter((r) => r.enabled);
  const nowMs = Date.now();
  const lastRaw = await kvGet(LAST_TICK_KEY);
  const lastTick = lastRaw ? Number(lastRaw) : nowMs - DEFAULT_LOOKBACK_MS;

  const fired: string[] = [];
  for (const r of routines) {
    const fire = dueSince(r.cron, r.tz, lastTick, nowMs);
    if (fire == null) continue;
    const dedupeKey = `routines:fired:${r.id}@${fire}`;
    if (await kvGet(dedupeKey)) continue;
    // Mark BEFORE running so a slow LLM call can't let an overlapping tick double-send.
    await kvSet(dedupeKey, "1", 2 * 3600);

    const body = await runRoutine(r, new Date(fire));
    await sendMessage(token, owner, `📋 ${r.title}\n\n${body}`);
    fired.push(r.title);
  }

  // Advance the cursor last, so a crash mid-batch re-processes on the next tick (dedupe prevents dupes).
  await kvSet(LAST_TICK_KEY, String(nowMs));
  return json(res, 200, { ok: true, routines: routines.length, fired });
}
