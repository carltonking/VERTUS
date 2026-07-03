// Backward-planned study schedule: for each exam/final, drop spaced study blocks on the calendar (denser
// as the exam nears), each a timed event with a reminder. Deterministic — same syllabus → same blocks
// (idempotent keys), so re-uploading never duplicates. No AI (cheaper, no hallucinated dates).

import { ExtractedEvent, SyllabusItem, USER_TZ } from "./extract";
import { studyKey, normCode, schoolURL, schoolToken, schoolCategories } from "./keys";

// Days-before-exam offsets by importance (earliest first). Finals get the most sessions.
const OFFSETS: Record<string, number[]> = {
  final: [14, 10, 7, 4, 2, 1],
  exam: [7, 4, 2, 1],
  quiz: [2, 1],
};

/** Study sessions for one exam/final/quiz, as calendar events. `examKey` is the exam's item key. */
export function planStudySessions(
  exam: SyllabusItem,
  code: string,
  examKey: string,
  batch: string,
  now: Date,
): ExtractedEvent[] {
  const offsets = OFFSETS[exam.type];
  if (!offsets) return [];
  const today = isoToday(now);
  const nowHour = hourNow(now);
  const startHour = 17 + (parseInt(examKey.slice(0, 2), 16) % 4); // 17..20, stable per exam (avoids stacking)
  const start = `${pad(startHour)}:00`;
  const end = `${pad(startHour + 1)}:30`; // 90-minute block
  const topics = exam.topics;
  const teach = Math.max(1, offsets.length - 2); // last 2 sessions are full review
  const per = topics.length ? Math.ceil(topics.length / teach) : 0;

  const out: ExtractedEvent[] = [];
  offsets.forEach((d, i) => {
    const date = subtractDays(exam.date, d);
    // Skip the past — including a same-day block whose start hour has already gone by.
    if (date < today || (date === today && startHour <= nowHour)) return;

    let focus: string;
    if (!topics.length) focus = `Prep for ${exam.title}`;
    else if (i < teach) {
      const chunk = topics.slice(i * per, i * per + per);
      focus = chunk.length ? `Focus: ${chunk.join(", ")}` : `Review: ${topics.join(", ")}`;
    } else {
      focus = `Review: ${topics.join(", ")}`;
    }

    const k = studyKey(code, examKey, d);
    out.push({
      title: `🔁 [${code}] Study: ${exam.title}`,
      date,
      start,
      end,
      allDay: false,
      location: null,
      notes: `${focus}\n\n${schoolToken({ key: k, code, type: "study", batch, linkedExamKey: examKey })}`,
      url: schoolURL(code, "study", k),
      categories: schoolCategories(code, "study", batch),
      uid: `alfred-${k}`,
      alarms: [{ related: "START", offset: "-PT30M" }],
    });
  });
  return out;
}

function pad(n: number): string {
  return String(n).padStart(2, "0");
}
function subtractDays(date: string, n: number): string {
  const d = new Date(date + "T12:00:00Z");
  d.setUTCDate(d.getUTCDate() - n);
  return d.toISOString().slice(0, 10);
}
function isoToday(now: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: USER_TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}
function hourNow(now: Date): number {
  return Number(new Intl.DateTimeFormat("en-US", { timeZone: USER_TZ, hour: "2-digit", hour12: false }).format(now)) % 24;
}
