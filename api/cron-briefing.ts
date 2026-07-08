// Daily morning briefing — a Vercel Cron job that runs SERVER-SIDE (independent of the Mac): it
// pulls current headlines, has Gemini write a concise briefing, and pushes it to the owner's Telegram.
// This is the "runs even when the Mac is off/asleep" delivery path for a time-based routine.
//
// Scheduling (see vercel.json): the cron fires at 10:00 AND 11:00 UTC. Vercel crons are UTC-only, but
// 06:00 America/New_York is 10:00 UTC in summer (EDT) and 11:00 UTC in winter (EST). The handler gates
// on the local hour so exactly ONE of the two fires actually sends, at 06:00 ET year-round.

import type { IncomingMessage, ServerResponse } from "http";
import { sendMessage } from "./_lib/telegram";
import { geminiText } from "./_lib/gemini";

const TZ = "America/New_York";
const SEND_HOUR = 6; // 06:00 local

function etHour(now: Date): number {
  return Number(
    new Intl.DateTimeFormat("en-US", { timeZone: TZ, hour: "numeric", hour12: false }).format(now)
  );
}

function etDate(now: Date): string {
  return new Intl.DateTimeFormat("en-US", {
    timeZone: TZ, weekday: "long", month: "long", day: "numeric",
  }).format(now);
}

// Tailored to Carlton (math + CS → quantitative finance): markets/business and tech lead, then top news.
const FEEDS: { label: string; url: string }[] = [
  { label: "Markets & business", url: "https://news.google.com/rss/headlines/section/topic/BUSINESS?hl=en-US&gl=US&ceid=US:en" },
  { label: "Tech", url: "https://news.google.com/rss/headlines/section/topic/TECHNOLOGY?hl=en-US&gl=US&ceid=US:en" },
  { label: "Top news", url: "https://news.google.com/rss?hl=en-US&gl=US&ceid=US:en" },
];

/** Headline titles from a Google News RSS feed (no API key). First <title> is the feed name, dropped. */
async function fetchFeed(url: string, limit: number): Promise<string[]> {
  try {
    const res = await fetch(url, { headers: { "User-Agent": "Mozilla/5.0" } });
    if (!res.ok) return [];
    const xml = await res.text();
    const titles = [...xml.matchAll(/<title>(?:<!\[CDATA\[)?([\s\S]*?)(?:\]\]>)?<\/title>/g)]
      .map((m) => m[1].trim())
      .filter(Boolean);
    return titles.slice(1, limit + 1);
  } catch {
    return [];
  }
}

/** All feeds in parallel, formatted as labeled blocks for the model. Empty string if none resolve. */
async function gatherNews(): Promise<string> {
  const sections = await Promise.all(
    FEEDS.map(async (f) => {
      const items = await fetchFeed(f.url, 8);
      return items.length ? `${f.label}:\n${items.join("\n")}` : "";
    })
  );
  return sections.filter(Boolean).join("\n\n");
}

function json(res: ServerResponse, code: number, body: unknown): void {
  res.statusCode = code;
  res.setHeader("Content-Type", "application/json");
  res.end(JSON.stringify(body));
}

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const token = process.env.CLOUD_BOT_TOKEN;
  const owner = process.env.OWNER_CHAT_ID;
  const secret = process.env.CRON_SECRET;
  const runParam = /[?&]run=([^&]+)/.exec(req.url || "")?.[1];

  // Auth. Three accepted callers:
  //  • manual owner-gated test: GET /api/cron-briefing?run=<OWNER_CHAT_ID> (also bypasses the hour gate)
  //  • Vercel Cron: if CRON_SECRET is set, Vercel auto-adds `Authorization: Bearer <CRON_SECRET>` and we
  //    require it (strict). If it isn't set, we fall back to trusting Vercel's `vercel-cron` user-agent.
  // Low blast radius either way: the endpoint only ever messages OWNER_CHAT_ID, and non-manual sends
  // only happen during the 06:00 ET window. To harden later, just set a CRON_SECRET env var.
  const manual = !!owner && runParam === owner;
  const cronUA = /vercel-cron/i.test(String(req.headers["user-agent"] || ""));
  const cronAuthed = secret ? req.headers["authorization"] === `Bearer ${secret}` : cronUA;
  if (!manual && !cronAuthed) return json(res, 401, { ok: false, error: "unauthorized" });
  if (!token || !owner) return json(res, 500, { ok: false, error: "missing CLOUD_BOT_TOKEN/OWNER_CHAT_ID" });

  const now = new Date();
  if (!manual && etHour(now) !== SEND_HOUR) {
    return json(res, 200, { ok: true, skipped: `not ${SEND_HOUR}:00 ${TZ}` });
  }

  const news = await gatherNews();
  const system =
    "You write a concise morning briefing for Carlton — a math + CS student heading into quantitative " +
    "finance. Straightforward and plain: no greeting, no enthusiasm, no emojis, no filler. Organize " +
    "into three short sections titled 'Markets & business', 'Tech', and 'Top news', each 2-4 " +
    "one-sentence lines, most consequential first. Favor market/finance and tech/AI relevance. Skip a " +
    "section if there's nothing solid. Omit anything unclear or purely promotional.";
  const user = news
    ? `Today is ${etDate(now)}. Write the briefing from these current headlines:\n\n${news}`
    : `Today is ${etDate(now)}. Note briefly that headlines couldn't be fetched this morning.`;

  const body = (await geminiText(system, user, 0.4)) ?? "Couldn't generate the briefing this morning.";
  await sendMessage(token, owner, `Morning Briefing — ${etDate(now)}\n\n${body}`);
  return json(res, 200, { ok: true, sent: true });
}
