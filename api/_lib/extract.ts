// Event extraction — ported from the Swift CalendarEventCapability: a date-reference table, a
// yearMentioned flag, and DETERMINISTIC year snapping (past no-year date → next future occurrence).
// Timezone-aware because the cloud server runs in UTC but the user's events are local.

import { geminiText, geminiVision } from "./gemini";

export const USER_TZ = process.env.USER_TZ || "America/New_York";

/** A native calendar reminder. offset is an ICS duration (e.g. "-PT1H", "PT9H"); related defaults START. */
export interface AlarmSpec {
  related?: "START" | "END";
  offset: string;
}

export interface ExtractedEvent {
  title: string;
  date: string; // YYYY-MM-DD, year already resolved
  start: string | null; // HH:mm (24h) local wall-clock, or null for all-day
  end: string | null;
  allDay: boolean;
  location: string | null;
  notes: string | null;
  // Optional syllabus extensions — ignored by the single-event (/calendar) path.
  uid?: string; // deterministic idempotent id → re-upload overwrites instead of duplicating
  url?: string; // alfred://school/... identity anchor
  categories?: string[];
  alarms?: AlarmSpec[];
}

// MARK: - Syllabus (multi-item) extraction

export type SyllabusItemType = "assignment" | "quiz" | "exam" | "final" | "reading" | "project" | "other";
const ITEM_TYPES: SyllabusItemType[] = ["assignment", "quiz", "exam", "final", "reading", "project", "other"];

export interface SyllabusItem {
  type: SyllabusItemType;
  title: string;
  date: string; // YYYY-MM-DD, year resolved
  start: string | null;
  end: string | null;
  allDay: boolean;
  weight: string | null; // "20%" if stated, kept as text
  topics: string[]; // exam coverage / reading topics — feeds study blocks
  location: string | null;
  notes: string | null;
}

export interface SyllabusExtract {
  course: string | null;
  code: string | null;
  termYear: number | null;
  items: SyllabusItem[];
}

/** Extract every dated item from a syllabus (PDF/image via Gemini vision, or plain text). */
export async function extractSyllabus(
  input: string,
  mime: string | null,
  now: Date,
  courseHint?: string,
): Promise<SyllabusExtract | null> {
  const sys = syllabusPrompt(now, courseHint);
  const raw = mime
    ? await geminiVision(sys, SYLLABUS_USER_PROMPT, input, mime, 0.2)
    : await geminiText(sys, `SYLLABUS:\n"""\n${input.slice(0, 20000)}\n"""\n\nExtract every dated item.`, 0.2);
  return raw ? parseSyllabus(raw, now, courseHint) : null;
}

const SYLLABUS_USER_PROMPT = "Extract every dated assignment, quiz, exam, final, and graded reading/project from this syllabus.";

function syllabusPrompt(now: Date, courseHint?: string): string {
  const today = isoDate(now, USER_TZ);
  const weekday = fmt(now, USER_TZ, { weekday: "long" });
  const year = Number(today.slice(0, 4));
  return [
    `You extract every dated deliverable from a course syllabus. Today is ${weekday}, ${today} (timezone ${USER_TZ}).`,
    courseHint ? `The user says this is for course: "${courseHint}".` : "",
    `Use this date reference to resolve relative dates — do NOT compute weekdays yourself:`,
    dateReference(now),
    `Reply with ONE JSON object and nothing else:`,
    `{"course": string|null, "code": string|null, "term": string|null, "termYear": number|null, "items": [`,
    `  {"type": "assignment|quiz|exam|final|reading|project|other", "title": string, "date": "YYYY-MM-DD",`,
    `   "start": "HH:mm"|null, "end": "HH:mm"|null, "allDay": true|false, "yearMentioned": true|false,`,
    `   "weight": string|null, "topics": [string], "location": string|null, "notes": string|null} ] }`,
    `Rules:`,
    `- ONLY include an item if the syllabus states an EXPLICIT calendar date for it. If a row has no date (or only "Week 6" with no date mapping), OMIT it. Never invent or estimate dates.`,
    `- Keep distinguishing numbers in titles ("Problem Set 3", "Midterm 2", "Quiz 4") — never collapse them to a generic name.`,
    `- Set "code" to the short course code (e.g. "CS 101"), "term" to the term as written ("Fall 2026", "Spring 2027") if present, and "termYear" to its 4-digit year. Set per-item "yearMentioned" true ONLY if that row explicitly names a year; otherwise put ${year} and the app resolves it.`,
    `- A cumulative/end-of-term exam = "final". A timed exam has allDay=false; a date-only item has allDay=true and start=null.`,
    `- "topics": for exams/finals/readings, the coverage or reading topics as a short list; else [].`,
    `- "weight": grade weight as written ("20%", "50 pts") or null. Keep titles short. Never invent details.`,
  ].filter(Boolean).join("\n");
}

function parseSyllabus(raw: string, now: Date, courseHint?: string): SyllabusExtract | null {
  const obj = firstJsonObject(raw);
  let list: any[] = [];
  let course: string | null = null;
  let code: string | null = courseHint ?? null;
  let term: string | null = null;
  let termYear: number | null = null;
  if (obj && Array.isArray(obj.items)) {
    list = obj.items;
    course = strOrNull(obj.course);
    code = courseHint ?? strOrNull(obj.code);
    term = strOrNull(obj.term);
    termYear = intOrNull(obj.termYear) ?? yearFromTerm(term);
  } else {
    const arr = firstJsonArray(raw);
    if (arr) list = arr;
  }
  const season = seasonOf(term);
  const items = list.map((o) => coerceItem(o, termYear, season, now)).filter((x): x is SyllabusItem => x !== null);
  return items.length || course ? { course, code, termYear, items } : null;
}

function coerceItem(o: any, termYear: number | null, season: string | null, now: Date): SyllabusItem | null {
  if (!o || typeof o !== "object") return null;
  const title = typeof o.title === "string" ? o.title.trim() : "";
  const date = typeof o.date === "string" ? o.date : "";
  if (!title || !/^\d{4}-\d{2}-\d{2}$/.test(date)) return null;
  const start = o.allDay === true ? null : timeOrNull(o.start);
  const allDay = o.allDay === true || start === null; // no parseable time ⇒ all-day (never a timed event with null start)
  const type: SyllabusItemType = ITEM_TYPES.includes(o.type) ? o.type : "other";
  return {
    type,
    title,
    date: resolveYear(date, o.yearMentioned === true, termYear, season, now),
    start,
    end: allDay ? null : timeOrNull(o.end),
    allDay,
    weight: strOrNull(o.weight),
    topics: Array.isArray(o.topics) ? o.topics.map((t: any) => strOrNull(t)).filter((t: string | null): t is string => !!t) : [],
    location: strOrNull(o.location),
    notes: strOrNull(o.notes),
  };
}

/** Resolve the year for a no-year date. Prefer the term year (keeps passed deadlines in the past,
 * preserving order); roll early-months into termYear+1 for a Fall term (and the reverse for Spring).
 * A malformed (non-4-digit) termYear falls through to snapYear. */
function resolveYear(dateStr: string, yearMentioned: boolean, termYear: number | null, season: string | null, now: Date): string {
  if (yearMentioned) return dateStr;
  if (termYear && termYear >= 1000 && termYear <= 9999) {
    const mo = Number(dateStr.slice(5, 7));
    let y = termYear;
    if (season === "fall" && mo <= 6) y = termYear + 1; // Fall term listing Jan–Jun → next calendar year
    else if (season === "spring" && mo >= 8) y = termYear - 1; // Spring term listing Aug–Dec → prior calendar year
    return `${y}-${dateStr.slice(5)}`;
  }
  return snapYear(dateStr, false, now);
}

function seasonOf(term: string | null): string | null {
  if (!term) return null;
  const t = term.toLowerCase();
  if (t.includes("fall") || t.includes("autumn")) return "fall";
  if (t.includes("spring")) return "spring";
  if (t.includes("summer")) return "summer";
  if (t.includes("winter")) return "winter";
  return null;
}
function yearFromTerm(term: string | null): number | null {
  const m = term ? /\b(20\d{2})\b/.exec(term) : null;
  return m ? Number(m[1]) : null;
}

function firstJsonArray(raw: string): any[] | null {
  const lo = raw.indexOf("[");
  const hi = raw.lastIndexOf("]");
  if (lo < 0 || hi <= lo) return null;
  try {
    const v = JSON.parse(raw.slice(lo, hi + 1));
    return Array.isArray(v) ? v : null;
  } catch {
    return null;
  }
}

function intOrNull(v: unknown): number | null {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? Math.trunc(n) : null;
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
// The dateReference loop builds ~10 formatters per extract; these two shapes never vary
// per request, so cache them at module scope. Both are bound to USER_TZ.
const weekdayFmt = new Intl.DateTimeFormat("en-US", { timeZone: USER_TZ, weekday: "long" });
const isoFmt = new Intl.DateTimeFormat("en-CA", { timeZone: USER_TZ, year: "numeric", month: "2-digit", day: "2-digit" });

function fmt(d: Date, tz: string, opts: Intl.DateTimeFormatOptions): string {
  // Fast path for the only call shape used across the app; falls back for any other args.
  if (tz === USER_TZ && opts.weekday === "long" && Object.keys(opts).length === 1) {
    return weekdayFmt.format(d);
  }
  return new Intl.DateTimeFormat("en-US", { timeZone: tz, ...opts }).format(d);
}
function isoDate(d: Date, tz: string): string {
  if (tz === USER_TZ) return isoFmt.format(d);
  return new Intl.DateTimeFormat("en-CA", { timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
}
