/**
 * ui.tsx — AlfredCode's Ink TUI.
 *
 * Three sticky zones, vertical stack:
 *   HEADER     1 line + dim separator — logo · model · cwd · branch · context
 *   STREAM     the append-only conversation, scrollable, auto-pin to bottom
 *   INPUT      the composer + status-when-working + one-line footer hint
 *
 * Every visual detail (palette, glyphs, spacing, dim separators instead of
 * boxes) lives here or in theme.ts. State is plain mutable data in a ref,
 * bumped through a render counter — agent events arrive from child-process
 * callbacks, so they funnel through the controller instead of React setState.
 *
 * Ink 5 constraint: styling lives on <Text>, not <Box>. Full-line effects
 * (the plan-mode tint) are done by appending a padded background run to each
 * row rather than a Box backgroundColor.
 */

import React, { useEffect, useMemo, useReducer, useRef } from "react";
import { Box, Text, useApp, useInput, useStdin, useStdout } from "ink";
import type { AgentClient, AgentEvent, PermissionOption } from "./agent.js";
import type { FileEntry } from "./commands.js";
import { buildPalette, filterFiles, scanFiles } from "./commands.js";
import { renderDiff, renderMarkdown, type Line } from "./renderer.js";
import { COLORS, GLYPHS, displayWidth, padRight, separatorLine, truncate, truncatePath } from "./theme.js";

// ---------------------------------------------------------------------------
// Model
// ---------------------------------------------------------------------------

type Block =
  | { id: number; kind: "user"; text: string }
  | { id: number; kind: "assistant"; text: string }
  | { id: number; kind: "thought"; text: string; start: number; end?: number; collapsed: boolean }
  | { id: number; kind: "tool"; toolId: string; title: string; toolKind: string; status: "running" | "done" | "failed"; result: string; collapsed: boolean }
  | { id: number; kind: "diff"; text: string; collapsed: boolean }
  | { id: number; kind: "system"; text: string };

type Overlay = "none" | "command" | "files";

type CollapsibleBlock = Extract<Block, { kind: "thought" } | { kind: "tool" } | { kind: "diff" }>;

interface PermissionState {
  title: string;
  options: PermissionOption[];
  respond: (optionId: string | null) => void;
}

interface Model {
  blocks: Block[];
  nextBlockID: number;
  /** Content epoch — bumped on every stream mutation so the row cache knows
   *  to rebuild even though block arrays are mutated in place. */
  epoch: number;

  status: "idle" | "working";
  turnStart: number;
  toolCount: number;

  input: string;
  cursor: number;

  scrollOffset: number;      // rows scrolled up from the bottom; 0 = pinned
  newWhileLocked: number;    // rows added while unpinned

  overlay: Overlay;
  overlayQuery: string;
  overlayIndex: number;
  atIndex: number;           // where the '@' token started (files overlay)

  planMode: boolean;
  permission: PermissionState | null;
  panel: "none" | "help" | "info";
  focusBlock: number;        // ctrl+r cursor over collapsible blocks
  tick: number;              // spinner / elapsed clock
}

const initialModel = (): Model => ({
  blocks: [],
  nextBlockID: 1,
  epoch: 0,
  status: "idle",
  turnStart: 0,
  toolCount: 0,
  input: "",
  cursor: 0,
  scrollOffset: 0,
  newWhileLocked: 0,
  overlay: "none",
  overlayQuery: "",
  overlayIndex: 0,
  atIndex: 0,
  planMode: false,
  permission: null,
  panel: "none",
  focusBlock: -1,
  tick: 0,
});

// ---------------------------------------------------------------------------
// Formatting helpers
// ---------------------------------------------------------------------------

function fmtDuration(seconds: number): string {
  if (seconds < 60) return `${seconds.toFixed(seconds < 10 ? 1 : 0)}s`;
  const m = Math.floor(seconds / 60);
  const s = Math.round(seconds % 60);
  return `${m}m ${String(s).padStart(2, "0")}s`;
}

function fmtTokens(n: number): string {
  if (n < 1000) return `${n}`;
  if (n < 1_000_000) return `${(n / 1000).toFixed(n < 10_000 ? 1 : 0)}k`;
  return `${(n / 1_000_000).toFixed(1)}m`;
}

/** Cost label: the agent's reported cost when it sends one, else a rough
 *  blended estimate (~$0.50 per million tokens). */
function estCost(used: number, realCost = 0): string {
  if (realCost > 0) return `$${realCost.toFixed(2)}`;
  const cents = (used / 1_000_000) * 0.5 * 100;
  if (cents < 0.01) return "~$0.00";
  return `~$${(cents / 100).toFixed(2)}`;
}

// ---------------------------------------------------------------------------
// Input sanitizing
// ---------------------------------------------------------------------------

/** Strip control characters that would corrupt Ink's frame if rendered raw —
 *  a stray \r inside a rendered Text was verified live to kill the whole TUI.
 *  Keeps \t and \n: pasted code keeps its indentation, and multi-line input
 *  keeps working. C0 controls 0-8 and 11-31 plus DEL go; \t(9), \n(10) stay.
 */
function stripControl(s: string): string {
  return s.replace(/[\x00-\x08\x0b-\x1f\x7f]/g, "");
}

// ---------------------------------------------------------------------------
// Row building
// ---------------------------------------------------------------------------

interface Row {
  blockID: number;
  runs: Line;
}

function buildRows(m: Model, width: number): Row[] {
  const rows: Row[] = [];
  const pushRuns = (blockID: number, runs: Line) => {
    rows.push({ blockID, runs: [{ t: "  " }, ...runs] });
  };

  for (const b of m.blocks) {
    switch (b.kind) {
      case "user": {
        pushRuns(b.id, [{ t: `${GLYPHS.prompt} `, s: { color: COLORS.amber, bold: true } }]);
        const lines = b.text.split("\n");
        for (let i = 0; i < lines.length; i++) {
          pushRuns(b.id, [
            { t: i === 0 ? "" : "    ", s: {} },
            { t: lines[i], s: { color: COLORS.textBright, bold: true } },
          ]);
        }
        break;
      }
      case "assistant": {
        const md = renderMarkdown(b.text, Math.max(4, width - 4));
        for (const line of md) pushRuns(b.id, line);
        if (m.status === "working" && b.id === m.blocks[m.blocks.length - 1]?.id) {
          pushRuns(b.id, [{ t: "▎", s: { color: COLORS.amber } }]);
        }
        break;
      }
      case "thought": {
        const elapsed = thoughtElapsed(b, m);
        if (b.collapsed) {
          pushRuns(b.id, [
            { t: `${GLYPHS.thought} `, s: { color: COLORS.dim } },
            { t: `Thinking… (${fmtDuration(elapsed)})`, s: { color: COLORS.dim, italic: true } },
            { t: "  [ctrl+r]", s: { color: COLORS.faint } },
          ]);
        } else {
          pushRuns(b.id, [
            { t: `${GLYPHS.thought} `, s: { color: COLORS.dim } },
            { t: `Thinking… (${fmtDuration(elapsed)})`, s: { color: COLORS.dim, italic: true } },
          ]);
          const md = renderMarkdown(b.text, Math.max(4, width - 8));
          for (const line of md) pushRuns(b.id, [{ t: "    ", s: {} }, ...line]);
        }
        break;
      }
      case "tool": {
        const glyph = b.status === "running" ? GLYPHS.running : b.status === "failed" ? "✕" : GLYPHS.done;
        const color = b.status === "failed" ? COLORS.red : b.status === "done" ? COLORS.green : COLORS.dim;
        if (b.collapsed) {
          pushRuns(b.id, [
            { t: `${GLYPHS.tool} `, s: { color: COLORS.dim } },
            { t: toolLabel(b), s: { color: COLORS.textBright, bold: true } },
            { t: "  (collapsed)  [ctrl+r]", s: { color: COLORS.faint } },
          ]);
        } else {
          pushRuns(b.id, [
            { t: `${GLYPHS.tool} `, s: { color } },
            { t: `${glyph} `, s: { color } },
            { t: toolLabel(b), s: { color: COLORS.textBright, bold: true } },
            { t: argsSuffix(b), s: { color: COLORS.dim } },
          ]);
          if (b.status === "running") {
            pushRuns(b.id, [{ t: `  ${GLYPHS.result} Running…`, s: { color: COLORS.dim, italic: true } }]);
          } else if (b.result) {
            const resultLines = b.result.split("\n").slice(0, 4);
            for (const rl of resultLines) {
              pushRuns(b.id, [
                { t: `  ${GLYPHS.result} `, s: { color: COLORS.dim } },
                { t: truncate(rl, Math.max(4, width - 10)), s: { color: COLORS.dim } },
              ]);
            }
            if (b.result.split("\n").length > 4) {
              pushRuns(b.id, [{ t: `  ${GLYPHS.result} …`, s: { color: COLORS.faint } }]);
            }
          }
        }
        break;
      }
      case "diff": {
        if (!b.collapsed) {
          for (const line of renderDiff(b.text, Math.max(4, width - 4))) pushRuns(b.id, line);
        } else {
          pushRuns(b.id, [{ t: "  (diff collapsed)  [ctrl+r]", s: { color: COLORS.faint } }]);
        }
        break;
      }
      case "system": {
        pushRuns(b.id, [{ t: `${GLYPHS.result} ${b.text}`, s: { color: COLORS.faint, italic: true } }]);
        break;
      }
    }
  }
  return rows;
}

function thoughtElapsed(b: Extract<Block, { kind: "thought" }>, m: Model): number {
  const live = m.status === "working" && m.blocks[m.blocks.length - 1]?.id === b.id;
  const end = live ? Date.now() : (b.end ?? b.start);
  return (end - b.start) / 1000;
}

/** Freeze the trailing thought block's timer when a different kind of event
 *  arrives (text, tool call, turn end). */
function sealThought(m: Model) {
  const tail = m.blocks[m.blocks.length - 1];
  if (tail?.kind === "thought" && tail.end === undefined) {
    tail.end = Date.now();
  }
}

function lastAssistant(m: Model): Block | undefined {
  for (let i = m.blocks.length - 1; i >= 0; i--) {
    if (m.blocks[i].kind === "assistant") return m.blocks[i];
  }
  return undefined;
}

function toolLabel(b: Extract<Block, { kind: "tool" }>): string {
  const name = b.toolKind || b.title.split(" ")[0] || "Tool";
  return truncate(name, 42);
}

function argsSuffix(b: Extract<Block, { kind: "tool" }>): string {
  const t = b.title.trim();
  if (!t || t === "Working…") return "";
  const kind = b.toolKind.toLowerCase();
  if (kind && t.toLowerCase().startsWith(kind)) {
    const rest = t.slice(kind.length).trim();
    if (rest) return `(${truncate(rest, 48)})`;
  }
  if (!kind || kind === t.toLowerCase()) return `(${truncate(t, 48)})`;
  return "";
}

// ---------------------------------------------------------------------------
// App
// ---------------------------------------------------------------------------

interface UIProps {
  cwd: string;
  branch: string;
  agent: () => AgentClient;
  agentName: string;
  initialPrompt?: string;
}

// The status bar needs the live agent; set once at boot.
let liveAgent: (() => AgentClient) | null = null;

export default function App({ cwd, branch, agent, agentName, initialPrompt }: UIProps) {
  const { exit } = useApp();
  const { stdout } = useStdout();
  const { stdin } = useStdin();
  const [, force] = useReducer((x: number) => x + 1, 0);
  const m = useRef<Model>(initialModel()).current;
  const fileCache = useRef<FileEntry[] | null>(null);
  // Latest geometry for long-lived listeners (the mouse hook binds once).
  const geom = useRef({ total: 0, height: 20 });

  const cols = stdout.columns || 100;
  const rows = stdout.rows || 30;

  const bump = () => force();

  // --- content mutation ------------------------------------------------------

  const pushBlock = (b: Block) => {
    m.blocks.push(b);
    m.epoch += 1;
    if (m.scrollOffset !== 0) m.newWhileLocked += 1;
    bump();
  };

  // --- geometry ---------------------------------------------------------------

  const composerLines = m.status === "working" ? 1 : Math.min(6, Math.max(1, m.input.split("\n").length));
  const permissionLines = m.permission ? 3 : 0;
  const conversationHeight = Math.max(4, rows - 3 - (composerLines - 1) - permissionLines);

  const allRows = useMemo(
    () => buildRows(m, cols),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [m.epoch, m.tick, m.status, cols],
  );
  const total = allRows.length;
  const offset = Math.min(m.scrollOffset, Math.max(0, total - conversationHeight));
  const start = Math.max(0, total - conversationHeight - offset);
  const viewRows = allRows.slice(start, start + conversationHeight);
  const pinned = m.scrollOffset === 0;
  geom.current.total = total;
  geom.current.height = conversationHeight;

  // --- scrolling ---------------------------------------------------------------

  const scrollBy = (n: number) => {
    const { total: t, height: h } = geom.current;
    if (m.scrollOffset === 0 && n > 0) m.newWhileLocked = 0;
    m.scrollOffset = Math.max(0, Math.min(m.scrollOffset + n, Math.max(0, t - h)));
    bump();
  };

  const scrollToTop = () => {
    const { total: t, height: h } = geom.current;
    m.scrollOffset = Math.max(0, t - h);
    m.newWhileLocked = 0;
    bump();
  };

  const scrollToBottom = () => {
    m.scrollOffset = 0;
    m.newWhileLocked = 0;
    bump();
  };

  // --- collapsible blocks --------------------------------------------------------

  const isCollapsible = (b: Block): b is CollapsibleBlock =>
    b.kind === "thought" || b.kind === "tool" || b.kind === "diff";

  const cycleCollapse = () => {
    const collapsible = m.blocks
      .map((b, i) => ({ b, i }))
      .filter((x): x is { b: CollapsibleBlock; i: number } => isCollapsible(x.b));
    if (collapsible.length === 0) return;
    const startIdx = m.focusBlock >= 0 ? m.focusBlock + 1 : 0;
    const next = collapsible.find((c) => c.i >= startIdx) ?? collapsible[0];
    next.b.collapsed = !next.b.collapsed;
    m.focusBlock = next.i;
    bump();
  };

  // --- overlays ------------------------------------------------------------------

  const closeOverlay = () => {
    m.overlay = "none";
    m.overlayQuery = "";
    m.overlayIndex = 0;
    bump();
  };

  const lineEnd = () => {
    let i = m.cursor;
    while (i < m.input.length && m.input[i] !== "\n") i++;
    return i;
  };

  const selectOverlayItem = () => {
    if (m.overlay === "command") {
      const q = m.overlayQuery;
      const entries = palette.filter((c) => c.command.includes(q.split(" ")[0]));
      const entry = entries[m.overlayIndex];
      if (entry) {
        const rest = q.slice(entry.command.length).trim();
        closeOverlay();
        entry.run(rest);
      }
    } else if (m.overlay === "files") {
      const files = filterFiles(cwd, m.overlayQuery, fileCache.current);
      const picked = files[m.overlayIndex];
      if (picked) {
        const before = m.input.slice(0, m.atIndex);
        const after = m.input.slice(lineEnd());
        m.input = before + picked.path + " " + after;
        m.cursor = m.input.length - after.length;
        closeOverlay();
      }
    }
  };

  const palette = useMemo(() => buildPalette({
    clear: () => {
      const a = agent();
      a.stop();
      void a.start().then(() => {
        m.blocks = [];
        m.nextBlockID = 1;
        pushBlock({ id: m.nextBlockID++, kind: "system", text: "Fresh session started." });
        bump();
      });
    },
    togglePlan: () => {
      m.planMode = !m.planMode;
      pushBlock({ id: m.nextBlockID++, kind: "system", text: m.planMode ? "Plan mode ON — read-only." : "Plan mode OFF." });
    },
    showCost: () => { m.panel = m.panel === "info" ? "none" : "info"; bump(); },
    showHelp: () => { m.panel = m.panel === "help" ? "none" : "help"; bump(); },
    compact: () => {
      const transcript = m.blocks
        .filter((b) => b.kind === "user" || b.kind === "assistant")
        .map((b) => (b.kind === "user" ? "USER: " : "ASSISTANT: ") + (b.text.length > 600 ? b.text.slice(0, 600) + "…" : b.text))
        .join("\n\n")
        .slice(-12_000);
      pushBlock({ id: m.nextBlockID++, kind: "user", text: "/compact" });
      pushBlock({ id: m.nextBlockID++, kind: "assistant", text: "" });
      m.status = "working";
      m.turnStart = Date.now();
      bump();
      void agent().prompt(
        "Compact the conversation below into a concise handoff summary a fresh session could continue from. " +
        "Keep the important decisions, file names and open questions.\n\n---\n" + transcript,
        m.planMode,
      );
    },
    review: () => {
      send("Review the changes made in this session and the current project state. Look for bugs, edge cases, missing tests and anything that would not survive a code review. Be specific and concise.");
    },
    quit: () => {
      agent().stop();
      exit();
    },
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }), []);

  // --- turns ------------------------------------------------------------------

  const send = (text: string) => {
    const t = text.trim();
    if (!t || m.status === "working") return;
    pushBlock({ id: m.nextBlockID++, kind: "user", text: t });
    pushBlock({ id: m.nextBlockID++, kind: "assistant", text: "" });
    m.status = "working";
    m.turnStart = Date.now();
    m.toolCount = 0;
    m.scrollOffset = 0;
    m.newWhileLocked = 0;
    bump();
    void agent().prompt(t, m.planMode);
  };

  // --- agent events -----------------------------------------------------------

  useEffect(() => {
    const a = agent();
    liveAgent = agent;
    a.onEvent = handleAgentEvent;
    void (async () => {
      try {
        await a.start();
        pushBlock({
          id: m.nextBlockID++,
          kind: "system",
          text: `Connected to ${a.info?.serverName ?? agentName}${a.info?.model ? ` (${a.info.model})` : ""} in ${cwd}`,
        });
        if (initialPrompt) send(initialPrompt);
      } catch (err) {
        pushBlock({ id: m.nextBlockID++, kind: "system", text: `Failed to start agent: ${err instanceof Error ? err.message : String(err)}` });
      }
    })();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const handleAgentEvent = (ev: AgentEvent) => {
    sealThought(m);
    m.epoch += 1;
    switch (ev.kind) {
      case "text": {
        const last = lastAssistant(m);
        if (last && last.kind === "assistant") last.text += ev.text;
        else pushBlock({ id: m.nextBlockID++, kind: "assistant", text: ev.text });
        bump();
        break;
      }
      case "thought": {
        const tail = m.blocks[m.blocks.length - 1];
        if (tail?.kind === "thought") tail.text += ev.text;
        else pushBlock({ id: m.nextBlockID++, kind: "thought", text: ev.text, start: Date.now(), collapsed: false });
        bump();
        break;
      }
      case "toolStart": {
        m.toolCount += 1;
        pushBlock({ id: m.nextBlockID++, kind: "tool", toolId: ev.id, title: ev.title, toolKind: ev.toolKind, status: "running", result: "", collapsed: false });
        break;
      }
      case "toolUpdate": {
        const tool = [...m.blocks].reverse().find((b) => b.kind === "tool" && b.toolId === ev.id);
        if (tool?.kind === "tool") {
          if (ev.title && ev.title !== "Working…") tool.title = ev.title;
          if (ev.status === "completed") tool.status = "done";
          else if (ev.status === "failed" || ev.status === "error") tool.status = "failed";
        }
        bump();
        break;
      }
      case "finished": {
        m.status = "idle";
        for (const b of m.blocks) if (b.kind === "tool" && b.status === "running") b.status = "done";
        const duration = (Date.now() - m.turnStart) / 1000;
        const lc = (liveAgent as () => AgentClient)().lastUsage;
        pushBlock({ id: m.nextBlockID++, kind: "system", text: `Cost: ${estCost(lc.used, lc.cost)} · Duration: ${fmtDuration(duration)}` });
        break;
      }
      case "failed": {
        m.status = "idle";
        for (const b of m.blocks) if (b.kind === "tool" && b.status === "running") b.status = "failed";
        pushBlock({ id: m.nextBlockID++, kind: "system", text: ev.message });
        break;
      }
      case "log": {
        pushBlock({ id: m.nextBlockID++, kind: "system", text: `agent: ${ev.line}` });
        break;
      }
      case "permission": {
        m.permission = {
          title: ev.title,
          options: ev.options,
          respond: (optionId) => {
            ev.respond(optionId);
            m.permission = null;
            pushBlock({ id: m.nextBlockID++, kind: "system", text: optionId ? `Allowed: ${ev.title}` : `Denied: ${ev.title}` });
            bump();
          },
        };
        bump();
        break;
      }
    }
  };

  // --- clock ------------------------------------------------------------------

  useEffect(() => {
    const id = setInterval(() => {
      const needsTick = m.status === "working" || m.blocks.some((b) => b.kind === "thought");
      if (needsTick) {
        m.tick += 1;
        bump();
      }
    }, 80);
    return () => clearInterval(id);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // --- raw stdin: mouse + Home/End (Ink's Key type has neither) -----------------

  useEffect(() => {
    const home = () => {
      const i = m.cursor;
      let j = i;
      while (j > 0 && m.input[j - 1] !== "\n") j--;
      m.cursor = j;
      bump();
    };
    const end = () => {
      const i = m.cursor;
      let j = i;
      while (j < m.input.length && m.input[j] !== "\n") j++;
      m.cursor = j;
      bump();
    };
    const clickAt = (y: number) => {
      const { height } = geom.current;
      const localY = y - 1 - 2; // header + separator
      if (localY < 0 || localY >= height) return;
      const { total: t } = geom.current;
      const off = Math.min(m.scrollOffset, Math.max(0, t - height));
      const rowIdx = Math.max(0, t - height - off) + localY;
      const row = allRowsCurrent[rowIdx];
      if (!row) return;
      const target = m.blocks.find((b) => b.id === row.blockID);
      if (target && isCollapsible(target)) {
        target.collapsed = !target.collapsed;
        m.focusBlock = m.blocks.indexOf(target);
        bump();
      }
    };

    try {
      process.stdout.write("\x1b[?1000h\x1b[?1006h\x1b[?1015h");
    } catch { /* ignore */ }
    const onData = (chunk: Buffer) => {
      const s = chunk.toString("utf8");
      // SGR mouse: ESC [ < Cb ; Cx ; Cy M/m
      const re = /\x1b\[<(\d+);(\d+);(\d+)([Mm])/g;
      let match: RegExpExecArray | null;
      while ((match = re.exec(s)) !== null) {
        const button = parseInt(match[1], 10);
        const y = parseInt(match[3], 10);
        if (button === 64) scrollBy(-3);
        else if (button === 65) scrollBy(3);
        else if (button === 0) clickAt(y);
      }
      if (s.includes("\x1b[H") || s.includes("\x1b[1~") || s.includes("\x1b[7~")) home();
      if (s.includes("\x1b[F") || s.includes("\x1b[4~") || s.includes("\x1b[8~")) end();
    };
    stdin?.on("data", onData);
    return () => {
      stdin?.off("data", onData);
      try {
        process.stdout.write("\x1b[?1000l\x1b[?1006l\x1b[?1015l");
      } catch { /* ignore */ }
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // The mouse click handler needs the latest rows; kept on a ref the listener
  // can read without re-subscribing.
  const allRowsCurrent = allRows;

  // --- input editing ---------------------------------------------------------------

  const insert = (s: string) => {
    // Defense in depth: never let a control char into the composer, where it
    // would be rendered raw to the terminal. Keeps \n (multi-line input) and
    // \t (pasted-code indentation); strips \r and the rest.
    const clean = stripControl(s);
    m.input = m.input.slice(0, m.cursor) + clean + m.input.slice(m.cursor);
    m.cursor += clean.length;
    bump();
  };

  const removeBefore = () => {
    if (m.cursor <= 0) return;
    m.input = m.input.slice(0, m.cursor - 1) + m.input.slice(m.cursor);
    m.cursor -= 1;
    bump();
  };

  const removeAfter = () => {
    if (m.cursor >= m.input.length) return;
    m.input = m.input.slice(0, m.cursor) + m.input.slice(m.cursor + 1);
    bump();
  };

  const lineStart = () => {
    let i = m.cursor;
    while (i > 0 && m.input[i - 1] !== "\n") i--;
    return i;
  };

  const moveUp = () => {
    const start = lineStart();
    if (start === 0) return;
    let prevStart = start - 1;
    while (prevStart > 0 && m.input[prevStart - 1] !== "\n") prevStart--;
    const col = Math.min(m.cursor - start, start - prevStart - 1);
    m.cursor = prevStart + col;
    bump();
  };

  const moveDown = () => {
    const end = lineEnd();
    if (end >= m.input.length) return;
    let nextEnd = end + 1;
    while (nextEnd < m.input.length && m.input[nextEnd] !== "\n") nextEnd++;
    const col = Math.min(m.cursor - lineStart(), nextEnd - end - 1);
    m.cursor = end + 1 + col;
    bump();
  };

  // --- keys -------------------------------------------------------------------------

  useInput((input, key) => {
    // Permission prompt owns the keyboard.
    if (m.permission) {
      const allow = m.permission.options.find((o) => /allow/i.test(o.kind) || /allow/i.test(o.optionId)) ?? m.permission.options[0];
      if (input === "y" || input === "a" || input === "s" || input === "d") {
        if (allow) m.permission.respond(allow.optionId);
      } else if (input === "n" || key.escape) {
        m.permission.respond(null);
      }
      return;
    }

    // Panels: any key closes.
    if (m.panel !== "none") {
      m.panel = "none";
      bump();
      return;
    }

    // Overlays.
    if (m.overlay !== "none") {
      if (key.escape) { closeOverlay(); return; }
      if (key.upArrow) { m.overlayIndex = Math.max(0, m.overlayIndex - 1); bump(); return; }
      if (key.downArrow || key.tab) {
        const count = m.overlay === "command"
          ? palette.filter((c) => c.command.includes(m.overlayQuery.split(" ")[0])).length
          : filterFiles(cwd, m.overlayQuery, fileCache.current).length;
        m.overlayIndex = Math.min(m.overlayIndex + 1, Math.max(0, count - 1));
        if (key.tab && m.overlayIndex >= count) m.overlayIndex = 0;
        bump();
        return;
      }
      if (key.return) { selectOverlayItem(); return; }
      if (key.backspace) { m.overlayQuery = m.overlayQuery.slice(0, -1); m.overlayIndex = 0; bump(); return; }
      if (input && !key.ctrl) {
        // A pasted query must never reach the render: strip control chars and
        // flatten newlines so the overlay stays single-line.
        m.overlayQuery += stripControl(input).replace(/\n/g, " ");
        m.overlayIndex = 0;
        bump();
      }
      return;
    }

    // Global keys.
    if (key.escape) {
      if (m.status === "working") { agent().cancel(); return; }
      if (m.input) { m.input = ""; m.cursor = 0; bump(); }
      return;
    }
    if (key.ctrl && input === "c") { agent().stop(); exit(); return; }
    if (key.ctrl && input === "r") { cycleCollapse(); return; }
    if (key.shift && key.tab) {
      m.planMode = !m.planMode;
      pushBlock({ id: m.nextBlockID++, kind: "system", text: m.planMode ? "Plan mode ON — read-only." : "Plan mode OFF." });
      return;
    }
    if (key.pageUp) { scrollBy(-conversationHeight); return; }
    if (key.pageDown) { scrollBy(conversationHeight); return; }
    if (input === "G") { scrollToBottom(); return; }
    if (key.ctrl && input === "g") { scrollToTop(); return; }

    // Palette + finder triggers.
    if (input === "/" && m.input === "") { m.overlay = "command"; m.overlayQuery = "/"; m.overlayIndex = 0; bump(); return; }
    if (input === "@" && (m.input === "" || m.input[m.cursor - 1] === " " || m.input[m.cursor - 1] === "\n")) {
      if (fileCache.current === null) fileCache.current = scanFiles(cwd);
      m.overlay = "files"; m.overlayQuery = ""; m.overlayIndex = 0; m.atIndex = m.cursor; bump(); return;
    }

    // Multi-char paste: Ink's parseKeypress only names single characters, so a
    // pasted chunk arrives as ONE event with no key flags. A trailing newline
    // means "paste, then Enter" — send the text (only when idle; while a turn
    // runs, drop the newline and insert instead so nothing is lost). Normalize
    // \r\n/\r to \n and strip stray control chars, because a raw \r rendered
    // inside the composer corrupts Ink's frame output and kills the app
    // (verified live).
    if (input.length > 1) {
      const normalized = stripControl(input.replace(/\r\n|\r/g, "\n"));
      const trailingNewline = normalized.endsWith("\n");
      const body = trailingNewline ? normalized.replace(/\n+$/, "") : normalized;
      if (!body) return; // a newline-only paste has nothing to say
      if (trailingNewline && m.status === "idle") {
        m.input = "";
        m.cursor = 0;
        send(body);
      } else {
        insert(body);
      }
      return;
    }

    // Vim-ish scroll when the composer is empty.
    if (m.input === "") {
      if (input === "j") { scrollBy(1); return; }
      if (input === "k") { scrollBy(-1); return; }
      if (input === "q") { agent().stop(); exit(); return; }
    }

    // Composer editing.
    if (key.return) {
      if (key.shift || key.ctrl) insert("\n");
      else { const t = m.input; m.input = ""; m.cursor = 0; send(t); }
      return;
    }
    if (key.backspace) { removeBefore(); return; }
    if (key.delete) { removeAfter(); return; }
    if (key.leftArrow) { m.cursor = Math.max(0, m.cursor - 1); bump(); return; }
    if (key.rightArrow) { m.cursor = Math.min(m.input.length, m.cursor + 1); bump(); return; }
    if (key.upArrow) { moveUp(); return; }
    if (key.downArrow) { moveDown(); return; }
    if (input && !key.ctrl) insert(input);
  });

  // --- render ----------------------------------------------------------------------

  const inputLines = m.input.split("\n");
  const cursorLineIdx = computeCursorLine(inputLines, m.cursor);
  const inputBase = Math.max(0, cursorLineIdx - 5);
  const visibleInputLines = inputLines.slice(inputBase, cursorLineIdx + 1);
  const fillBg = m.planMode ? COLORS.planBg : undefined;

  return (
    <Box flexDirection="column" height="100%">
      <Header m={m} cwd={cwd} branch={branch} cols={cols} agent={agent} />
      <Text color={COLORS.faint}>{separatorLine(cols)}</Text>

      {/* Middle zone: conversation stream (or a modal overlay/panel). */}
      <Box flexDirection="column" flexGrow={1} overflow="hidden">
        {m.panel === "help" ? (
          <HelpPanel agent={agent} cwd={cwd} branch={branch} />
        ) : m.panel === "info" ? (
          <InfoPanel m={m} agent={agent} />
        ) : m.overlay === "command" ? (
          <CommandOverlay m={m} palette={palette} cols={cols} />
        ) : m.overlay === "files" ? (
          <FilesOverlay m={m} cwd={cwd} cache={fileCache.current} cols={cols} />
        ) : (
          <>
            {viewRows.map((row, i) => (
              <RowView key={`${row.blockID}:${i}`} runs={row.runs} cols={cols} fillBg={fillBg} />
            ))}
            {!pinned && m.newWhileLocked > 0 && (
              <Text color={COLORS.dim} bold>{`  ↓ ${m.newWhileLocked} new ${m.newWhileLocked === 1 ? "message" : "messages"} (G to jump)`}</Text>
            )}
          </>
        )}
      </Box>

      {/* Permission block. */}
      {m.permission && (
        <Box flexDirection="column">
          <Text color={COLORS.faint}>{separatorLine(cols)}</Text>
          <Box flexDirection="row" marginTop={1}>
            <Text dimColor>  ⚠ </Text>
            <Text color={COLORS.yellow}>{m.permission.title}</Text>
          </Box>
          <Box flexDirection="row" marginTop={1}>
            <Text dimColor>  Options: </Text>
            <Text color={COLORS.amber}>[Y] allow </Text>
            <Text dimColor>· </Text>
            <Text color={COLORS.red}>[N] deny </Text>
            <Text dimColor>· </Text>
            <Text color={COLORS.amber}>[A] once </Text>
            <Text dimColor>· </Text>
            <Text color={COLORS.amber}>[S] session </Text>
            <Text dimColor>· </Text>
            <Text color={COLORS.amber}>[D] always</Text>
          </Box>
        </Box>
      )}

      {/* Bottom zone: status bar or composer + footer hint. */}
      {m.status === "working" ? (
        <StatusBar m={m} />
      ) : (
        <Composer m={m} visibleLines={visibleInputLines} inputBase={inputBase} cursorLine={cursorLineIdx} inputLines={inputLines} />
      )}
      <Footer m={m} />
    </Box>
  );
}

function computeCursorLine(lines: string[], cursor: number): number {
  let pos = 0;
  for (let i = 0; i < lines.length; i++) {
    pos += lines[i].length;
    if (cursor <= pos) return i;
    pos += 1; // the \n
  }
  return Math.max(0, lines.length - 1);
}

// ---------------------------------------------------------------------------
// Pieces
// ---------------------------------------------------------------------------

function RowView({ runs, cols, fillBg }: { runs: Line; cols: number; fillBg?: string }) {
  const width = runs.reduce((acc, r) => acc + displayWidth(r.t), 0);
  const fill = fillBg && width < cols ? " ".repeat(cols - width) : "";
  return (
    <Text>
      {runs.map((r, i) => (
        <Text
          key={i}
          color={r.s?.color}
          backgroundColor={r.s?.bg}
          bold={r.s?.bold}
          dimColor={r.s?.dim}
          italic={r.s?.italic}
          underline={r.s?.underline}
        >
          {r.t}
        </Text>
      ))}
      {fill && <Text backgroundColor={fillBg}>{fill}</Text>}
    </Text>
  );
}

function Header(props: { m: Model; cwd: string; branch: string; cols: number; agent: () => AgentClient }) {
  const { m, cwd, branch, cols, agent } = props;
  const a = agent();
  const model = a.info?.model || "";
  const cwdW = Math.max(12, cols - 46 - (model ? 22 : 0) - (branch ? 14 : 0) - (m.planMode ? 14 : 0));
  const right = `${fmtTokens(a.lastUsage.used)}/${fmtTokens(a.lastUsage.size || 0)} · ${estCost(a.lastUsage.used, a.lastUsage.cost)}`;

  return (
    <Box flexDirection="row" justifyContent="space-between">
      <Box>
        {m.planMode && <Text color={COLORS.blue} bold>PLAN </Text>}
        <Text color={COLORS.amber} bold>ALFRED CODE</Text>
        {model && <Text dimColor>{` ${GLYPHS.bullet} ${truncate(model, 26)}`}</Text>}
        <Text dimColor>{` ${GLYPHS.bullet} ${truncatePath(cwd, cwdW)}`}</Text>
        {branch && <Text color={COLORS.green}>{` ${GLYPHS.bullet} ${branch}`}</Text>}
      </Box>
      <Text dimColor>{right}</Text>
    </Box>
  );
}

function StatusBar({ m }: { m: Model }) {
  const spinner = GLYPHS.spinner[Math.floor(m.tick / 3) % GLYPHS.spinner.length];
  const elapsed = (Date.now() - m.turnStart) / 1000;
  const used = (liveAgent as (() => AgentClient))().lastUsage.used;
  return (
    <Box flexDirection="row" marginTop={1}>
      <Text color={COLORS.amber}>{`  ${GLYPHS.thought} Cooking…`}</Text>
      <Text color={COLORS.dim}>{` ${spinner}`}</Text>
      <Text dimColor>{` (esc to interrupt · ${fmtDuration(elapsed)} · ${m.toolCount} tool ${m.toolCount === 1 ? "call" : "calls"} · ${fmtTokens(used)} tokens)`}</Text>
    </Box>
  );
}

function Composer(props: { m: Model; visibleLines: string[]; inputBase: number; cursorLine: number; inputLines: string[] }) {
  const { m, visibleLines, inputBase, cursorLine, inputLines } = props;
  return (
    <Box flexDirection="column" marginTop={1}>
      {visibleLines.map((line, vi) => {
        const li = inputBase + vi;
        const realLine = inputLines[li] ?? "";
        const isActive = li === cursorLine;
        const col = isActive ? m.cursor - prefixLen(inputLines, li) : realLine.length;
        const before = realLine.slice(0, Math.max(0, col));
        const at = realLine[col];
        const after = realLine.slice(col + (at ? 1 : 0));
        return (
          <Box key={li} flexDirection="row">
            <Text color={COLORS.amber} bold>{`  ${GLYPHS.prompt} `}</Text>
            <Text color={COLORS.text}>
              {before}
              {at ? <Text inverse>{at}</Text> : isActive ? <Text inverse> </Text> : null}
              {after}
            </Text>
          </Box>
        );
      })}
    </Box>
  );
}

function prefixLen(lines: string[], i: number): number {
  let n = 0;
  for (let k = 0; k < i; k++) n += lines[k].length + 1;
  return n;
}

function Footer({ m }: { m: Model }) {
  const hint = m.planMode
    ? "PLAN MODE ON — read-only · shift+tab to exit · esc interrupt · enter send"
    : "? help · / commands · @ mention file · shift+tab plan mode · esc interrupt · enter send";
  return <Text dimColor>{`  ${hint}`}</Text>;
}

function CommandOverlay(props: { m: Model; palette: ReturnType<typeof buildPalette>; cols: number }) {
  const { m, palette, cols } = props;
  const q = m.overlayQuery.split(" ")[0];
  const entries = palette.filter((c) => c.command.includes(q) || c.description.toLowerCase().includes(m.overlayQuery.toLowerCase()));
  return (
    <Box flexDirection="column" marginLeft={2} marginTop={1}>
      <Box flexDirection="row">
        <Text color={COLORS.blue}>┃ </Text>
        <Text color={COLORS.amber}>{`${m.overlayQuery}`}</Text>
        <Text dimColor>  commands</Text>
      </Box>
      {entries.slice(0, 8).map((c, i) => (
        <Box key={c.command} flexDirection="row">
          <Text dimColor>┃ </Text>
          <Text color={i === m.overlayIndex ? COLORS.amberBright : COLORS.text} bold={i === m.overlayIndex}>
            {i === m.overlayIndex ? "> " : "  "}{c.command}
          </Text>
          <Text dimColor>{`  ${truncate(c.description, Math.max(10, Math.min(64, cols - 34)))}`}</Text>
        </Box>
      ))}
    </Box>
  );
}

function FilesOverlay(props: { m: Model; cwd: string; cache: FileEntry[] | null; cols: number }) {
  const { m, cwd, cache, cols } = props;
  const files = filterFiles(cwd, m.overlayQuery, cache);
  return (
    <Box flexDirection="column" marginLeft={2} marginTop={1}>
      <Box flexDirection="row">
        <Text color={COLORS.blue}>┃ </Text>
        <Text color={COLORS.amber}>{`@ ${m.overlayQuery}`}</Text>
        <Text dimColor>{files.length === 0 ? "  no matches" : `  ${files.length} files`}</Text>
      </Box>
      {files.slice(0, 8).map((f, i) => (
        <Box key={f.path} flexDirection="column">
          <Box flexDirection="row">
            <Text dimColor>┃ </Text>
            <Text color={i === m.overlayIndex ? COLORS.amberBright : COLORS.text} bold={i === m.overlayIndex}>
              {i === m.overlayIndex ? "> " : "  "}{f.display}
            </Text>
          </Box>
          <Box flexDirection="row">
            <Text dimColor>┃ </Text>
            <Text dimColor>{`  ${truncate(f.preview || f.path, Math.max(10, Math.min(64, cols - 36)))}`}</Text>
          </Box>
        </Box>
      ))}
    </Box>
  );
}

function HelpPanel(props: { agent: () => AgentClient; cwd: string; branch: string }) {
  const { agent, cwd, branch } = props;
  const a = agent();
  const keys: Array<[string, string]> = [
    ["enter", "send · select"],
    ["shift+enter / ctrl+enter", "new line"],
    ["esc", "interrupt agent · clear input · close overlay"],
    ["/", "command palette"],
    ["@", "file mention finder"],
    ["shift+tab", "toggle plan mode (read-only)"],
    ["ctrl+r", "cycle collapsed blocks"],
    ["j / k", "scroll (empty input)"],
    ["page up / page down", "scroll"],
    ["G", "jump to latest"],
    ["ctrl+c", "quit"],
  ];
  return (
    <Box flexDirection="column" marginLeft={2} marginTop={1}>
      <Text color={COLORS.textBright} bold>  Keys</Text>
      {keys.map(([k, d]) => (
        <Box key={k} flexDirection="row">
          <Text color={COLORS.amber} bold>{`  ${padRight(k, 22)}`}</Text>
          <Text dimColor>{d}</Text>
        </Box>
      ))}
      <Box marginTop={1}>
        <Text color={COLORS.textBright} bold>  Session</Text>
      </Box>
      <Text dimColor>{`    agent   ${a.info?.serverName ?? "…"}`}</Text>
      <Text dimColor>{`    model   ${a.info?.model || "…"}`}</Text>
      <Text dimColor>{`    cwd     ${cwd}${branch ? ` (${branch})` : ""}`}</Text>
      <Text dimColor>  any key to close</Text>
    </Box>
  );
}

function InfoPanel(props: { m: Model; agent: () => AgentClient }) {
  const { m, agent } = props;
  const a = agent();
  const rows: Array<[string, string]> = [
    ["agent", a.info?.serverName ?? "…"],
    ["model", a.info?.model || "…"],
    ["provider", a.info?.provider || "…"],
    ["context", `${fmtTokens(a.lastUsage.used)} / ${fmtTokens(a.lastUsage.size || 0)}`],
    ["est cost", estCost(a.lastUsage.used, a.lastUsage.cost)],
    ["turns", `${m.blocks.filter((b) => b.kind === "user").length}`],
  ];
  return (
    <Box flexDirection="column" marginLeft={2} marginTop={1}>
      <Text color={COLORS.textBright} bold>  Session info</Text>
      {rows.map(([k, v]) => (
        <Box key={k} flexDirection="row">
          <Text dimColor>{`  ${padRight(k, 10)}`}</Text>
          <Text color={COLORS.text}>{v}</Text>
        </Box>
      ))}
      <Text dimColor>  any key to close</Text>
    </Box>
  );
}
