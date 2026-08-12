// Calendar feed (ICS) fetching and parsing for app-side calendar subscriptions.
//
// iOS has no public API for an app to subscribe to a remote .ics feed — the
// "Add Subscribed Calendar" flow lives in Settings and is Apple-only. Alfred
// works around that with its own backend: the phone posts a feed URL here, this
// function fetches and parses the ICS (handling recurrence for a horizon the
// phone then mirrors into a local EventKit calendar), and returns a flat event
// list the phone can upsert. The phone stays the source of truth for *which*
// feeds exist; this endpoint is a stateless fetcher/parser.
//
// Scope of the parser: RFC 5545's common subset. Line folding, VEVENT blocks,
// DATE vs DATE-TIME values, Z-suffixed UTC, TZID offsets, DURATION, and the
// practical recurrence rules (DAILY/WEEKLY/MONTHLY/YEARLY with INTERVAL, COUNT,
// UNTIL, BYDAY). Everything exotic (EXDATE, RECURRENCE-ID, VTODO, VALARM,
// BYSETPOS, multiple VEVENTs per UID) is deliberately skipped — subscription
// feeds that need them are rare, and a worst case is the phone showing one
// occurrence where Apple Calendar would show more.

/** A parsed event, in a shape the iOS app can consume directly. */
export interface FeedEvent {
  uid: string;
  title: string;
  /** Milliseconds since epoch (UTC). Timed events only. */
  start?: number;
  /** Milliseconds since epoch (UTC). Timed events only. */
  end?: number;
  /** "YYYYMMDD" in the event's own calendar, for all-day events. */
  date?: string;
  allDay: boolean;
  location?: string;
  description?: string;
}

const MAX_FETCH_BYTES = 4 * 1024 * 1024;
const FETCH_TIMEOUT_MS = 20_000;
/** How far into the future occurrences are expanded. */
const HORIZON_YEARS = 2;
const MAX_OCCURRENCES = 1000;

// MARK: - Fetching

/** webcal:// → https://, and refuse anything that isn't a plain web URL. */
export function normalizeFeedUrl(input: string): string | null {
  let raw = input.trim();
  if (!raw) return null;
  if (raw.toLowerCase().startsWith("webcal://")) {
    raw = "https://" + raw.slice("webcal://".length);
  }
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return null;
  }
  if (url.protocol !== "https:" && url.protocol !== "http:") return null;
  return url.toString();
}

export async function fetchFeed(url: string): Promise<string> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  try {
    const response = await fetch(url, {
      redirect: "follow",
      signal: controller.signal,
      headers: { "user-agent": "AlfredFeed/1.0" },
    });
    if (!response.ok) throw new Error(`the feed answered HTTP ${response.status}`);
    const buf = Buffer.from(await response.arrayBuffer());
    if (buf.length > MAX_FETCH_BYTES) throw new Error("the feed is too large to read");
    // Some servers serve UTF-16 or ISO-8859-1 despite the content type. ICS is
    // near-ASCII; UTF-8 decode then strip a UTF-8 BOM is right for the real world.
    return buf.toString("utf8").replace(/^\uFEFF/, "");
  } finally {
    clearTimeout(timer);
  }
}

// MARK: - Parsing

/** Unfold continuation lines, then split into (name, params, value) triples. */
function unfold(text: string): Array<{ name: string; params: Record<string, string>; value: string }> {
  const unfolded = text
    .replace(/\r\n/g, "\n")
    .replace(/\r/g, "\n")
    .split("\n")
    .reduce((acc, line) => {
      if (line.startsWith(" ") || line.startsWith("\t")) {
        acc[acc.length - 1] += line.slice(1);
      } else if (line.trim()) {
        acc.push(line);
      }
      return acc;
    }, [] as string[]);

  return unfolded.map((line) => {
    const colon = line.indexOf(":");
    if (colon < 0) return { name: line.trim().toUpperCase(), params: {}, value: "" };
    const head = line.slice(0, colon);
    const value = unescape(line.slice(colon + 1));
    const [nameRaw, ...paramBits] = head.split(";");
    const params: Record<string, string> = {};
    for (const bit of paramBits) {
      const eq = bit.indexOf("=");
      if (eq > 0) params[bit.slice(0, eq).toUpperCase()] = bit.slice(eq + 1);
    }
    return { name: nameRaw.trim().toUpperCase(), params, value };
  });
}

function unescape(value: string): string {
  return value
    .replace(/\\n/gi, "\n")
    .replace(/\\N/gi, "\n")
    .replace(/\\,/g, ",")
    .replace(/\\;/g, ";")
    .replace(/\\\\/g, "\\");
}

/** Parse a DATE (YYYYMMDD) or DATE-TIME (YYYYMMDDTHHMMSS[Z]) value. */
interface ParsedDate {
  isDate: boolean;
  /** y/m/d/h/mi/s are the wall-clock components as written in the feed. */
  y: number; mo: number; d: number; h: number; mi: number; s: number;
  /** UTC if the value was Z-suffixed or had no TZID; tzid string otherwise. */
  tzid: string | null;
}

function parseDate(raw: string): ParsedDate | null {
  const value = raw.trim();
  if (!/^\d{8}(T\d{6}Z?)?$/.test(value)) return null;
  const isDate = value.length === 8;
  const y = parseInt(value.slice(0, 4), 10);
  const mo = parseInt(value.slice(4, 6), 10);
  const d = parseInt(value.slice(6, 8), 10);
  if (isDate) return { isDate: true, y, mo, d, h: 0, mi: 0, s: 0, tzid: null };
  const h = parseInt(value.slice(9, 11), 10);
  const mi = parseInt(value.slice(11, 13), 10);
  const s = parseInt(value.slice(13, 15), 10);
  const utc = value.endsWith("Z");
  return { isDate: false, y, mo, d, h, mi, s, tzid: utc ? "UTC" : null };
}

/** Wall-clock components plus a TZID → epoch milliseconds. */
function toEpoch(p: ParsedDate, tzid: string | null): number {
  if (!tzid || tzid === "UTC") return Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s);
  // TZID offsets come from Intl, which ships with the ICU database. The trick:
  // interpret the wall time as UTC, ask Intl what wall time that is in the target
  // zone, and the difference between the two is the offset to apply.
  const asUTC = new Date(Date.UTC(p.y, p.mo - 1, p.d, p.h, p.mi, p.s));
  try {
    const parts = new Intl.DateTimeFormat("en-US", {
      timeZone: tzid,
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit",
      hourCycle: "h23",
    }).formatToParts(asUTC);
    const get = (type: string) => Number(parts.find((x) => x.type === type)?.value ?? "0");
    const wall = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
    return asUTC.getTime() + (asUTC.getTime() - wall);
  } catch {
    // Unknown tzid: treat as UTC rather than failing the whole feed.
    return asUTC.getTime();
  }
}

function epochOf(p: ParsedDate): number {
  return toEpoch(p, p.tzid);
}

function addMonths(y: number, mo: number, n: number): { y: number; mo: number } {
  const total = y * 12 + (mo - 1) + n;
  return { y: Math.floor(total / 12), mo: (total % 12) + 1 };
}

/** Clamp a day-of-month into the target month, like most calendar apps do. */
function clampDay(y: number, mo: number, d: number): number {
  const last = new Date(Date.UTC(y, mo, 0)).getUTCDate();
  return Math.min(d, last);
}

/** Parse a DURATION like P1DT2H30M into milliseconds (sign ignored, RFC forbids negatives here). */
function parseDuration(raw: string): number {
  const m = /^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$/i.exec(raw.trim());
  if (!m) return 0;
  const n = (i: number) => Number(m[i] ?? 0);
  const weeks = n(1), days = n(2), hours = n(3), minutes = n(4), seconds = n(5);
  return ((weeks * 7 + days) * 24 + hours) * 3600_000 + minutes * 60_000 + seconds * 1000;
}

interface Rrule {
  freq: "DAILY" | "WEEKLY" | "MONTHLY" | "YEARLY";
  interval: number;
  count?: number;
  until?: ParsedDate;
  byday?: string[];
}

function parseRrule(raw: string): Rrule | null {
  const rule: Rrule = { freq: "DAILY", interval: 1 };
  let ok = false;
  for (const part of raw.split(";")) {
    const eq = part.indexOf("=");
    if (eq <= 0) continue;
    const key = part.slice(0, eq).toUpperCase();
    const value = part.slice(eq + 1);
    switch (key) {
      case "FREQ":
        if (["DAILY", "WEEKLY", "MONTHLY", "YEARLY"].includes(value.toUpperCase())) {
          rule.freq = value.toUpperCase() as Rrule["freq"];
          ok = true;
        }
        break;
      case "INTERVAL": rule.interval = Math.max(1, parseInt(value, 10) || 1); break;
      case "COUNT": rule.count = parseInt(value, 10); break;
      case "UNTIL": {
        const p = parseDate(value);
        if (p && !p.isDate) rule.until = p;
        break;
      }
      case "BYDAY": {
        const days = value.split(",").map((s) => s.trim().toUpperCase()).filter((s) => /^(MO|TU|WE|TH|FR|SA|SU)$/.test(s));
        if (days.length) rule.byday = days;
        break;
      }
    }
  }
  return ok ? rule : null;
}

const DAY_MS = 86_400_000;
const WEEKDAY_INDEX: Record<string, number> = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };

/** Expand a VEVENT into concrete occurrences within the horizon. */
function expand(start: ParsedDate, rrule: Rrule | null, untilMs: number): ParsedDate[] {
  if (!rrule) return [start];

  const horizon = Math.min(untilMs, start.isDate ? Number.MAX_SAFE_INTEGER : Date.now() + HORIZON_YEARS * 365.25 * DAY_MS);
  const out: ParsedDate[] = [];
  const seen = new Set<string>();
  let count = 0;
  const take = (p: ParsedDate) => {
    if (rrule.count && count >= rrule.count) return;
    const key = p.isDate ? `d${p.y}-${p.mo}-${p.d}` : `t${epochOf(p)}`;
    if (seen.has(key)) return;
    const overHorizon = p.isDate
      ? Date.UTC(p.y, p.mo - 1, p.d) > horizon
      : epochOf(p) > horizon;
    if (overHorizon) return;
    if (rrule.until) {
      const u = rrule.until;
      if (p.isDate) {
        if (Date.UTC(p.y, p.mo - 1, p.d) > Date.UTC(u.y, u.mo - 1, u.d)) return;
      } else if (epochOf(p) > epochOf(u)) return;
    }
    seen.add(key);
    out.push(p);
    count++;
  };

  if (rrule.freq === "WEEKLY" && rrule.byday?.length) {
    // The week grid of occurrences, then BYDAY picks which weekdays inside each.
    const startDow = new Date(Date.UTC(start.y, start.mo - 1, start.d)).getUTCDay();
    const baseDate = new Date(Date.UTC(start.y, start.mo - 1, start.d - startDow));
    for (let week = 0; count < MAX_OCCURRENCES; week++) {
      const weekStart = new Date(baseDate.getTime() + week * rrule.interval * 7 * DAY_MS);
      if (weekStart.getTime() > horizon) break;
      for (const day of rrule.byday) {
        const target = new Date(weekStart.getTime() + ((WEEKDAY_INDEX[day] - weekStart.getUTCDay() + 7) % 7) * DAY_MS);
        if (target.getTime() < Date.UTC(start.y, start.mo - 1, start.d)) continue; // before DTSTART
        take({
          isDate: start.isDate,
          y: target.getUTCFullYear(), mo: target.getUTCMonth() + 1, d: target.getUTCDate(),
          h: start.h, mi: start.mi, s: start.s, tzid: start.tzid,
        });
        if (count >= MAX_OCCURRENCES) break;
      }
    }
  } else {
    for (let i = 0; count < MAX_OCCURRENCES; i++) {
      const n = i * rrule.interval;
      let p: ParsedDate;
      switch (rrule.freq) {
        case "DAILY": {
          const t = new Date(Date.UTC(start.y, start.mo - 1, start.d) + n * DAY_MS);
          p = { isDate: start.isDate, y: t.getUTCFullYear(), mo: t.getUTCMonth() + 1, d: t.getUTCDate(), h: start.h, mi: start.mi, s: start.s, tzid: start.tzid };
          break;
        }
        case "WEEKLY": {
          const t = new Date(Date.UTC(start.y, start.mo - 1, start.d) + n * 7 * DAY_MS);
          p = { isDate: start.isDate, y: t.getUTCFullYear(), mo: t.getUTCMonth() + 1, d: t.getUTCDate(), h: start.h, mi: start.mi, s: start.s, tzid: start.tzid };
          break;
        }
        case "MONTHLY": {
          const ym = addMonths(start.y, start.mo, n);
          const d = clampDay(ym.y, ym.mo, start.d);
          p = { isDate: start.isDate, y: ym.y, mo: ym.mo, d, h: start.h, mi: start.mi, s: start.s, tzid: start.tzid };
          break;
        }
        case "YEARLY": {
          const d = clampDay(start.y + n, start.mo, start.d);
          p = { isDate: start.isDate, y: start.y + n, mo: start.mo, d, h: start.h, mi: start.mi, s: start.s, tzid: start.tzid };
          break;
        }
        default:
          p = start;
      }
      take(p);
      if (i > 1000) break; // safety valve for malformed rules
    }
  }
  return out;
}

interface RawEvent {
  uid?: string;
  summary?: string;
  dtstart?: ParsedDate;
  dtend?: ParsedDate;
  durationMs: number;
  location?: string;
  description?: string;
  rrule?: Rrule | null;
}

export function parseIcs(text: string): FeedEvent[] {
  const lines = unfold(text);
  const blocks: Array<Record<string, { params: Record<string, string>; value: string }>> = [];
  let current: Record<string, { params: Record<string, string>; value: string }> | null = null;

  for (const line of lines) {
    if (line.name === "BEGIN" && line.value.toUpperCase() === "VEVENT") {
      current = {};
      blocks.push(current);
    } else if (line.name === "END" && line.value.toUpperCase() === "VEVENT") {
      current = null;
    } else if (current && line.name !== "BEGIN" && line.name !== "END") {
      current[line.name] = { params: line.params, value: line.value };
    }
  }

  const events: FeedEvent[] = [];
  for (const block of blocks) {
    const raw: RawEvent = {
      uid: block["UID"]?.value,
      summary: block["SUMMARY"]?.value,
      dtstart: block["DTSTART"] ? (parseDate(block["DTSTART"].value) ?? undefined) : undefined,
      dtend: block["DTEND"] ? (parseDate(block["DTEND"].value) ?? undefined) : undefined,
      durationMs: block["DURATION"] ? parseDuration(block["DURATION"].value) : 0,
      location: block["LOCATION"]?.value,
      description: block["DESCRIPTION"]?.value,
      rrule: block["RRULE"] ? parseRrule(block["RRULE"].value) : undefined,
    };
    if (!raw.uid || !raw.dtstart) continue;

    const occurrences = expand(raw.dtstart, raw.rrule ?? null, Date.now() + HORIZON_YEARS * 365.25 * DAY_MS);
    for (const occ of occurrences) {
      const allDay = occ.isDate || raw.dtstart.isDate;
      // End time uses the occurrence's date with the DTEND's wall-clock time; the
      // date fields come from the occurrence, not from DTEND (which carries the
      // master's date). All-day DTENDs are dates, so take the day after.
      const endMs = raw.dtend
        ? (raw.dtend.isDate
            ? Date.UTC(occ.y, occ.mo - 1, occ.d + 1)
            : toEpoch(
                { ...occ, h: raw.dtend.h, mi: raw.dtend.mi, s: raw.dtend.s },
                occ.tzid || raw.dtend.tzid
              ))
        : epochOf(occ) + (raw.durationMs || (allDay ? DAY_MS : 3600_000));

      if (allDay) {
        events.push({
          uid: `${raw.uid}-${occ.y}${String(occ.mo).padStart(2, "0")}${String(occ.d).padStart(2, "0")}`,
          title: raw.summary || "(untitled)",
          date: `${occ.y}${String(occ.mo).padStart(2, "0")}${String(occ.d).padStart(2, "0")}`,
          allDay: true,
          location: raw.location?.trim() || undefined,
          description: raw.description?.trim() || undefined,
        });
      } else {
        events.push({
          uid: `${raw.uid}-${occ.y}${String(occ.mo).padStart(2, "0")}${String(occ.d).padStart(2, "0")}${String(occ.h).padStart(2, "0")}${String(occ.mi).padStart(2, "0")}`,
          title: raw.summary || "(untitled)",
          start: epochOf(occ),
          end: endMs,
          allDay: false,
          location: raw.location?.trim() || undefined,
          description: raw.description?.trim() || undefined,
        });
      }
    }
  }
  return events;
}
