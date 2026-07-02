// iCloud CalDAV — create an event on the user's Apple/iCloud calendar via a VEVENT PUT (Basic auth
// with an app-specific password). The calendar URL is discovered once at setup and stored as an env
// var (CALDAV_CALENDAR_URL). Times use TZID + a bundled VTIMEZONE so iCloud places them correctly.

import { ExtractedEvent, USER_TZ } from "./extract";

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
    lines.push(`DTSTART;TZID=${USER_TZ}:${local(ev.date, start)}`, `DTEND;TZID=${USER_TZ}:${local(ev.date, end)}`);
  }
  if (ev.location) lines.push(`LOCATION:${esc(ev.location)}`);
  if (ev.notes) lines.push(`DESCRIPTION:${esc(ev.notes)}`);
  lines.push("END:VEVENT", "END:VCALENDAR");
  return lines.join("\r\n");
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

/** First calendar collection that supports VEVENT (falls back to any calendar collection). */
function pickCalendar(xml: string): string | null {
  const blocks = xml.split(/<[^>]*\bresponse\b[^>]*>/i).slice(1);
  const hrefOf = (b: string) => (/<[^>]*\bhref\b[^>]*>([^<]+)<\/[^>]*\bhref\b[^>]*>/i.exec(b) || [])[1]?.trim() || null;
  for (const b of blocks) if (/calendar/i.test(b) && /VEVENT/i.test(b)) { const h = hrefOf(b); if (h) return h; }
  for (const b of blocks) if (/<[^>]*\bcalendar\b[^>]*\/>/i.test(b)) { const h = hrefOf(b); if (h) return h; }
  return null;
}

function resolve(base: string, href: string): string {
  try {
    return href.startsWith("http") ? href : new URL(href, base).toString();
  } catch {
    return href;
  }
}
