// Transport-neutral routing — "message in, reply text out", with no Telegram in sight.
//
// Everything Alfred can do off-Mac has until now been reachable only through api/telegram.ts, whose
// handlers take (token, chatId) and call sendMessage themselves rather than returning anything. That
// makes them unusable from any other front door. This module is the seam: the paths that resolve to a
// single reply live here, so both the Telegram webhook and the iOS app (api/app.ts) can share them.
//
// Not here yet — the flows that push several messages or need per-chat session state, which still
// live in api/telegram.ts: /syllabus, /email, /routine, /school, and YouTube watch sessions.

import { answerChat, macOnlyReply } from "./chat";
import { extractFromText } from "./extract";
import { createEvent } from "./caldav";
import { chainStatus } from "./llm";

export const APP_HELP = [
  "I'm Alfred. Just talk to me — I can answer questions, check your calendar, and look things up.",
  "",
  "calendar — add an event: \"put dentist tomorrow 15:00 on my calendar\"",
  "/models — which AI backends are up",
  "",
  "Email, syllabus imports, routines and video Q&A are still Telegram-only for now.",
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
 * Route one message to one reply. Mirrors the plain-text path of the Telegram webhook's handleUpdate,
 * minus the flows that can't answer in a single message.
 */
export async function routeText(text: string): Promise<string> {
  const t = text.trim();
  if (!t) return "Say something and I'll answer.";

  if (t.startsWith("/")) {
    const [wordRaw, ...rest] = t.slice(1).split(" ");
    const word = (wordRaw.split("@")[0] || "").toLowerCase();
    const args = rest.join(" ").trim();
    switch (word) {
      case "calendar":
      case "cal":
      case "event":
        if (!args) return "Add the details — e.g. /calendar dentist tomorrow 15:00.";
        return addEventFromText(args);
      case "models":
      case "llm":
        return chainStatus();
      case "help":
      case "start":
        return APP_HELP;
      // Deliberately explicit rather than falling through to the model, which would happily
      // pretend it had done the thing.
      case "email":
      case "inbox":
      case "mail":
      case "routine":
      case "routines":
      case "syllabus":
      case "syl":
      case "school":
      case "class":
      case "course":
      case "watch":
      case "video":
        return `“/${word}” isn't wired into the app yet — use Telegram for that one.`;
      default:
        return `Unknown command “/${word}”. Try /help.`;
    }
  }

  if (isCalendarAdd(t)) return addEventFromText(t);

  // Genuinely Mac-only asks get an honest decline rather than a hallucinated answer.
  const macOnly = macOnlyReply(t);
  if (macOnly) return macOnly;

  return answerChat(t);
}
