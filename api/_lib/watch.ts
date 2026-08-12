// Watch a YouTube video and answer questions about it — the video-capable model in the chain (Gemini
// today) ingests the URL natively (visual + audio), so there's no downloading/transcription and it
// works with the Mac off. Sending a link (or
// /watch <url>) starts a short-lived "video session" stored per chat in Upstash, so plain follow-up
// questions are answered about that same video until it's stopped or expires.

import { llmVideo } from "./llm";
import { kvGet, kvSet, kvDel } from "./kv";
import type { Reply } from "./reply";

const activeKey = (chatId: string) => `watch:active:${chatId}`;
const SESSION_TTL_S = 30 * 60; // a video session lasts 30 min of inactivity

const WATCH_SYSTEM =
  "You are Alfred, watching a YouTube video for Carlton and answering his questions about it. Be concise " +
  "and specific, grounded in what actually happens in the video; give rough timestamps when useful. If " +
  "the video doesn't cover what he asks, say so instead of guessing. Plain text, 24-hour times.";

const WATCH_HELP = [
  "Watch a video & ask about it (works with your Mac off):",
  "Send a YouTube link — or /watch <link> — optionally with a question, e.g.",
  "  /watch https://youtu.be/abc123 what's the main argument?",
  "Then just ask follow-up questions. /watch stop when you're done.",
].join("\n");

const YT_PATTERNS = [
  /youtu\.be\/([A-Za-z0-9_-]{6,})/i,
  /[?&]v=([A-Za-z0-9_-]{6,})/i,
  /\/shorts\/([A-Za-z0-9_-]{6,})/i,
  /\/embed\/([A-Za-z0-9_-]{6,})/i,
  /youtube\.com\/live\/([A-Za-z0-9_-]{6,})/i,
];

export function youtubeIdFrom(text: string): string | null {
  for (const p of YT_PATTERNS) {
    const m = p.exec(text);
    if (m) return m[1];
  }
  return null;
}

export function youtubeUrlFrom(text: string): string | null {
  const id = youtubeIdFrom(text);
  return id ? `https://www.youtube.com/watch?v=${id}` : null;
}

/** True when the message clearly contains a YouTube link (so we should treat it as "watch this"). */
export function hasYouTubeUrl(text: string): boolean {
  return /youtube\.com|youtu\.be/i.test(text) && youtubeIdFrom(text) !== null;
}

async function setActive(chatKey: string, url: string): Promise<void> {
  await kvSet(activeKey(chatKey), JSON.stringify({ url, at: Date.now() }), SESSION_TTL_S);
}

/** The active video URL for this chat, or null. */
export async function activeVideo(chatKey: string): Promise<string | null> {
  const raw = await kvGet(activeKey(chatKey));
  if (!raw) return null;
  try {
    const v = JSON.parse(raw);
    return typeof v?.url === "string" ? v.url : null;
  } catch {
    return null;
  }
}

/** Answer `question` about `url`, refreshing the session. Shows a typing status while it watches. */
async function answerAbout(url: string, question: string, reply: Reply, chatKey: string): Promise<void> {
  // (Telegram showed a typing indicator here; it has no cross-transport
  // equivalent, and emitting it as a message would be noise in the app.)
  const answer = await llmVideo(WATCH_SYSTEM, question, url);
  await setActive(chatKey, url); // keep the session warm on each interaction
  if (!answer) {
    return reply("I couldn't get through that video — it may be private, age-restricted, too long, or unavailable. Try another link.");
  }
  await reply(answer);
}

/** Entry for `/watch …` and for a bare YouTube link. Handles start, ask-about-active, and stop. */
export async function handleWatch(args: string, reply: Reply, chatKey: string): Promise<void> {
  const trimmed = args.trim();
  if (/^(stop|off|done|clear|end)\b/i.test(trimmed)) {
    await kvDel(activeKey(chatKey));
    return reply("Stopped watching. Send a new link anytime.");
  }

  const url = youtubeUrlFrom(trimmed);
  if (url) {
    const question = trimmed.replace(/\S*(youtube\.com|youtu\.be)\S*/gi, "").trim();
    await reply("🎬 Watching that video… (can take up to a minute)");
    await answerAbout(url, question || "Give a concise summary: what is this video about and its key points?", reply, chatKey);
    await reply("Ask me anything about it — /watch stop when you're done.");
    return;
  }

  // No URL in the message → treat as a question about the active video, else show help.
  const active = await activeVideo(chatKey);
  if (active) return answerAbout(active, trimmed || "Summarize the key points.", reply, chatKey);
  return reply(WATCH_HELP);
}

/** A plain follow-up message while a video session is active. */
export async function watchFollowUp(text: string, reply: Reply, chatKey: string): Promise<void> {
  const active = await activeVideo(chatKey);
  if (!active) return; // caller checked, but guard anyway
  return answerAbout(active, text, reply, chatKey);
}
