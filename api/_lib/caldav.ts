// iCloud CalDAV — create an event on the user's Apple/iCloud calendar via a VEVENT PUT (Basic auth
// with an app-specific password). The calendar URL is discovered once at setup and stored as an env
// var (CALDAV_CALENDAR_URL). Times use TZID + a bundled VTIMEZONE so iCloud places them correctly.

import { ExtractedEvent, USER_TZ } from "./extract";
import { parseToken } from "./keys";

/** America/New_York VTIMEZONE (RFC-correct, so iCloud honors local times + DST). v1 targets this TZ. */
const NY_VTIMEZONE = [
  "BEGIN:VTIMEZONE",
  "TZID:America/New_York",
  "BEGIN:DAYLIGHT",
  "TZOFFSETFROM:-0500",
  "TZOFFSETTO:-0400",
  "TZNAME:EDT",
  "DTSTART:19700308T020000",
  "RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=2SU",
  "END:DAYLIGHT",
  "BEGIN:STANDARD",
  "TZOFFSETFROM:-0400",
  "TZOFFSETTO:-0500",
  "TZNAME:EST",
  "DTSTART:19701101T020000",
  "RRULE:FREQ=YEARLY;BYMONTH=11;BYDAY=1SU",
  "END:STANDARD",
  "END:VTIMEZONE",
];

export async function createEvent(ev: ExtractedEvent): Promise<{ ok: boolean; message: string }> {
  const appleId = process.env.APPLE_ID;
  const appPassword = process.env.APPLE_APP_PASSWORD;
  if (!appleId || !appPassword) return { ok: false, message: "Apple ID / app-specific password isn't set up yet." };
  const auth = "Basic " + Buffer.from(`${appleId}:${appPassword}`).toString("base64");
  const calUrl = await resolveCalendarUrl(auth);
  if (!calUrl) return { ok: false, message: "Couldn't find your iCloud calendar — double-check the Apple ID + app-specific password." };

  const uid = `alfredlite-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
  const ics = buildICS(ev, uid);
  const href = calUrl.replace(/\/+$/, "") + `/${uid}.ics`;
  try {
    const res = await fetch(href, {
      method: "PUT",
      headers: { "Content-Type": "text/calendar; charset=utf-8", Authorization: auth },
      body: ics,
    });
    if ([200, 201, 204].includes(res.status)) return { ok: true, message: confirmText(ev) };
    return { ok: false, message: `The calendar server rejected it (HTTP ${res.status}).` };
  } catch (e: any) {
    return { ok: false, message: `Couldn't reach the calendar: ${e?.message ?? e}` };
  }
}

function buildICS(ev: ExtractedEvent, uid: string): string {
  const lines: string[] = [
    "BEGIN:VCALENDAR",
    "VERSION:2.0",
    "PRODID:-//Alfred Lite//EN",
    "CALSCALE:GREGORIAN",
    ...NY_VTIMEZONE,
    "BEGIN:VEVENT",
    `UID:${uid}`,
    `DTSTAMP:${utcStamp(new Date())}`,
    `SUMMARY:${esc(ev.title)}`,
  ];
  if (ev.allDay) {
    lines.push(`DTSTART;VALUE=DATE:${ev.date.replace(/-/g, "")}`, `DTEND;VALUE=DATE:${nextDay(ev.date).replace(/-/g, "")}`);
  } else {
    const start = ev.start || "09:00";
    const end = ev.end || addHour(start);
    const endDate = end <= start ? nextDay(ev.date) : ev.date; // advance a day for overnight / 23:xx→00:xx wrap
    lines.push(`DTSTART;TZID=${USER_TZ}:${local(ev.date, start)}`, `DTEND;TZID=${USER_TZ}:${local(endDate, end)}`);
  }
  if (ev.location) lines.push(`LOCATION:${esc(ev.location)}`);
  if (ev.notes) lines.push(`DESCRIPTION:${esc(ev.notes)}`);
  if (ev.url) lines.push(`URL:${ev.url}`); // URI value — not TEXT-escaped
  if (ev.categories?.length) lines.push(`CATEGORIES:${ev.categories.map(esc).join(",")}`);
  for (const a of ev.alarms ?? []) {
    lines.push(
      "BEGIN:VALARM",
      "ACTION:DISPLAY",
      `DESCRIPTION:${esc(ev.title)}`,
      `TRIGGER${a.related ? `;RELATED=${a.related}` : ""}:${a.offset}`,
      "END:VALARM",
    );
  }
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.map(fold).join("\r\n");
}

/** RFC5545 line folding at 75 octets (continuations start with a space), on code-point boundaries so
 * multibyte chars (emoji in SUMMARY) are never split. Readers rejoin CRLF+space. */
function fold(line: string): string {
  const chunks: string[] = [];
  let cur = "";
  let curBytes = 0;
  for (const ch of line) {
    const b = Buffer.byteLength(ch, "utf8");
    const limit = chunks.length === 0 ? 75 : 74; // continuations lose one octet to the leading space
    if (curBytes + b > limit) {
      chunks.push(cur);
      cur = "";
      curBytes = 0;
    }
    cur += ch;
    curBytes += b;
  }
  chunks.push(cur);
  return chunks.map((s, i) => (i === 0 ? s : " " + s)).join("\r\n");
}

function confirmText(ev: ExtractedEvent): string {
  const [y, m, d] = ev.date.split("-").map(Number);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const when = ev.allDay ? `${months[m - 1]} ${d}, ${y}` : `${months[m - 1]} ${d}, ${y} at ${ev.start}`;
  const loc = ev.location ? ` · ${ev.location}` : "";
  return `✅ Added “${ev.title}” to your calendar — ${when}${loc}.`;
}

// MARK: - helpers

function local(date: string, time: string): string {
  return `${date.replace(/-/g, "")}T${time.replace(":", "")}00`;
}
function utcStamp(d: Date): string {
  return d.toISOString().replace(/[-:]/g, "").replace(/\.\d{3}/, "");
}
function nextDay(date: string): string {
  const d = new Date(date + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() + 1);
  return d.toISOString().slice(0, 10);
}
function addHour(time: string): string {
  const [h, m] = time.split(":").map(Number);
  const nh = (h + 1) % 24;
  return `${String(nh).padStart(2, "0")}:${String(m).padStart(2, "0")}`;
}
function esc(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/;/g, "\\;").replace(/,/g, "\\,").replace(/\r?\n/g, "\\n");
}

// MARK: - iCloud calendar discovery (auto; cached per warm instance)

let cachedCalUrl: string | null = null;

/** Uses CALDAV_CALENDAR_URL if set, else discovers the user's iCloud calendar via PROPFIND. */
async function resolveCalendarUrl(auth: string): Promise<string | null> {
  if (process.env.CALDAV_CALENDAR_URL) return process.env.CALDAV_CALENDAR_URL;
  if (cachedCalUrl) return cachedCalUrl;
  cachedCalUrl = await discover(auth);
  return cachedCalUrl;
}

async function discover(auth: string): Promise<string | null> {
  const base = "https://caldav.icloud.com";
  // 1. current-user-principal
  const p = await propfind(`${base}/`, auth, "0",
    `<A:propfind xmlns:A="DAV:"><A:prop><A:current-user-principal/></A:prop></A:propfind>`);
  const principal = p && propHref(p.body, "current-user-principal");
  if (!p || !principal) return null;
  const principalUrl = resolve(p.finalUrl || `${base}/`, principal);
  // 2. calendar-home-set
  const h = await propfind(principalUrl, auth, "0",
    `<A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><C:calendar-home-set/></A:prop></A:propfind>`);
  const home = h && propHref(h.body, "calendar-home-set");
  if (!h || !home) return null;
  const homeUrl = resolve(h.finalUrl || principalUrl, home);
  // 3. list calendars, pick a VEVENT-capable one
  const list = await propfind(homeUrl, auth, "1",
    `<A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><A:resourcetype/><A:displayname/><C:supported-calendar-component-set/></A:prop></A:propfind>`);
  const calHref = list && pickCalendar(list.body);
  if (!list || !calHref) return null;
  return resolve(list.finalUrl || homeUrl, calHref);
}

async function propfind(url: string, auth: string, depth: string, body: string): Promise<{ body: string; finalUrl: string } | null> {
  try {
    const res = await fetch(url, {
      method: "PROPFIND",
      headers: { Authorization: auth, Depth: depth, "Content-Type": "application/xml; charset=utf-8" },
      body,
    });
    if (res.status !== 207 && res.status !== 200) return null;
    return { body: await res.text(), finalUrl: res.url || url };
  } catch {
    return null;
  }
}

/** The <href> inside a given property element (namespace-agnostic, best-effort). */
function propHref(xml: string, prop: string): string | null {
  const block = new RegExp(`<[^>]*\\b${prop}\\b[^>]*>([\\s\\S]*?)</[^>]*\\b${prop}\\b[^>]*>`, "i").exec(xml);
  const inner = block ? block[1] : "";
  const m = /<[^>]*\bhref\b[^>]*>([^<]+)<\/[^>]*\bhref\b[^>]*>/i.exec(inner);
  return m ? m[1].trim() : null;
}

interface CalEntry { href: string; name: string; vevent: boolean; isCalendar: boolean; }

/** Parse each <response> into a calendar entry. "calendar" is detected inside <resourcetype> (NOT the
 * href — the home container's path contains "calendars" and must not match), VEVENT inside the
 * supported component set (so reminders lists, which are VTODO, are excluded). */
function parseCalendars(xml: string): CalEntry[] {
  const blocks = xml.split(/<[^>]*\bresponse\b[^>]*>/i).slice(1);
  const entries: CalEntry[] = [];
  for (const b of blocks) {
    const href = (/<[^>]*\bhref\b[^>]*>([^<]+)<\/[^>]*\bhref\b[^>]*>/i.exec(b) || [])[1]?.trim();
    if (!href) continue;
    const rt = (/<[^>]*\bresourcetype\b[^>]*>([\s\S]*?)<\/[^>]*\bresourcetype\b[^>]*>/i.exec(b) || [])[1] || "";
    const ccs = (/<[^>]*supported-calendar-component-set[^>]*>([\s\S]*?)<\/[^>]*supported-calendar-component-set[^>]*>/i.exec(b) || [])[1] || "";
    const name = ((/<[^>]*\bdisplayname\b[^>]*>([^<]*)<\/[^>]*\bdisplayname\b[^>]*>/i.exec(b) || [])[1] || "").trim();
    entries.push({ href, name, isCalendar: /\bcalendar\b/i.test(rt), vevent: /VEVENT/i.test(ccs) });
  }
  return entries;
}

/** A writable VEVENT calendar collection, preferring the user's primary over holiday/birthday feeds. */
function pickCalendar(xml: string): string | null {
  const cals = parseCalendars(xml).filter((c) => c.isCalendar && c.vevent);
  if (!cals.length) return null;
  const deprioritize = /holiday|birthday|siri|subscrib|shared|us holidays/i;
  const preferred = cals.filter((c) => !deprioritize.test(c.name));
  return (preferred.length ? preferred : cals)[0].href;
}

function resolve(base: string, href: string): string {
  try {
    return href.startsWith("http") ? href : new URL(href, base).toString();
  } catch {
    return href;
  }
}

// MARK: - Batch create / read / delete (syllabus)

function authHeader(): string | null {
  const appleId = process.env.APPLE_ID;
  const appPassword = process.env.APPLE_APP_PASSWORD;
  if (!appleId || !appPassword) return null;
  return "Basic " + Buffer.from(`${appleId}:${appPassword}`).toString("base64");
}

async function pool<T>(items: T[], size: number, fn: (item: T) => Promise<void>): Promise<void> {
  let i = 0;
  const workers = Array.from({ length: Math.max(1, Math.min(size, items.length)) }, async () => {
    while (i < items.length) {
      const idx = i++;
      await fn(items[idx]);
    }
  });
  await Promise.all(workers);
}

export interface BatchResult { created: number; failed: number; failures: string[] }

/** Batch-create events, resolving the calendar + auth ONCE. Deterministic ev.uid → re-PUT overwrites
 * (idempotent re-upload). Cloud-only for now; cross-platform search-before-create lands with the Mac. */
export async function createEvents(events: ExtractedEvent[]): Promise<BatchResult> {
  const auth = authHeader();
  if (!auth) return { created: 0, failed: events.length, failures: ["Apple ID / app password not set"] };
  const calUrl = await resolveCalendarUrl(auth);
  if (!calUrl) return { created: 0, failed: events.length, failures: ["couldn't find your iCloud calendar"] };
  const base = calUrl.replace(/\/+$/, "");
  let created = 0;
  let failed = 0;
  const failures: string[] = [];
  await pool(events, 4, async (ev) => {
    const uid = ev.uid ?? `alfredlite-${Date.now()}-${Math.floor(Math.random() * 1e6)}`;
    const res = await fetch(`${base}/${uid}.ics`, {
      method: "PUT",
      headers: { "Content-Type": "text/calendar; charset=utf-8", Authorization: auth },
      body: buildICS(ev, uid),
    }).catch(() => null);
    if (res && [200, 201, 204].includes(res.status)) created++;
    else {
      failed++;
      failures.push(`${ev.title} (HTTP ${res?.status ?? "net"})`);
    }
  });
  return { created, failed, failures };
}

export interface SchoolRef { href: string; token: Record<string, string> }

/** calendar-query REPORT for Alfred-tagged events in a wide window; returns hrefs + parsed tokens. */
async function listSchool(auth: string, calUrl: string, daysBack = 400, daysFwd = 400): Promise<SchoolRef[]> {
  const now = new Date();
  const start = utcStamp(new Date(now.getTime() - daysBack * 86400000));
  const end = utcStamp(new Date(now.getTime() + daysFwd * 86400000));
  const body =
    `<C:calendar-query xmlns:D="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav">` +
    `<D:prop><D:getetag/><C:calendar-data/></D:prop>` +
    `<C:filter><C:comp-filter name="VCALENDAR"><C:comp-filter name="VEVENT">` +
    `<C:time-range start="${start}" end="${end}"/>` +
    `</C:comp-filter></C:comp-filter></C:filter></C:calendar-query>`;
  const res = await fetch(calUrl, {
    method: "REPORT",
    headers: { Authorization: auth, Depth: "1", "Content-Type": "application/xml; charset=utf-8" },
    body,
  }).catch(() => null);
  if (!res || (res.status !== 207 && res.status !== 200)) return [];
  return parseSchoolRefs(await res.text());
}

function parseSchoolRefs(xml: string): SchoolRef[] {
  const blocks = xml.split(/<[^>]*\bresponse\b[^>]*>/i).slice(1);
  const refs: SchoolRef[] = [];
  for (const b of blocks) {
    const href = (/<[^>]*\bhref\b[^>]*>([^<]+)<\/[^>]*\bhref\b[^>]*>/i.exec(b) || [])[1]?.trim();
    if (!href) continue;
    const cdata = (/<[^>]*calendar-data[^>]*>([\s\S]*?)<\/[^>]*calendar-data[^>]*>/i.exec(b) || [])[1];
    if (!cdata) continue;
    const ics = unfoldICS(xmlUnescape(cdata));
    const desc = icsProp(ics, "DESCRIPTION"); // token has no escapable chars, so raw value is fine
    const tok = desc ? parseToken(desc) : null;
    if (tok) refs.push({ href, token: tok });
  }
  return refs;
}

/** Delete all Alfred-tagged events whose token matches `pred`. Returns count, or null on setup error. */
export async function deleteSchool(pred: (tok: Record<string, string>) => boolean): Promise<number | null> {
  const auth = authHeader();
  if (!auth) return null;
  const calUrl = await resolveCalendarUrl(auth);
  if (!calUrl) return null;
  const refs = (await listSchool(auth, calUrl)).filter((r) => pred(r.token));
  let deleted = 0;
  await pool(refs, 4, async (r) => {
    const url = resolve(calUrl, r.href);
    const res = await fetch(url, { method: "DELETE", headers: { Authorization: auth } }).catch(() => null);
    if (res && [200, 202, 204, 404].includes(res.status)) deleted++;
  });
  return deleted;
}

/** Owner-gated read diagnostic: list currently-tagged Alfred events (href + token). */
export async function listSchoolDiag(): Promise<{ count: number; items: SchoolRef[] } | null> {
  const auth = authHeader();
  if (!auth) return null;
  const calUrl = await resolveCalendarUrl(auth);
  if (!calUrl) return null;
  const refs = await listSchool(auth, calUrl);
  return { count: refs.length, items: refs.slice(0, 50) };
}

function xmlUnescape(s: string): string {
  return s
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&#(\d+);/g, (_, n) => String.fromCharCode(Number(n)))
    .replace(/&amp;/g, "&");
}
function unfoldICS(ics: string): string {
  return ics.replace(/\r?\n[ \t]/g, "");
}
function icsProp(ics: string, name: string): string | null {
  // Capture up to the line terminator directly — avoids ".*$" failing against CRLF (. stops at \r).
  const m = new RegExp(`^${name}(?:;[^:\\r\\n]*)?:([^\\r\\n]*)`, "im").exec(ics);
  return m ? m[1].trim() : null;
}

// MARK: - Diagnostics (owner-gated; reports each discovery step + a test PUT, never the credentials)

export async function diagnose(doPut = false): Promise<Record<string, unknown>> {
  const appleId = process.env.APPLE_ID;
  const appPassword = process.env.APPLE_APP_PASSWORD;
  const out: Record<string, unknown> = {
    hasAppleId: !!appleId,
    hasAppPassword: !!appPassword,
    appleIdLooksLikeEmail: !!appleId && /.+@.+\..+/.test(appleId),
    appPasswordLen: appPassword ? appPassword.length : 0,
    envCalUrlSet: !!process.env.CALDAV_CALENDAR_URL,
  };
  if (!appleId || !appPassword) return out;
  const auth = "Basic " + Buffer.from(`${appleId}:${appPassword}`).toString("base64");
  const base = "https://caldav.icloud.com";

  const p = await propfind(`${base}/`, auth, "0",
    `<A:propfind xmlns:A="DAV:"><A:prop><A:current-user-principal/></A:prop></A:propfind>`);
  out.step1_principal_ok = !!p;
  if (!p) { out.hint = "PROPFIND to caldav.icloud.com returned non-207 — usually a wrong Apple ID / app-specific password (401)."; return out; }
  const principal = propHref(p.body, "current-user-principal");
  out.principalHref = principal;
  if (!principal) { out.step1_body = p.body.slice(0, 300); return out; }
  const principalUrl = resolve(p.finalUrl || `${base}/`, principal);
  out.principalUrl = principalUrl;

  const h = await propfind(principalUrl, auth, "0",
    `<A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><C:calendar-home-set/></A:prop></A:propfind>`);
  out.step2_home_ok = !!h;
  if (!h) return out;
  const home = propHref(h.body, "calendar-home-set");
  out.homeHref = home;
  if (!home) { out.step2_body = h.body.slice(0, 300); return out; }
  const homeUrl = resolve(h.finalUrl || principalUrl, home);
  out.homeUrl = homeUrl;

  const list = await propfind(homeUrl, auth, "1",
    `<A:propfind xmlns:A="DAV:" xmlns:C="urn:ietf:params:xml:ns:caldav"><A:prop><A:resourcetype/><A:displayname/><C:supported-calendar-component-set/></A:prop></A:propfind>`);
  out.step3_list_ok = !!list;
  if (!list) return out;
  out.calendars = parseCalendars(list.body).map((c) => ({ href: c.href, name: c.name, isCalendar: c.isCalendar, vevent: c.vevent }));
  const calHref = pickCalendar(list.body);
  out.calHref = calHref;
  if (!calHref) { out.step3_body = list.body.slice(0, 1500); return out; }
  const calUrl = resolve(list.finalUrl || homeUrl, calHref);
  out.calUrl = calUrl;
  if (!doPut) { out.putSkipped = "read-only diagnostic (add &put=1 to write a throwaway test event)"; return out; }

  // Test PUT of a throwaway event (safe to delete) to see iCloud's actual response.
  const now = new Date();
  const tomorrow = new Intl.DateTimeFormat("en-CA", { timeZone: USER_TZ, year: "numeric", month: "2-digit", day: "2-digit" })
    .format(new Date(now.getTime() + 86400000));
  const testEv: ExtractedEvent = {
    title: "🔁 Alfred diagnostic (safe to delete)",
    date: tomorrow,
    start: "15:00",
    end: "16:00",
    allDay: false,
    location: null,
    notes: "Diagnostic\n\n[alfred|v1|k=diagnostic00|c=DIAG|t=other|b=DIAG-x]",
    url: "alfred://school/DIAG/other/diagnostic00",
    categories: ["Alfred", "School", "DIAG", "other", "DIAG-x"],
    alarms: [{ offset: "-PT1H" }],
  };
  const uid = `alfreddiag-${Date.now()}`;
  const ics = buildICS(testEv, uid);
  out.ics = ics;
  const href = calUrl.replace(/\/+$/, "") + `/${uid}.ics`;
  out.putHref = href;
  try {
    const put = await fetch(href, {
      method: "PUT",
      headers: { "Content-Type": "text/calendar; charset=utf-8", Authorization: auth },
      body: ics,
    });
    out.putStatus = put.status;
    out.putBody = (await put.text()).slice(0, 600);
  } catch (e: any) {
    out.putError = String(e?.message ?? e);
  }
  return out;
}
