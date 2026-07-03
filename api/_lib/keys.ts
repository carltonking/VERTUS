// Shared syllabus identity + VEVENT-metadata encoding (the cross-platform "contract"). The Mac app must
// mirror this exactly so both sides read/write the same tagged iCloud events. Metadata rides in fields
// BOTH readers can see (URL + a DESCRIPTION token) — EventKit can't read CATEGORIES/X- props.

import { createHash } from "crypto";

/** Canonical course code: uppercase, strip everything non-alphanumeric. "cs 101" -> "CS101". */
export function normCode(code: string): string {
  return code.toUpperCase().replace(/[^A-Z0-9]/g, "");
}

/** Normalized title for the identity key: strip diacritics/punctuation, collapse spaces, drop a leading
 * echo of the course code. "PS #3 (CS101)" -> "ps 3". */
export function normTitle(title: string, code?: string): string {
  // NFKD decomposes accents; the [^a-z0-9] filter below then drops the combining marks too.
  let t = title.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
  if (code) {
    // Normalize the code the SAME way as the title (spaces preserved, so "CS 101" -> "cs 101"),
    // then strip a leading OR trailing echo of it. "cs 101 midterm 2" -> "midterm 2".
    const nc = code.normalize("NFKD").toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();
    if (nc) t = t.replace(new RegExp(`^${nc}\\s+|\\s+${nc}$`), "").trim();
  }
  return t;
}

function sha12(src: string): string {
  return createHash("sha256").update(src).digest("hex").slice(0, 12);
}

/** Stable per-item key. Date is INCLUDED so two same-type items with the same title on different dates
 * (e.g. weekly "Reading Response") get distinct ids and can't silently overwrite each other. Trade-off:
 * a rescheduled item becomes a new event and the old one is orphaned until /school delete (or the
 * Phase-2 reconciler) removes it. */
export function itemKey(code: string, itemType: string, title: string, date: string): string {
  return sha12(`${normCode(code)}|${itemType}|${normTitle(title, code)}|${date}`);
}

/** Study-session key: derived from the exam it prepares for + the day offset (stable across re-runs). */
export function studyKey(code: string, examKey: string, offset: number): string {
  return sha12(`${normCode(code)}|study|${examKey}|D-${offset}`);
}

/** Per-import batch tag (used for bulk delete/undo and CATEGORIES). */
export function batchId(code: string, termYear: number | null): string {
  return `${normCode(code)}-${termYear ?? "x"}`;
}

/** Custom-scheme identity anchor stored in the VEVENT URL property (least-edited field). */
export function schoolURL(code: string, type: string, key: string): string {
  return `alfred://school/${normCode(code)}/${type}/${key}`;
}

export interface SchoolMeta {
  key: string;
  code: string;
  type: string;
  batch: string;
  weight?: string | null;
  topics?: string[];
  linkedExamKey?: string | null;
}

/** Only ICS-non-escapable chars, so the token is byte-identical raw (CalDAV) vs. unescaped (EventKit). */
function tokenVal(s: string): string {
  return s.replace(/[|\][~=;,\\\r\n]+/g, " ").replace(/\s+/g, " ").trim();
}

/** The machine-readable payload appended to DESCRIPTION/notes. Delimiters are `|` and `~` (never escaped). */
export function schoolToken(m: SchoolMeta): string {
  const parts = [`k=${m.key}`, `c=${normCode(m.code)}`, `t=${m.type}`, `b=${m.batch}`];
  if (m.weight) parts.push(`w=${tokenVal(m.weight)}`);
  if (m.linkedExamKey) parts.push(`x=${m.linkedExamKey}`);
  if (m.topics && m.topics.length) parts.push(`tp=${m.topics.map(tokenVal).filter(Boolean).join("~")}`);
  return `[alfred|v1|${parts.join("|")}]`;
}

export function schoolCategories(code: string, type: string, batch: string): string[] {
  return ["Alfred", "School", normCode(code), type, batch];
}

/** Parse the `[alfred|v1|...]` token out of a DESCRIPTION/notes string. */
export function parseToken(text: string): Record<string, string> | null {
  const m = /\[alfred\|v1\|([^\]]*)\]/.exec(text || "");
  if (!m) return null;
  const out: Record<string, string> = {};
  for (const kv of m[1].split("|")) {
    const i = kv.indexOf("=");
    if (i > 0) out[kv.slice(0, i)] = kv.slice(i + 1);
  }
  return out;
}
