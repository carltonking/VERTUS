// 5-field cron (`minute hour day-of-month month day-of-week`) — a faithful TS port of the Mac's
// CronSchedule.swift. Supports `*`, single values, lists (`a,b`), ranges (`a-b`), and steps (`*/n`,
// `a-b/n`, `n/step`). Day-of-week: 0 or 7 = Sunday; standard OR-semantics between DOM and DOW when both
// are restricted.
//
// Unlike the Mac (which ticks every 60s and matches the exact current minute), the cloud runner is
// driven by an external pinger that does NOT align to the minute. So the useful entry point here is
// `dueSince` — "did an occurrence fire in the (since, now] window?" — which tolerates any tick cadence.

export interface Cron {
  minutes: Set<number>;
  hours: Set<number>;
  daysOfMonth: Set<number>;
  months: Set<number>;
  daysOfWeek: Set<number>; // normalized 0-6, 0 = Sunday
  domRestricted: boolean;
  dowRestricted: boolean;
}

export function parseCron(expression: string): Cron | null {
  const fields = expression.trim().split(/\s+/);
  if (fields.length !== 5) return null;
  const minutes = parseField(fields[0], 0, 59);
  const hours = parseField(fields[1], 0, 23);
  const daysOfMonth = parseField(fields[2], 1, 31);
  const months = parseField(fields[3], 1, 12);
  const dowRaw = parseField(fields[4], 0, 7);
  if (!minutes || !hours || !daysOfMonth || !months || !dowRaw) return null;
  return {
    minutes,
    hours,
    daysOfMonth,
    months,
    daysOfWeek: new Set([...dowRaw].map((d) => (d === 7 ? 0 : d))),
    domRestricted: fields[2] !== "*",
    dowRestricted: fields[4] !== "*",
  };
}

/** True when `date`, read in `tz`, matches every cron field to minute resolution. */
export function cronMatches(c: Cron, date: Date, tz: string): boolean {
  const w = wallParts(date, tz);
  if (!c.minutes.has(w.minute) || !c.hours.has(w.hour) || !c.months.has(w.month)) return false;
  const domMatch = c.daysOfMonth.has(w.day);
  const dowMatch = c.daysOfWeek.has(w.dow);
  if (c.domRestricted && c.dowRestricted) return domMatch || dowMatch;
  if (c.domRestricted) return domMatch;
  if (c.dowRestricted) return dowMatch;
  return true;
}

const WINDOW_CAP_MS = 15 * 60_000; // never fire an occurrence older than this (don't spam after downtime)

/** Epoch ms of the most recent cron occurrence in (sinceMs, nowMs], or null. Minute-stepped, and the
 *  look-back is capped so a long pinger outage doesn't replay a stale routine hours late. */
export function dueSince(expression: string, tz: string, sinceMs: number, nowMs: number): number | null {
  const c = parseCron(expression);
  if (!c) return null;
  const start = Math.max(sinceMs, nowMs - WINDOW_CAP_MS);
  let t = Math.floor(start / 60_000) * 60_000 + 60_000; // first minute strictly after `start`
  let last: number | null = null;
  for (; t <= nowMs; t += 60_000) {
    if (cronMatches(c, new Date(t), tz)) last = t;
  }
  return last;
}

// MARK: - Field parsing (ports parseField / parsePart)

function parseField(field: string, min: number, max: number): Set<number> | null {
  const result = new Set<number>();
  for (const part of field.split(",")) {
    const values = parsePart(part, min, max);
    if (!values) return null;
    for (const v of values) result.add(v);
  }
  return result.size ? result : null;
}

function parsePart(part: string, min: number, max: number): Set<number> | null {
  let rangePart = part;
  let step = 1;
  let hasStep = false;
  const slash = part.indexOf("/");
  if (slash >= 0) {
    rangePart = part.slice(0, slash);
    const s = Number(part.slice(slash + 1));
    if (!Number.isInteger(s) || s <= 0) return null;
    step = s;
    hasStep = true;
  }

  let lo: number;
  let hi: number;
  if (rangePart === "*") {
    lo = min;
    hi = max;
  } else if (rangePart.includes("-")) {
    const [a, b] = rangePart.split("-");
    const av = Number(a);
    const bv = Number(b);
    if (!Number.isInteger(av) || !Number.isInteger(bv)) return null;
    lo = av;
    hi = bv;
  } else {
    const v = Number(rangePart);
    if (!Number.isInteger(v)) return null;
    lo = v;
    hi = hasStep ? max : v; // "n/step" means n..max stepping by `step`
  }
  if (lo < min || hi > max || lo > hi) return null;

  const out = new Set<number>();
  for (let v = lo; v <= hi; v += step) out.add(v);
  return out;
}

// MARK: - Wall-clock components in a time zone

interface Wall { minute: number; hour: number; day: number; month: number; dow: number }

const DOW: Record<string, number> = { Sun: 0, Mon: 1, Tue: 2, Wed: 3, Thu: 4, Fri: 5, Sat: 6 };

function wallParts(date: Date, tz: string): Wall {
  const p = new Intl.DateTimeFormat("en-US", {
    timeZone: tz, hour12: false, weekday: "short",
    year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit",
  }).formatToParts(date).reduce<Record<string, string>>((a, x) => ((a[x.type] = x.value), a), {});
  return {
    minute: Number(p.minute),
    hour: p.hour === "24" ? 0 : Number(p.hour),
    day: Number(p.day),
    month: Number(p.month),
    dow: DOW[p.weekday] ?? 0,
  };
}
