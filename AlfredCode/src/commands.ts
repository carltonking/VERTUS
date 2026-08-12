/**
 * commands.ts — the `/` command palette, the `@` file finder, and plan mode.
 *
 * Both overlays are pure logic: they return a filtered list of entries the UI
 * renders, and the UI calls back to act on the selection.
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, basename } from "node:path";

export interface CommandEntry {
  command: string;
  description: string;
  /** Called with the raw typed text after the command (e.g. "/model foo"). */
  run: (arg: string) => void;
}

/** The palette, ordered with the most-used at the top. */
export function buildPalette(ctx: {
  clear: () => void;
  togglePlan: () => void;
  showCost: () => void;
  showHelp: () => void;
  compact: () => void;
  review: () => void;
  quit: () => void;
}): CommandEntry[] {
  return [
    { command: "/help", description: "Show key bindings and this list", run: () => ctx.showHelp() },
    { command: "/clear", description: "Start a fresh session (new agent process, empty transcript)", run: () => ctx.clear() },
    { command: "/plan", description: "Toggle plan mode — read-only analysis, no edits", run: () => ctx.togglePlan() },
    { command: "/cost", description: "Show token usage and estimated cost for this session", run: () => ctx.showCost() },
    { command: "/compact", description: "Summarize the conversation and continue fresh", run: () => ctx.compact() },
    { command: "/model", description: "Show the agent, model and provider in use", run: () => ctx.showHelp() },
    { command: "/review", description: "Ask the agent to review the changes it just made", run: () => ctx.review() },
    { command: "/quit", description: "Exit AlfredCode", run: () => ctx.quit() },
  ];
}

// ---------------------------------------------------------------------------
// File finder
// ---------------------------------------------------------------------------

export interface FileEntry {
  path: string;       // relative to cwd (what gets inserted)
  display: string;    // how it shows in the overlay
  preview: string;    // first non-empty line, for the one-line preview
}

const SKIP_DIRS = new Set([
  "node_modules", ".git", ".next", ".cache", "dist", "build", ".venv", "venv",
  "target", ".build", "DerivedData", ".tmp", "tmp", ".turbo", ".swc", ".svn",
  ".hg", ".DS_Store",
]);

const SKIP_FILES = new Set([".DS_Store"]);

const MAX_FILES = 400;

/** Walk the project tree collecting file entries. Shallow-ish: bounded depth
 *  and count so a huge repo can't hang the finder. */
export function scanFiles(cwd: string, depth = 0): FileEntry[] {
  const out: FileEntry[] = [];
  if (depth > 3 || out.length >= MAX_FILES) return out;
  let entries: string[];
  try {
    entries = readdirSync(cwd);
  } catch {
    return out;
  }
  for (const name of entries) {
    if (SKIP_FILES.has(name)) continue;
    const full = join(cwd, name);
    try {
      const st = statSync(full);
      if (st.isDirectory()) {
        if (SKIP_DIRS.has(name)) continue;
        out.push(...scanFiles(full, depth + 1));
      } else if (st.size < 512 * 1024) {
        out.push(makeFileEntry(full));
      }
    } catch {
      /* unreadable — skip */
    }
    if (out.length >= MAX_FILES) break;
  }
  return out;
}

function makeFileEntry(full: string): FileEntry {
  const preview = firstLine(full);
  return {
    path: full,
    display: basename(full),
    preview,
  };
}

function firstLine(path: string): string {
  try {
    const buf = readFileSync(path);
    const text = buf.toString("utf8", 0, Math.min(buf.length, 2048));
    const line = text.split("\n").map((l) => l.trim()).find((l) => l.length > 0) ?? "";
    return line.slice(0, 90);
  } catch {
    return "";
  }
}

/** Fuzzy-match a query against a path+name. Returns a score (higher better)
 *  or -1 when there is no match. */
export function fuzzyScore(query: string, entry: FileEntry): number {
  const q = query.toLowerCase();
  if (!q) return 1;
  const hay = `${basename(entry.path)} ${entry.path}`.toLowerCase();
  if (hay.includes(q)) return 100 + q.length;
  // subsequence match: every char of q appears in order.
  let i = 0;
  for (const ch of hay) {
    if (ch === q[i]) i++;
    if (i === q.length) return 50 + q.length;
  }
  return -1;
}

/** The file finder result for the current query. */
export function filterFiles(cwd: string, query: string, cache?: FileEntry[] | null): FileEntry[] {
  const all = cache ?? scanFiles(cwd);
  const scored = all
    .map((e) => ({ e, s: fuzzyScore(query, e) }))
    .filter((x) => x.s >= 0)
    .sort((a, b) => b.s - a.s);
  return scored.slice(0, 12).map((x) => x.e);
}
