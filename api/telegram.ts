// Alfred Lite — Telegram webhook handler (Vercel serverless). Handles chat + adding calendar events
// from a photo or text, independent of the Mac. Owner-only. Telegram POSTs each update here.

import { sendMessage, downloadFile, largestPhotoId } from "./_lib/telegram";
import { geminiText } from "./_lib/gemini";
import { extractFromText, extractFromImage } from "./_lib/extract";
import { createEvent } from "./_lib/caldav";

const HELP = [
  "Commands:",
  "/calendar — add an event. Attach a photo of it, or type details: /calendar dentist tomorrow 15:00",
  "/help — show this",
  "Or just talk to me.",
].join("\n");

const CHAT_SYSTEM =
  "You are Alfred, Carlton's personal assistant, reachable on his phone. Be concise and direct — lead " +
  "with the answer, cut filler and preamble. Real conversation: contractions, natural language, no forced " +
  "enthusiasm, one question at a time. Be unbiased and intellectually honest — when Carlton states a " +
  "debatable opinion or plan, push back with the counterargument instead of just agreeing. Always write " +
  "times in 24-hour format (14:30, not 2:30 PM).";

export default async function handler(req: Request): Promise<Response> {
  if (req.method !== "POST") return new Response("Alfred Lite is running.");
  const token = process.env.CLOUD_BOT_TOKEN;
  const owner = process.env.OWNER_CHAT_ID;
  if (!token || !owner) return new Response("ok");
  let update: any;
  try {
    update = await req.json();
  } catch {
    return new Response("ok");
  }
  try {
    await handleUpdate(update, token, owner);
  } catch {
    // Always ack so Telegram doesn't retry-storm; errors are surfaced to the user inside handlers.
  }
  return new Response("ok");
}

async function handleUpdate(update: any, token: string, owner: string): Promise<void> {
  const msg = update?.message ?? update?.edited_message;
  if (!msg) return;
  if (String(msg.chat?.id ?? "") !== String(owner)) return; // owner only

  const chatId = String(msg.chat.id);

  // Photo → treat as "add this event to my calendar".
  const photoId = largestPhotoId(msg);
  if (photoId) return handlePhoto(photoId, msg.caption, token, chatId);

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
