// Transport-neutral routing — "message in, reply text out", with no Telegram in sight.
//
// Everything Alfred can do off-Mac has until now been reachable only through api/telegram.ts, whose
// handlers take (token, chatId) and call sendMessage themselves rather than returning anything. That
// makes them unusable from any other front door. This module is the seam: the paths that resolve to a
// single reply live here, so both the Telegram webhook and the iOS app (api/app.ts) can share them.
//
// Handlers now take a `Reply` sink and a `chatKey` (see _lib/reply.ts) rather than
// (token, chatId), so the multi-message and session-stateful flows — /email,
// /routine, /school, YouTube watch sessions — live here too and work from either
// surface. Only file uploads (/syllabus, event photos) remain Telegram-only, and
// that is a client limitation: the iOS app has no attachment UI to send one.

import { answerChat, macOnlyReply } from "./chat";
import { handleEmail, isEmailCheck } from "./emailflow";
import { routineCommand, ROUTINE_HELP } from "./routines";
import { schoolCommand } from "./school";
import { handleWatch, hasYouTubeUrl, activeVideo, watchFollowUp } from "./watch";
import type { Reply } from "./reply";
import { extractFromText } from "./extract";
import { createEvent } from "./caldav";
import { chainStatus } from "./llm";

export const APP_HELP = [
  "I'm Alfred. Just talk to me — I can answer questions, check your calendar, and look things up.",
  "",
  "calendar — add an event: \"put dentist tomorrow 15:00 on my calendar\"",
  "/models — which AI backends are up",
  "",
  "/email — triage your inbox · /routine — scheduled jobs · /school — course items",
  "/watch <youtube url> — watch a video and answer questions about it",
  "",
  "Syllabus imports still need Telegram — they take a PDF or photo attachment.",
].join("\n");

/** Natural-language "add X to my calendar" (not a read like "what's on my calendar"). */
export function isCalendarAdd(text: string): boolean {
  const q = text.toLowerCase();
  if (!q.includes("calendar") && !q.includes("schedule")) return false;
  const addVerb = ["add", "put", "create", "schedule", "save", "make", "set up", "new event", "book"].some((v) => q.includes(v));
  const read = ["what", "show", "list", "check", "do i have", "upcoming"].some((v) => q.includes(v));
  return addVerb && !read;
}

/** Pull an event out of free text and write it to iCloud. Returns the reply to show the user. */
export async function addEventFromText(text: string): Promise<string> {
  const ev = await extractFromText(text, new Date());
  if (!ev) return "I couldn't find an event in that. Try: dentist tomorrow 15:00 at 5th ave.";
  const res = await createEvent(ev);
  return res.message;
}


/**
 * Route one message through Alfred's full pipeline.
 *
 * This mirrors the Telegram webhook's text path exactly, in the same order, so
 * the two surfaces cannot drift: whatever Telegram does with a message, the app
 * now does too. Telegram keeps its own entry point only for what is genuinely
 * Telegram-shaped — attachments, and the webhook envelope itself.
 *
 * `chatKey` scopes per-conversation state (email drafts, the numbered message
 * list, an active video session). Telegram passes its chat id; the app passes
 * APP_CHAT_KEY, deliberately separate so the two don't clobber each other's
 * drafts.
 */
export async function routeMessage(text: string, reply: Reply, chatKey: string): Promise<void> {
  const t = text.trim();
  if (!t) return reply("Say something and I'll answer.");

  if (t.startsWith("/")) return routeCommand(t, reply, chatKey);
  if (hasYouTubeUrl(t)) return handleWatch(t, reply, chatKey);
  if (isCalendarAdd(t)) return reply(await addEventFromText(t));
  if (isEmailCheck(t)) return handleEmail("", reply, chatKey);

  // Genuinely Mac-only asks get an honest decline rather than a hallucinated success.
  const macOnly = macOnlyReply(t);
  if (macOnly) return reply(macOnly);

  // Inside an active video session, plain messages are follow-ups about that video.
  if (await activeVideo(chatKey)) return watchFollowUp(t, reply, chatKey);

  return reply(await answerChat(t));
}

async function routeCommand(cmd: string, reply: Reply, chatKey: string): Promise<void> {
  const [wordRaw, ...rest] = cmd.slice(1).split(" ");
  const word = (wordRaw.split("@")[0] || "").toLowerCase();
  const args = rest.join(" ").trim();

  switch (word) {
    case "calendar":
    case "cal":
    case "event":
      if (!args) return reply("Add the details — e.g. /calendar dentist tomorrow 15:00.");
      return reply(await addEventFromText(args));

    case "school":
    case "class":
    case "course":
      return schoolCommand(args, reply, chatKey);

    case "routine":
    case "routines":
      return routineCommand(args, reply, chatKey);

    case "email":
    case "inbox":
    case "mail":
      return handleEmail(args, reply, chatKey);

    case "watch":
    case "video":
      return handleWatch(args, reply, chatKey);

    case "models":
    case "llm":
      return reply(await chainStatus());

    case "help":
    case "start":
      return reply(APP_HELP);

    case "syllabus":
    case "syl":
      // The only remaining Telegram-only path, and honestly so: importing a
      // syllabus needs a PDF or photo, and the iOS app has no way to attach one.
      return reply("Send the syllabus as a PDF or clear photo with the course in the caption — that needs Telegram for now:\n/syllabus CS 101");

    default:
      return reply(`Unknown command "/${word}". Try /help.`);
  }
}

/** Back-compat single-reply wrapper. Prefer routeMessage. */
export async function routeText(text: string): Promise<string> {
  const parts: string[] = [];
  await routeMessage(text, async (t) => { if (t.trim()) parts.push(t.trim()); }, "app");
  return parts.join("\n\n") || "I didn't have a reply for that.";
}
