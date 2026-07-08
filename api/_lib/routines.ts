// Cloud routines — the always-on set, authored from Telegram and stored in Upstash (a single JSON blob,
// fine for a handful). These run in the cloud so they fire even when the Mac is off. Distinct from the
// Mac's local routines (which run through AssistantCore and can touch iMessage/files); a cloud routine
// is a scheduled prompt answered by the LLM (+ optional fresh-news context).

import { kvGet, kvSet } from "./kv";
import { parseCron } from "./cron";
import { USER_TZ } from "./extract";

export interface CloudRoutine {
  id: string;
  title: string;
  cron: string;    // 5-field
  tz: string;      // IANA
  prompt: string;
  web: boolean;    // prepend fresh news headlines before answering
  enabled: boolean;
  createdAt: number;
}

const KEY = "routines:all";

export async function getRoutines(): Promise<CloudRoutine[]> {
  const raw = await kvGet(KEY);
  if (!raw) return [];
  try {
    const list = JSON.parse(raw);
    return Array.isArray(list) ? (list as CloudRoutine[]) : [];
  } catch {
    return [];
  }
}

async function saveRoutines(list: CloudRoutine[]): Promise<void> {
  await kvSet(KEY, JSON.stringify(list));
}

/** Short, URL/key-safe id (fired-markers embed it). Not security-sensitive. */
function newId(): string {
  return Date.now().toString(36) + Math.floor(Math.random() * 1e4).toString(36);
}

export async function addRoutine(r: Omit<CloudRoutine, "id" | "createdAt">): Promise<CloudRoutine> {
  const list = await getRoutines();
  const routine: CloudRoutine = { ...r, id: newId(), createdAt: Date.now() };
  list.push(routine);
  await saveRoutines(list);
  return routine;
}

/** Remove by id or 1-based index (as shown in /routine list). Returns the removed routine or null. */
export async function removeRoutine(idOrIndex: string): Promise<CloudRoutine | null> {
  const list = await getRoutines();
  let idx = list.findIndex((r) => r.id === idOrIndex);
  if (idx < 0) {
    const n = Number(idOrIndex);
    if (Number.isInteger(n) && n >= 1 && n <= list.length) idx = n - 1;
  }
  if (idx < 0) return null;
  const [removed] = list.splice(idx, 1);
  await saveRoutines(list);
  return removed;
}

/** Toggle enabled by id or 1-based index. Returns the updated routine or null. */
export async function setRoutineEnabled(idOrIndex: string, enabled: boolean): Promise<CloudRoutine | null> {
  const list = await getRoutines();
  let idx = list.findIndex((r) => r.id === idOrIndex);
  if (idx < 0) {
    const n = Number(idOrIndex);
    if (Number.isInteger(n) && n >= 1 && n <= list.length) idx = n - 1;
  }
  if (idx < 0) return null;
  list[idx].enabled = enabled;
  await saveRoutines(list);
  return list[idx];
}

// MARK: - Schedule phrase → cron

const DOW_NUM: Record<string, number> = { sun: 0, mon: 1, tue: 2, wed: 3, thu: 4, fri: 5, sat: 6 };

/** Parse a schedule that's either a raw 5-field cron OR a friendly phrase. Returns a valid cron string
 *  (validated via parseCron) or null. Examples: "daily 07:00", "weekdays 8:30", "every 30 min",
 *  "every 2 hours", "mon,wed,fri 18:00", "0 6 * * *". */
export function parseWhen(input: string): string | null {
  const s = input.trim().toLowerCase();
  if (!s) return null;

  // Already a 5-field cron?
  if (s.split(/\s+/).length === 5 && parseCron(s)) return s;

  const hm = /(\d{1,2}):(\d{2})/.exec(s);
  const at = hm ? { h: Number(hm[1]), m: Number(hm[2]) } : null;
  const validHM = !!at && at.h >= 0 && at.h <= 23 && at.m >= 0 && at.m <= 59;

  let cron: string | null = null;
  if (/^every\s+(\d+)\s*m(in)?/.test(s)) {
    const n = Number(/^every\s+(\d+)/.exec(s)![1]);
    if (n >= 1 && n <= 59) cron = `*/${n} * * * *`;
  } else if (/^every\s+(\d+)\s*h(our|r)?/.test(s)) {
    const n = Number(/^every\s+(\d+)/.exec(s)![1]);
    if (n >= 1 && n <= 23) cron = `0 */${n} * * *`;
  } else if (validHM && /(daily|every day|each day)/.test(s)) {
    cron = `${at!.m} ${at!.h} * * *`;
  } else if (validHM && /weekday/.test(s)) {
    cron = `${at!.m} ${at!.h} * * 1-5`;
  } else if (validHM && /weekend/.test(s)) {
    cron = `${at!.m} ${at!.h} * * 0,6`;
  } else if (validHM) {
    // Explicit day list ("mon,wed,fri 18:00") or a bare time (→ daily).
    const days = Object.keys(DOW_NUM).filter((d) => new RegExp(`\\b${d}`).test(s)).map((d) => DOW_NUM[d]);
    cron = days.length ? `${at!.m} ${at!.h} * * ${days.sort().join(",")}` : `${at!.m} ${at!.h} * * *`;
  }

  return cron && parseCron(cron) ? cron : null;
}

export { USER_TZ };
