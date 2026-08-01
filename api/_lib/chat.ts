// Cloud chat brain — the free-form conversation path, upgraded so Alfred can actually answer questions
// about Carlton's calendar and current news/web off-Mac (keyword-routed context injection: detect what
// the question needs, fetch it, hand it to the model). Email reads are already handled upstream by the
// /email triage route. Requests that genuinely need the Mac (iMessage, local files, Obsidian, screen,
// app control) get a deterministic, honest decline instead of a hallucinated answer.

import { llmText } from "./llm";
import { listUpcomingEvents, CalendarEvent } from "./caldav";
import { searchHeadlines } from "./news";
import { USER_TZ } from "./extract";

const CHAT_SYSTEM =
  "You are Alfred, Carlton's personal assistant, reachable on his phone as an always-on cloud service. " +
  "Lead with the answer, cut filler and preamble; contractions, natural language, one question at a time. " +
  "Be intellectually honest — push back on debatable claims instead of just agreeing. Always use 24-hour " +
  "times.\n\n" +
  "You are the CLOUD version, so you CAN: chat/answer, check his calendar, read his email, and look up " +
  "current news/web info. You CANNOT (these need his Mac, which may be off): read or send iMessage, read " +
  "his local files or Obsidian notes, see his screen, or control apps. If he asks for one of those, say " +
  "briefly that you'll need his Mac — don't pretend.\n\n" +
  "When a [context] block is included below, use it as ground truth and don't invent events or headlines.";

const MAC_ONLY_REPLY =
  "That one needs your Mac — from the cloud I can't reach iMessage, your local files or Obsidian, your " +
  "screen, or your apps. It'll work through Alfred on your Mac once it's awake.";

/** Deterministic guard for the clearest Mac-only asks, so we never hallucinate an answer for them. */
export function macOnlyReply(text: string): string | null {
  const q = text.toLowerCase();
  const macOnly =
    /\bi-?messages?\b/.test(q) ||
    /\bobsidian\b/.test(q) ||
    /\b(screenshot|screen shot)\b/.test(q) ||
    /what'?s? on my screen/.test(q) ||
    /\bclipboard\b/.test(q) ||
    /\b(local files?|my files?|my downloads|finder|spotlight)\b/.test(q) ||
    /\b(open|launch|quit|close)\b.*\b(app|application|safari|chrome|spotify|notes|finder|window)\b/.test(q) ||
    /\bon my (mac|laptop|computer|desktop)\b/.test(q);
  return macOnly ? MAC_ONLY_REPLY : null;
}

/** A read question about his schedule (adds — "put X on my calendar" — are handled earlier). */
export function wantsCalendar(text: string): boolean {
  const q = text.toLowerCase();
  if (!/\b(calendar|schedule|agenda|events?|meetings?|class(es)?|appointments?|free|busy)\b/.test(q)) return false;
  return /\b(what|whats|when|do i|am i|any|next|upcoming|today|tomorrow|this week|weekend|have|on my|got)\b/.test(q);
}

/** A question that benefits from fresh headlines. */
export function wantsWeb(text: string): boolean {
  const q = text.toLowerCase();
  return (
    /\b(news|latest|current|todays?|headlines?|happening|markets?|stocks?|price of|who won|score|weather)\b/.test(q) ||
    /\b(search|look up|google)\b/.test(q)
  );
}

function fmtEvent(e: CalendarEvent, tz: string): string {
  const day = new Intl.DateTimeFormat("en-US", { timeZone: tz, weekday: "short", month: "short", day: "numeric" }).format(e.start);
  const time = e.allDay ? "all day" : new Intl.DateTimeFormat("en-GB", { timeZone: tz, hour: "2-digit", minute: "2-digit", hour12: false }).format(e.start);
  return `- ${day} ${time} — ${e.title}${e.location ? ` @ ${e.location}` : ""}`;
}

export async function answerChat(text: string): Promise<string> {
  let context = "";

  if (wantsCalendar(text)) {
    const events = await listUpcomingEvents(96).catch(() => [] as CalendarEvent[]);
    context += events.length
      ? `\n\n[calendar — next few days]\n${events.slice(0, 20).map((e) => fmtEvent(e, USER_TZ)).join("\n")}`
      : "\n\n[calendar]\n(no events found in the next few days)";
  }

  if (wantsWeb(text)) {
    const heads = await searchHeadlines(text, 10).catch(() => [] as string[]);
    if (heads.length) context += `\n\n[current headlines]\n${heads.join("\n")}`;
  }

  const user = context ? `${text}\n${context}` : text;
  const reply = await llmText(CHAT_SYSTEM, user, 0.5);
  return reply ?? "Sorry — I couldn't reach the AI just now. Try again in a moment.";
}
