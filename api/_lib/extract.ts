// Event extraction — ported from the Swift CalendarEventCapability: a date-reference table, a
// yearMentioned flag, and DETERMINISTIC year snapping (past no-year date → next future occurrence).
// Timezone-aware because the cloud server runs in UTC but the user's events are local.

import { geminiText, geminiVision } from "./gemini";

export const USER_TZ = process.env.USER_TZ || "America/New_York";

export interface ExtractedEvent {
  title: string;
  date: string; // YYYY-MM-DD, year already resolved
  start: string | null; // HH:mm (24h) local wall-clock, or null for all-day
  end: string | null;
  allDay: boolean;
  location: string | null;
  notes: string | null;
}

export async function extractFromText(text: string, now: Date): Promise<ExtractedEvent | null> {
  const raw = await geminiText(systemPrompt(now), `SOURCE:\n"""\n${text.slice(0, 6000)}\n"""\n\nExtract the event.`, 0.2);
  return raw ? parse(raw, now) : null;
}

export async function extractFromImage(base64: string, mime: string, now: Date, caption?: string): Promise<ExtractedEvent | null> {
  const prompt = `Extract the single calendar event shown in this image.${caption ? ` Extra context: ${caption}` : ""}`;
  const raw = await geminiVision(systemPrompt(now), prompt, base64, mime, 0.2);
  return raw ? parse(raw, now) : null;
}

// MARK: - Prompt

function systemPrompt(now: Date): string {
  const today = isoDate(now, USER_TZ);
  const weekday = fmt(now, USER_TZ, { weekday: "long" });
  const year = Number(today.slice(0, 4));
  return [
    `You extract a single calendar event from text or an image. Today is ${weekday}, ${today} (timezone ${USER_TZ}).`,
    `Use this date reference to resolve relative dates like "tomorrow" / "this Thursday" / "next Monday" — do NOT compute weekdays yourself:`,
    dateReference(now),
    `Times stay as written ("3pm" -> 15:00). Reply with ONE JSON object and nothing else:`,
    `{"found": true|false, "title": string, "date": "YYYY-MM-DD", "start": "HH:mm" or null, "end": "HH:mm" or null, "allDay": true|false, "yearMentioned": true|false, "location": string or null, "notes": string or null}`,
    `Rules: "found" false if there's no event. If several events appear, pick the most prominent / foreground one. Set "yearMentioned" true ONLY if the text explicitly states a year; otherwise false and put ${year} as the year in "date" (the app fixes the year). Do NOT guess a far-future year or match weekdays. If a start time is present, allDay=false; if only a date is given, allDay=true and start=null. Keep the title short. Never invent details.`,
  ].join("\n");
}

function dateReference(now: Date): string {
  const lines: string[] = [];
  for (let i = 0; i < 10; i++) {
    const d = new Date(now.getTime() + i * 86400000);
    lines.push(`${fmt(d, USER_TZ, { weekday: "long" })} ${isoDate(d, USER_TZ)}`);
  }
  return lines.join("\n");
}

// MARK: - Parse

function parse(raw: string, now: Date): ExtractedEvent | null {
  const obj = firstJsonObject(raw);
  if (!obj || obj.found !== true) return null;
  const title = typeof obj.title === "string" ? obj.title.trim() : "";
  const date = typeof obj.date === "string" ? obj.date : "";
  if (!title || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;

  const allDay = obj.allDay === true;
  const yearMentioned = obj.yearMentioned === true;
  const snapped = snapYear(date, yearMentioned, now);
  return {
    title,
    date: snapped,
    start: allDay ? null : timeOrNull(obj.start),
    end: allDay ? null : timeOrNull(obj.end),
    allDay,
    location: strOrNull(obj.location),
    notes: strOrNull(obj.notes),
  };
}

/** Past no-year date -> next future occurrence of that month/day (in the user's timezone). */
function snapYear(dateStr: string, yearMentioned: boolean, now: Date): string {
  if (yearMentioned) return dateStr;
  const [, m, d] = dateStr.split("-").map(Number);
  const today = isoDate(now, USER_TZ).split("-").map(Number); // [y, m, d]
  const key = (y: number, mm: number, dd: number) => y * 10000 + mm * 100 + dd;
  const todayKey = key(today[0], today[1], today[2]);
  if (key(Number(dateStr.slice(0, 4)), m, d) >= todayKey) return dateStr;
  for (let yr = today[0]; yr <= today[0] + 3; yr++) {
    if (key(yr, m, d) >= todayKey) return `${yr}-${pad(m)}-${pad(d)}`;
  }
  return dateStr;
}

// MARK: - helpers

function firstJsonObject(raw: string): any | null {
  const lo = raw.indexOf("{");
  const hi = raw.lastIndexOf("}");
  if (lo < 0 || hi <= lo) return null;
  try {
    return JSON.parse(raw.slice(lo, hi + 1));
  } catch {
    return null;
  }
}

function timeOrNull(v: unknown): string | null {
  return typeof v === "string" && /^\d{1,2}:\d{2}$/.test(v.trim()) ? v.trim() : null;
}
function strOrNull(v: unknown): string | null {
  const s = typeof v === "string" ? v.trim() : "";
  return s ? s : null;
}
function pad(n: number): string {
  return String(n).padStart(2, "0");
}
function fmt(d: Date, tz: string, opts: Intl.DateTimeFormatOptions): string {
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, ...opts }).format(d);
}
function isoDate(d: Date, tz: string): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
