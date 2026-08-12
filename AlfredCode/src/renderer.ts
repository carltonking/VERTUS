/**
 * renderer.ts — turns markdown, tool output and unified diffs into styled
 * terminal rows. No ANSI escapes; everything is plain text + a Style object
 * that Ink paints. Width-aware wrapping and truncation happen here so the UI
 * never has to think about columns.
 */

import { COLORS, displayWidth, truncate, type Style } from "./theme.js";

// A run is one styled piece of text; a line is one terminal row.
export type Run = { t: string; s?: Style };
export type Line = Run[];

export function plain(t: string, s?: Style): Run[] {
  return [{ t, s }];
}

export function wrapRuns(runs: Run[], width: number): Line[] {
  if (width <= 2) return [[{ t: "" }]];
  const lines: Line[] = [];
  let cur: Run[] = [];
  let curW = 0;
  const flush = () => {
    lines.push(cur.length ? cur : [{ t: "" }]);
    cur = [];
    curW = 0;
  };
  for (const run of runs) {
    const words = run.t.split(/(\s+)/);
    for (const word of words) {
      if (word === "") continue;
      const w = displayWidth(word);
      if (curW + w > width) {
        if (curW > 0) flush();
        // A single word wider than the viewport must still break.
        if (w > width) {
          const pieces = chunkWord(word, width);
          for (let i = 0; i < pieces.length; i++) {
            cur.push({ t: pieces[i], s: run.s });
            if (i < pieces.length - 1) flush();
          }
        } else {
          cur.push({ t: word, s: run.s });
        }
      } else {
        cur.push({ t: word, s: run.s });
      }
      curW = cur.reduce((acc, r) => acc + displayWidth(r.t), 0);
    }
  }
  flush();
  return lines;
}

function chunkWord(word: string, width: number): string[] {
  const out: string[] = [];
  let cur = "";
  for (const ch of word) {
    if (displayWidth(cur + ch) > width) {
      out.push(cur);
      cur = ch;
    } else {
      cur += ch;
    }
  }
  if (cur) out.push(cur);
  return out.length ? out : [word];
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

/** Render a markdown buffer (GFM-ish) into styled rows. Safe to call on a
 *  partially-streamed buffer: unfinished fenced blocks still render, with a
 *  dim continuation hint. */
export function renderMarkdown(md: string, width: number): Line[] {
  const lines: Line[] = [];
  const rawLines = md.replace(/\r\n/g, "\n").split("\n");

  let i = 0;
  let blankSinceLast = true;
  let lastWasBlock = false;

  const blockGap = () => {
    if (lines.length && !blankSinceLast) lines.push([{ t: "" }]);
  };

  while (i < rawLines.length) {
    const raw = rawLines[i];
    const trimmed = raw.trim();

    // Fenced code block (also catches an unclosed fence mid-stream).
    const fence = /^```(\w*)\s*$/.exec(trimmed);
    if (fence) {
      blockGap();
      const lang = fence[1] || "";
      const codeLines: string[] = [];
      i++;
      let closed = false;
      while (i < rawLines.length) {
        if (/^```\s*$/.test(rawLines[i].trim())) { closed = true; i++; break; }
        codeLines.push(rawLines[i]);
        i++;
      }
      lines.push([{ t: `\u00A0${lang || "code"}`, s: { color: COLORS.faint, bold: true } }]);
      for (const cl of codeLines) {
        const runs = highlight(cl, lang);
        lines.push(wrapRuns(runs, Math.max(4, width - 4)).map((r) => [{ t: "  ", s: {} }, ...r]).flat());
      }
      if (!closed) lines.push([{ t: "  · continuing…", s: { color: COLORS.faint, italic: true } }]);
      lastWasBlock = true;
      blankSinceLast = false;
      continue;
    }

    // Heading.
    const h = /^(#{1,6})\s+(.*)$/.exec(trimmed);
    if (h) {
      blockGap();
      const level = h[1].length;
      const runs = inline(h[2]);
      const weight: Style = { color: COLORS.textBright, bold: true };
      if (level === 1) {
        lines.push([{ t: "", s: {} }, ...runs.map((r) => ({ t: r.t, s: { ...r.s, ...weight } }))]);
        lines.push([{ t: "", s: { color: COLORS.faint } }]);
      } else {
        lines.push([{ t: "", s: {} }, ...runs.map((r) => ({ t: r.t, s: { ...r.s, ...weight } }))]);
      }
      lastWasBlock = true;
      blankSinceLast = false;
      i++;
      continue;
    }

    // Horizontal rule.
    if (/^(-{3,}|\*{3,}|_{3,})$/.test(trimmed)) {
      blockGap();
      lines.push([{ t: "", s: { color: COLORS.faint } }]);
      lines.push([{ t: "─".repeat(Math.max(4, Math.min(width - 4, 40))), s: { color: COLORS.faint } }]);
      lastWasBlock = true;
      blankSinceLast = false;
      i++;
      continue;
    }

    // Blank line → paragraph break.
    if (trimmed === "") {
      if (lines.length && !blankSinceLast) lines.push([{ t: "" }]);
      blankSinceLast = true;
      i++;
      continue;
    }

    // Blockquote.
    if (/^>\s?/.test(trimmed)) {
      const quoted: string[] = [];
      while (i < rawLines.length) {
        const t = rawLines[i].trim();
        if (!t.startsWith(">")) break;
        quoted.push(t.replace(/^>\s?/, ""));
        i++;
      }
      blockGap();
      for (const q of quoted) {
        const runs = inline(q);
        const body = wrapRuns(runs, Math.max(4, width - 4));
        lines.push([{ t: "│ ", s: { color: COLORS.dim } }, ...(body[0] ?? runs)]);
        for (let k = 1; k < body.length; k++) {
          lines.push([{ t: "│ ", s: { color: COLORS.dim } }, ...body[k]]);
        }
      }
      lastWasBlock = true;
      blankSinceLast = false;
      continue;
    }

    // List item.
    const li = /^(\s*)([-*+]|\d+\.)\s+(.*)$/.exec(trimmed);
    if (li) {
      blockGap();
      const bullet = /^\d+\.$/.test(li[2]) ? `${li[2]} ` : "· ";
      const runs = inline(li[3]);
      const body = wrapRuns(runs, Math.max(4, width - 6));
      lines.push([{ t: `  ${bullet}`, s: { color: COLORS.amber } }, ...(body[0] ?? [])]);
      for (let k = 1; k < body.length; k++) {
        lines.push([{ t: "     ", s: {} }, ...body[k]]);
      }
      lastWasBlock = true;
      blankSinceLast = false;
      i++;
      continue;
    }

    // Plain paragraph — group consecutive lines.
    const para: string[] = [];
    while (i < rawLines.length) {
      const t = rawLines[i].trim();
      if (t === "" || /^(#{1,6})\s/.test(t) || /^```/.test(t) || /^>\s?/.test(t) || /^(\s*)([-*+]|\d+\.)\s+/.test(t)) break;
      para.push(t);
      i++;
    }
    blockGap();
    const joined = para.join(" ");
    const runs = inline(joined);
    const wrapped = wrapRuns(runs, Math.max(4, width - 4));
    for (let k = 0; k < wrapped.length; k++) {
      lines.push([{ t: "", s: {} }, ...wrapped[k]]);
    }
    lastWasBlock = true;
    blankSinceLast = false;
  }

  return lines;
}

/** Inline markdown: `code`, **bold**, *italic*, [link](url). */
export function inline(text: string): Run[] {
  const out: Run[] = [];
  let i = 0;
  const buf: string[] = [];
  const flush = () => {
    if (buf.length) {
      out.push({ t: buf.join(""), s: {} });
      buf.length = 0;
    }
  };

  while (i < text.length) {
    const ch = text[i];

    // Inline code span.
    if (ch === "`") {
      let j = i + 1;
      while (j < text.length && text[j] !== "`") j++;
      if (j < text.length) {
        flush();
        out.push({ t: text.slice(i + 1, j), s: { bg: COLORS.codeBg, color: COLORS.amberBright } });
        i = j + 1;
        continue;
      }
    }

    // Bold / italic.
    if ((ch === "*" || ch === "_") && i + 1 < text.length && text[i + 1] === ch) {
      const close = text.indexOf(ch + ch, i + 2);
      if (close > i) {
        flush();
        const inner = text.slice(i + 2, close);
        out.push(...inline(inner).map((r) => ({ t: r.t, s: { ...r.s, bold: true } as Style })));
        i = close + 2;
        continue;
      }
    }
    if (ch === "*" && i + 1 < text.length && text[i + 1] !== " " && text.slice(i + 1).includes("*")) {
      // single-star italic if a matching star exists later
      const close = text.indexOf("*", i + 1);
      if (close > i + 1 && close < text.length - 1) {
        flush();
        const inner = text.slice(i + 1, close);
        out.push(...inline(inner).map((r) => ({ t: r.t, s: { ...r.s, italic: true } as Style })));
        i = close + 1;
        continue;
      }
    }

    // Link [text](url).
    if (ch === "[" ) {
      const close = text.indexOf("]", i + 1);
      if (close > i && text[close + 1] === "(") {
        const paren = text.indexOf(")", close + 1);
        if (paren > close) {
          flush();
          out.push({ t: text.slice(i + 1, close), s: { color: COLORS.blue, underline: true } });
          i = paren + 1;
          continue;
        }
      }
    }

    buf.push(ch);
    i++;
  }
  flush();
  return out;
}

// ---------------------------------------------------------------------------
// Syntax highlighting (lightweight, generic)
// ---------------------------------------------------------------------------

const KEYWORDS: Record<string, string[]> = {
  js: ["import","export","const","let","var","function","return","async","await","class","interface","type","enum","extends","implements","if","else","for","while","switch","case","default","break","continue","new","throw","try","catch","finally","typeof","instanceof","in","of","as","from","require","this","null","undefined","true","false","void","any","unknown","never","string","number","boolean","object","readonly","static","public","private","protected","declare","yield","delete"],
  ts: ["import","export","const","let","var","function","return","async","await","class","interface","type","enum","extends","implements","if","else","for","while","switch","case","default","break","continue","new","throw","try","catch","finally","typeof","instanceof","in","of","as","from","require","this","null","undefined","true","false","void","any","unknown","never","string","number","boolean","object","readonly","static","public","private","protected","declare","yield","delete","satisfies","keyof","namespace","module"],
  python: ["def","return","if","elif","else","for","while","import","from","class","with","as","try","except","finally","lambda","yield","global","nonlocal","pass","break","continue","and","or","not","in","is","None","True","False","self","async","await","raise","assert","del"],
  swift: ["func","let","var","if","else","guard","for","while","switch","case","default","return","class","struct","enum","protocol","extension","import","throws","throw","async","await","actor","final","private","public","internal","fileprivate","static","init","defer","nil","true","false","inout","where","associatedtype","typealias","operator","subscript","override","required","convenience","lazy","weak","unowned"],
  bash: ["if","then","fi","else","elif","for","while","do","done","function","case","esac","echo","export","local","readonly","shift","return","exit","cd","ls","cat","grep","sed","awk","curl","wget","git","npm","pnpm","yarn","bun","python3","node","sudo","chmod","mkdir","touch","rm","cp","mv","source","set","unset"],
  json: ["true","false","null"],
  yaml: ["true","false","null","yes","no"],
};

const COMMENT_PATTERNS: Array<[RegExp, string]> = [
  [/\/\/.*$/gm, "js"],
  [/#.*$/gm, "python"],
  [/\/\*[\s\S]*?\*\//g, "js"],
];

/** Highlight one line of code in a given language. Falls back to dim plain
 *  text for unknown languages. */
export function highlight(code: string, lang: string): Run[] {
  const norm = lang.toLowerCase();
  const keywords = KEYWORDS[norm] ?? (norm.startsWith("js") ? KEYWORDS.js : undefined);
  const isCommentLang = norm === "python" || norm === "bash" || norm === "yaml" || norm === "ruby" || norm === "go";
  const isSlashComment = norm === "js" || norm === "ts" || norm === "swift" || norm === "c" || norm === "cpp" || norm === "go" || norm === "rust" || norm === "java";
  const isBlockComment = norm === "js" || norm === "ts" || norm === "swift" || norm === "c" || norm === "cpp" || norm === "java" || norm === "rust" || norm === "go";
  const isStringLang = norm !== "bash";

  const runs: Run[] = [];
  let i = 0;
  while (i < code.length) {
    const rest = code.slice(i);

    // Block comment.
    if (isBlockComment && rest.startsWith("/*")) {
      const end = rest.indexOf("*/", 2);
      const len = end < 0 ? rest.length : end + 2;
      runs.push({ t: code.slice(i, i + len), s: { color: COLORS.dim, italic: true } });
      i += len;
      continue;
    }
    // Line comment.
    if (isSlashComment && rest.startsWith("//")) {
      runs.push({ t: rest, s: { color: COLORS.dim, italic: true } });
      break;
    }
    if (isCommentLang && rest.startsWith("#")) {
      runs.push({ t: rest, s: { color: COLORS.dim, italic: true } });
      break;
    }
    // String (single or double, no escape handling beyond backslash skip).
    const strStart = isStringLang ? (rest.startsWith('"') ? '"' : rest.startsWith("'") ? "'" : null) : null;
    if (strStart) {
      let j = 1;
      while (j < rest.length) {
        if (rest[j] === "\\") { j += 2; continue; }
        if (rest[j] === strStart) break;
        j++;
      }
      const len = j >= rest.length ? rest.length : j + 1;
      runs.push({ t: code.slice(i, i + len), s: { color: COLORS.green } });
      i += len;
      continue;
    }
    // Number.
    if (/\d/.test(rest[0]) && (i === 0 || !/[A-Za-z0-9_]/.test(code[i - 1]))) {
      const m = /^\d[\d._]*/.exec(rest);
      if (m) {
        runs.push({ t: m[0], s: { color: COLORS.amber } });
        i += m[0].length;
        continue;
      }
    }
    // Keyword / identifier.
    const word = /^[A-Za-z_$][A-Za-z0-9_$]*/.exec(rest);
    if (word) {
      const w = word[0];
      if (keywords?.includes(w)) {
        runs.push({ t: w, s: { color: COLORS.blue } });
      } else if (norm === "json" || norm === "yaml" || norm === "toml") {
        // Keys in config files get the amber treatment.
        const after = rest.slice(w.length);
        if (/^\s*:/.test(after) || /^\s*=/.test(after)) {
          runs.push({ t: w, s: { color: COLORS.amberBright } });
        } else {
          runs.push({ t: w, s: {} });
        }
      } else {
        runs.push({ t: w, s: {} });
      }
      i += w.length;
      continue;
    }
    runs.push({ t: rest[0], s: {} });
    i++;
  }
  return runs;
}

// ---------------------------------------------------------------------------
// Unified diffs
// ---------------------------------------------------------------------------

/** Render a unified diff (git diff / patch output) into styled rows. */
export function renderDiff(diff: string, width: number): Line[] {
  const lines: Line[] = [];
  let oldLine = 0;
  let newLine = 0;
  const gutter = 5;

  for (const raw of diff.replace(/\r\n/g, "\n").split("\n")) {
    if (raw.startsWith("@@")) {
      const m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(raw);
      if (m) {
        oldLine = parseInt(m[1], 10) - 1;
        newLine = parseInt(m[2], 10) - 1;
      }
      lines.push([{ t: `  ${truncate(raw, Math.max(4, width - 2))}`, s: { color: COLORS.diffHunk } }]);
      continue;
    }
    if (raw.startsWith("+++") || raw.startsWith("---") || raw.startsWith("diff --git") || raw.startsWith("index ") || raw.startsWith("new file") || raw.startsWith("deleted file")) {
      lines.push([{ t: `  ${truncate(raw, Math.max(4, width - 2))}`, s: { color: COLORS.dim } }]);
      continue;
    }
    if (raw.startsWith("+")) {
      newLine++;
      lines.push([
        { t: ` ${String(newLine).padStart(gutter - 1, " ")}│`, s: { color: COLORS.faint } },
        { t: `+${raw.slice(1)}`, s: { color: COLORS.green, bg: COLORS.diffAddBg } },
      ]);
      continue;
    }
    if (raw.startsWith("-")) {
      oldLine++;
      lines.push([
        { t: ` ${String(oldLine).padStart(gutter - 1, " ")}│`, s: { color: COLORS.faint } },
        { t: `-${raw.slice(1)}`, s: { color: COLORS.red, bg: COLORS.diffRemoveBg } },
      ]);
      continue;
    }
    // Context line.
    oldLine++;
    newLine++;
    lines.push([
      { t: ` ${String(oldLine).padStart(gutter - 1, " ")} ${String(newLine).padStart(gutter - 1, " ")}│`, s: { color: COLORS.faint } },
      { t: ` ${raw}`, s: { color: COLORS.dim } },
    ]);
  }
  return lines;
}
