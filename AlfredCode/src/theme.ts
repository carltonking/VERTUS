/**
 * theme.ts — AlfredCode's palette, glyphs and style helpers.
 *
 * The whole visual language lives here so every component draws from one
 * source. Dark mode only. See the design spec:
 *   bg #0F0F0F→#121212 · text #E6E6E6 · dim #8A8A8A · amber #F5A524
 *   green #4ADE80 · red #F87171 · code bg #1E1E1E · diff add/remove bgs
 */

export const COLORS = {
  bgTop: "#0F0F0F",
  bgBottom: "#121212",
  surface: "#161616",
  border: "#262626",

  text: "#E6E6E6",
  textBright: "#FFFFFF",
  dim: "#8A8A8A",
  faint: "#5C5C5C",

  amber: "#F5A524",
  amberBright: "#FCD34D",

  green: "#4ADE80",
  red: "#F87171",
  yellow: "#FACC15",
  blue: "#7FB4F5",

  codeBg: "#1E1E1E",
  diffAddBg: "#14331F",
  diffRemoveBg: "#331414",
  diffHunk: "#9A9A9A",

  planBg: "#0B1220",
} as const;

/** Every glyph the TUI uses. Kept here so a font/halfwidth terminal issue is
 *  fixed in exactly one place. */
export const GLYPHS = {
  prompt: ">",
  thought: "✻",
  tool: "⏺",
  result: "⎿",
  running: "○",
  done: "●",
  bullet: "·",
  dot: "◯",
  hollow: "◯",
  filled: "●",
  spinner: ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"],
  separator: "─",
  diffAdd: "+",
  diffRemove: "-",
  ellipsis: "…",
} as const;

/** How many columns wide a glyph is. Ink measures by string length, so
 *  double-width CJK glyphs (◯ ● ⏺ ✻ ⎿) need a real-width adjustment when we
 *  do our own truncation/padding. */
export function displayWidth(s: string): number {
  let w = 0;
  for (const ch of s) {
    w += WIDE.has(ch) ? 2 : 1;
  }
  return w;
}

const WIDE = new Set([
  "◯", "●", "○", "⏺", "✻", "⎿", "⧉", "✳", "✢", "…",
  "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏",
]);

/** Right-pad to a display width (wide glyphs count double). */
export function padRight(s: string, width: number): string {
  const w = displayWidth(s);
  return w >= width ? s : s + " ".repeat(width - w);
}

/** Truncate a string to a display width, appending an ellipsis if cut. */
export function truncate(s: string, width: number): string {
  if (displayWidth(s) <= width) return s;
  let out = "";
  let w = 0;
  const limit = Math.max(0, width - 1);
  for (const ch of s) {
    const cw = WIDE.has(ch) ? 2 : 1;
    if (w + cw > limit) break;
    out += ch;
    w += cw;
  }
  return out + GLYPHS.ellipsis;
}

export interface Style {
  color?: string;
  bg?: string;
  bold?: boolean;
  dim?: boolean;
  italic?: boolean;
  underline?: boolean;
  strikethrough?: boolean;
}

/** Format a piece of text with an optional style. Styled strings are plain
 *  ANSI-free text with a style object attached — Ink decides how to paint
 *  them. Nesting works because a child style simply overrides fields. */
export function styled(text: string, style: Style = {}): StyledText {
  return { text, style };
}

export interface StyledText {
  text: string;
  style: Style;
}

/** Concatenate styled runs into a single line. */
export function joinRuns(runs: (StyledText | string)[]): StyledText[] {
  return runs.map((r) => (typeof r === "string" ? { text: r, style: {} } : r));
}

/** The header separator line: a full-width row of dim ─ glyphs. */
export function separatorLine(width: number): string {
  return GLYPHS.separator.repeat(Math.max(1, width));
}

/** Truncate a path for the header: keep the tail, but never split a segment
 *  unless it is genuinely too long. */
export function truncatePath(p: string, max: number): string {
  if (displayWidth(p) <= max) return p;
  const parts = p.split("/");
  let out = parts.pop() ?? p;
  while (parts.length > 0 && displayWidth(out) + displayWidth(parts[parts.length - 1]) + 1 < max) {
    out = `${parts.pop()}/${out}`;
  }
  return truncate(out, max);
}
