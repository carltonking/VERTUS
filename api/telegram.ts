// Alfred Lite — Telegram webhook handler (Vercel serverless). Handles chat + adding calendar events
// from a photo or text, independent of the Mac. Owner-only. Telegram POSTs each update here.

import { sendMessage, downloadFile, largestPhotoId } from "./_lib/telegram";
import { geminiText } from "./_lib/gemini";
import { extractFromText, extractFromImage, extractSyllabus, SyllabusItem, SyllabusItemType, ExtractedEvent, AlarmSpec, USER_TZ } from "./_lib/extract";
import { createEvent, createEvents, deleteSchool, diagnose } from "./_lib/caldav";
import { planStudySessions } from "./_lib/study";
import { itemKey, batchId, normCode, schoolURL, schoolToken, schoolCategories } from "./_lib/keys";

const HELP = [
  "Commands:",
  "/calendar — add one event (photo or text): /calendar dentist tomorrow 15:00",
  "/syllabus — add a whole course. Attach the syllabus PDF/photo, caption /syllabus CS 101",
  "/school delete <code> — remove a course's items",
  "/help — show this",
  "Or just talk to me.",
].join("\n");

const MAX_ITEMS = Number(process.env.SYLLABUS_MAX_ITEMS || 60);

const CHAT_SYSTEM =
  "You are Alfred, Carlton's personal assistant, reachable on his phone. Be concise and direct — lead " +
  "with the answer, cut filler and preamble. Real conversation: contractions, natural language, no forced " +
  "enthusiasm, one question at a time. Be unbiased and intellectually honest — when Carlton states a " +
  "debatable opinion or plan, push back with the counterargument instead of just agreeing. Always write " +
  "times in 24-hour format (14:30, not 2:30 PM).";

import type { IncomingMessage, ServerResponse } from "http";

const PUBLIC_URL = "https://alfredassistant.vercel.app/api/telegram";

export default async function handler(req: IncomingMessage, res: ServerResponse): Promise<void> {
  if (req.method !== "POST") {
    // One-time, owner-gated webhook self-setup: GET /api/telegram?setup=<OWNER_CHAT_ID>.
    // Lets us arm the Telegram webhook using the token already in this function's env
    // (the token is stored "Sensitive" in Vercel and can't be pulled back out).
    // Owner-gated CalDAV diagnostic: GET /api/telegram?diag=<OWNER_CHAT_ID>. Reports each iCloud
    // discovery step + a throwaway test PUT so we can see exactly why a calendar write fails.
    const d = /[?&]diag=([^&]+)/.exec(req.url || "");
    if (d) {
      const owner = process.env.OWNER_CHAT_ID;
      res.statusCode = 200;
      res.setHeader("Content-Type", "application/json");
      if (!owner || decodeURIComponent(d[1]) !== owner) {
        res.end(JSON.stringify({ ok: false, error: "not authorized" }));
        return;
      }
      const doPut = /[?&]put=1(&|$)/.test(req.url || "");
      const report = await diagnose(doPut).catch((e: any) => ({ error: String(e?.message ?? e) }));
      res.end(JSON.stringify(report, null, 2));
      return;
    }

    // Owner-gated syllabus-extraction preview (read-only, no writes):
    // GET /api/telegram?syldiag=<OWNER>&text=<url-encoded syllabus text>
    const sd = /[?&]syldiag=([^&]+)/.exec(req.url || "");
    if (sd) {
      const owner = process.env.OWNER_CHAT_ID;
      res.statusCode = 200;
      res.setHeader("Content-Type", "application/json");
      if (!owner || decodeURIComponent(sd[1]) !== owner) {
        res.end(JSON.stringify({ ok: false, error: "not authorized" }));
        return;
      }
      const t = /[?&]text=([^&]*)/.exec(req.url || "");
      const sample = t ? decodeURIComponent(t[1]) : "";
      if (!sample) {
        res.end(JSON.stringify({ ok: false, error: "add &text=<url-encoded syllabus text>" }));
        return;
      }
      const parsed = await extractSyllabus(sample, null, new Date()).catch((e: any) => ({ error: String(e?.message ?? e) }));
      res.end(JSON.stringify(parsed, null, 2));
      return;
    }

    const m = /[?&]setup=([^&]+)/.exec(req.url || "");
    if (m) {
      const token = process.env.CLOUD_BOT_TOKEN;
      const owner = process.env.OWNER_CHAT_ID;
      res.statusCode = 200;
      res.setHeader("Content-Type", "application/json");
      if (!token || !owner || decodeURIComponent(m[1]) !== owner) {
        res.end(JSON.stringify({ ok: false, error: "setup not authorized" }));
        return;
      }
      try {
        const tg = await fetch(`https://api.telegram.org/bot${token}/setWebhook`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({ url: PUBLIC_URL, allowed_updates: ["message"], drop_pending_updates: true }),
        });
        const hookBody = await tg.text();
        // Register the command menu so the bot shows its skills (the "/" menu), like the Mac bot.
        await fetch(`https://api.telegram.org/bot${token}/setMyCommands`, {
          method: "POST",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            commands: [
              { command: "calendar", description: "Add an event — attach a photo or type details" },
              { command: "syllabus", description: "Add a course — attach the syllabus PDF/photo (caption the course)" },
              { command: "school", description: "Manage courses — e.g. /school delete CS 101" },
              { command: "help", description: "What Alfred can do" },
            ],
          }),
        });
        res.end(hookBody);
      } catch (e: any) {
        res.end(JSON.stringify({ ok: false, error: String(e?.message ?? e) }));
      }
      return;
    }
    res.statusCode = 200;
    res.end("Alfred Lite is running.");
    return;
  }
  const token = process.env.CLOUD_BOT_TOKEN;
  const owner = process.env.OWNER_CHAT_ID;
  if (!token || !owner) {
    res.statusCode = 200;
    res.end("ok");
    return;
  }
  let update: any;
  try {
    update = await readJson(req);
  } catch {
    res.statusCode = 200;
    res.end("ok");
    return;
  }
  try {
    await handleUpdate(update, token, owner);
  } catch {
    // Always ack so Telegram doesn't retry-storm; errors are surfaced to the user inside handlers.
  }
  res.statusCode = 200;
  res.end("ok");
}

/** Read and JSON-parse the request body from the Node request stream. */
function readJson(req: IncomingMessage): Promise<any> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (c: Buffer) => chunks.push(c));
    req.on("end", () => {
      try {
        const raw = Buffer.concat(chunks).toString("utf8").trim();
        resolve(raw ? JSON.parse(raw) : {});
      } catch (e) {
        reject(e);
      }
    });
    req.on("error", reject);
  });
}

async function handleUpdate(update: any, token: string, owner: string): Promise<void> {
  const msg = update?.message; // ignore edited_message: the single-event path uses random UIDs and would duplicate
  if (!msg) return;
  if (String(msg.chat?.id ?? "") !== String(owner)) return; // owner only

  const chatId = String(msg.chat.id);

  // Photo → a syllabus if captioned /syllabus, otherwise a single "add to calendar" event.
  const photoId = largestPhotoId(msg);
  if (photoId) {
    if (isSyllabusTrigger(msg.caption)) return handleSyllabus(photoId, "image/jpeg", msg.caption, token, chatId);
    return handlePhoto(photoId, msg.caption, token, chatId);
  }

  // Document (PDF) → treat as a syllabus.
  const doc = msg.document;
  if (doc?.file_id) {
    if ((doc.file_size ?? 0) > 20 * 1024 * 1024)
      return sendMessage(token, chatId, "That file's over 20 MB — Telegram won't let me fetch it. Send a smaller PDF, or import it on your Mac.");
    const mime = (doc.mime_type || "").toLowerCase();
    if (mime && mime !== "application/pdf" && !mime.startsWith("image/"))
      return sendMessage(token, chatId, "I can read a PDF or a photo of a syllabus — export it as a PDF and resend.");
    return handleSyllabus(doc.file_id, mime || "application/pdf", msg.caption, token, chatId);
  }

  const text = (msg.text ?? "").trim();
  if (!text) return;

  if (text.startsWith("/")) return handleCommand(text, token, chatId);
  if (isCalendarAdd(text)) return addFromText(text, token, chatId);

  const reply = (await geminiText(CHAT_SYSTEM, text)) ?? "Sorry — I couldn't reach the AI just now. Try again in a moment.";
  await sendMessage(token, chatId, reply);
}

async function handleCommand(cmd: string, token: string, chatId: string): Promise<void> {
  const [wordRaw, ...rest] = cmd.slice(1).split(" ");
  const word = (wordRaw.split("@")[0] || "").toLowerCase();
  const args = rest.join(" ").trim();
  switch (word) {
    case "calendar":
    case "cal":
    case "event":
      if (!args) return sendMessage(token, chatId, "Attach a photo of an event, or add details — e.g. /calendar dentist tomorrow 15:00.");
      return addFromText(args, token, chatId);
    case "syllabus":
    case "syl":
      return sendMessage(token, chatId, "Send me the syllabus as a PDF or a clear photo, with the course in the caption:\n/syllabus CS 101");
    case "school":
    case "class":
    case "course":
      return handleSchool(args, token, chatId);
    case "help":
    case "start":
      return sendMessage(token, chatId, HELP);
    default:
      return sendMessage(token, chatId, `Unknown command “/${word}”. Try /help.`);
  }
}

async function addFromText(text: string, token: string, chatId: string): Promise<void> {
  const ev = await extractFromText(text, new Date());
  if (!ev) return sendMessage(token, chatId, "I couldn't find an event in that. Try: /calendar dentist tomorrow 15:00 at 5th ave.");
  const res = await createEvent(ev);
  await sendMessage(token, chatId, res.message);
}

async function handlePhoto(fileId: string, caption: string | undefined, token: string, chatId: string): Promise<void> {
  await sendMessage(token, chatId, "📷 Reading that…");
  const bytes = await downloadFile(token, fileId);
  if (!bytes) return sendMessage(token, chatId, "Couldn't download that image — try sending it again.");
  const base64 = Buffer.from(bytes).toString("base64");
  const cleanCaption = caption && !caption.startsWith("/") ? caption : undefined;
  const ev = await extractFromImage(base64, "image/jpeg", new Date(), cleanCaption);
  if (!ev) return sendMessage(token, chatId, "I couldn't find an event in that image. Try a clearer photo, or type the details.");
  const res = await createEvent(ev);
  await sendMessage(token, chatId, res.message);
}

/** Natural-language "add X to my calendar" (not a read like "what's on my calendar"). */
function isCalendarAdd(text: string): boolean {
  const q = text.toLowerCase();
  if (!q.includes("calendar") && !q.includes("schedule")) return false;
  const addVerb = ["add", "put", "create", "schedule", "save", "make", "set up", "new event", "book"].some((v) => q.includes(v));
  const read = ["what", "show", "list", "check", "do i have", "upcoming"].some((v) => q.includes(v));
  return addVerb && !read;
}

// MARK: - Syllabus

function isSyllabusTrigger(caption?: string): boolean {
  return !!caption && /^\/syllabus\b/i.test(caption.trim());
}
/** The course name the user typed after "/syllabus", or undefined. */
function courseFromCaption(caption?: string): string | undefined {
  if (!caption) return undefined;
  const m = /^\/syllabus(?:@\S+)?\s*([\s\S]*)$/i.exec(caption.trim());
  const c = (m ? m[1] : caption).trim();
  return c || undefined;
}

const EMOJI: Record<SyllabusItemType, string> = {
  assignment: "📝",
  quiz: "🧠",
  exam: "✍️",
  final: "🎓",
  reading: "📖",
  project: "🛠️",
  other: "📌",
};

function alarmsFor(item: SyllabusItem): AlarmSpec[] {
  const isExam = item.type === "exam" || item.type === "final";
  if (item.allDay) {
    // All-day: DTSTART is local midnight, so measure from START to hit friendly clock times.
    return isExam
      ? [{ related: "START", offset: "-P6DT15H" }, { related: "START", offset: "-PT15H" }, { related: "START", offset: "PT9H" }]
      : [{ related: "START", offset: "-PT15H" }, { related: "START", offset: "PT9H" }];
  }
  return isExam
    ? [{ offset: "-P1W" }, { offset: "-P1D" }, { offset: "-PT2H" }]
    : [{ offset: "-P1D" }, { offset: "-PT1H" }];
}

function toEvent(item: SyllabusItem, code: string, batch: string): ExtractedEvent {
  const key = itemKey(code, item.type, item.title, item.date);
  const human = [
    item.weight ? `Weight: ${item.weight}` : "",
    item.topics.length ? `Topics: ${item.topics.join(", ")}` : "",
    item.notes || "",
  ].filter(Boolean).join(" · ");
  const token = schoolToken({ key, code, type: item.type, batch, weight: item.weight, topics: item.topics });
  return {
    title: `${EMOJI[item.type]} [${code}] ${item.title}`,
    date: item.date,
    start: item.start,
    end: item.end,
    allDay: item.allDay,
    location: item.location,
    notes: human ? `${human}\n\n${token}` : token,
    url: schoolURL(code, item.type, key),
    categories: schoolCategories(code, item.type, batch),
    uid: `alfred-${key}`,
    alarms: alarmsFor(item),
  };
}

async function handleSyllabus(fileId: string, mime: string, caption: string | undefined, token: string, chatId: string): Promise<void> {
  await sendMessage(token, chatId, "📚 Reading your syllabus… this can take ~20s.");
  const bytes = await downloadFile(token, fileId);
  if (!bytes) return sendMessage(token, chatId, "Couldn't download that file — try sending it again.");
  const base64 = Buffer.from(bytes).toString("base64");
  const courseHint = courseFromCaption(caption);
  const parsed = await extractSyllabus(base64, mime, new Date(), courseHint);
  if (!parsed || !parsed.items.length) {
    return sendMessage(token, chatId, "I couldn't find dated items in that. Make sure the syllabus lists explicit assignment/exam dates, or add them one at a time with /calendar.");
  }

  const code = (courseHint || parsed.code || parsed.course || "Course").trim();
  const batch = batchId(code, parsed.termYear);
  let items = parsed.items;
  let capped = 0;
  if (items.length > MAX_ITEMS) {
    capped = items.length - MAX_ITEMS;
    items = items.slice(0, MAX_ITEMS);
  }

  const deadlineEvents = items.map((it) => toEvent(it, code, batch));
  const studyEvents = items
    .filter((it) => it.type === "exam" || it.type === "final" || it.type === "quiz")
    .flatMap((it) => planStudySessions(it, code, itemKey(code, it.type, it.title, it.date), batch, new Date()));

  const result = await createEvents([...deadlineEvents, ...studyEvents]);
  await sendMessage(token, chatId, formatSyllabusSummary(code, items, studyEvents.length, result, capped));
}

function formatSyllabusSummary(
  code: string,
  items: SyllabusItem[],
  studyCount: number,
  result: { created: number; failed: number },
  capped: number,
): string {
  const n = (t: SyllabusItemType) => items.filter((i) => i.type === t).length;
  const counts: string[] = [];
  if (n("assignment")) counts.push(`Assignments: ${n("assignment")}`);
  if (n("quiz")) counts.push(`Quizzes: ${n("quiz")}`);
  if (n("exam")) counts.push(`Exams: ${n("exam")}`);
  if (n("final")) counts.push(`Final: ${n("final")}`);
  if (n("reading")) counts.push(`Readings: ${n("reading")}`);
  if (n("project")) counts.push(`Projects: ${n("project")}`);

  const today = isoTodayNY(new Date());
  const next = [...items].sort((a, b) => a.date.localeCompare(b.date)).find((i) => i.date >= today);

  const parts = [
    `✅ ${code} — added ${result.created} calendar item${result.created === 1 ? "" : "s"}` +
      (studyCount ? ` (incl. ${studyCount} study block${studyCount === 1 ? "" : "s"})` : "") + ".",
  ];
  if (counts.length) parts.push(counts.join(" · "));
  if (next) parts.push(`Next up: ${next.title} — ${fmtDate(next.date)}${next.allDay || !next.start ? "" : ` ${next.start}`}`);
  if (result.failed) parts.push(`⚠️ ${result.failed} couldn't be added.`);
  if (capped) parts.push(`(Capped at ${MAX_ITEMS} items; ${capped} more not added — send the rest separately.)`);
  parts.push(`Reminders are set on your phone. Re-upload anytime to update; \`/school delete ${code}\` to remove.`);
  return parts.join("\n");
}

async function handleSchool(args: string, token: string, chatId: string): Promise<void> {
  const [subRaw, ...rest] = args.split(" ");
  const sub = (subRaw || "").toLowerCase();
  const code = rest.join(" ").trim();
  if (sub === "delete" || sub === "drop" || sub === "remove") {
    if (!code) return sendMessage(token, chatId, "Which course? e.g. /school delete CS 101");
    await sendMessage(token, chatId, `🗑️ Removing ${code} items…`);
    const deleted = await deleteSchool((tok) => tok.c === normCode(code));
    if (deleted === null) return sendMessage(token, chatId, "Calendar isn't set up yet.");
    return sendMessage(token, chatId, deleted ? `Removed ${deleted} ${code} item${deleted === 1 ? "" : "s"}.` : `No ${code} items found.`);
  }
  return sendMessage(token, chatId, "Usage: /school delete <course code> — e.g. /school delete CS 101");
}

function isoTodayNY(now: Date): string {
  return new Intl.DateTimeFormat("en-CA", { timeZone: USER_TZ, year: "numeric", month: "2-digit", day: "2-digit" }).format(now);
}
function fmtDate(date: string): string {
  const [, m, d] = date.split("-").map(Number);
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${months[m - 1]} ${d}`;
}
