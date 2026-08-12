// One brain, two transports.
//
// Alfred's richer handlers — email triage, routines, school, video — grew inside
// the Telegram webhook and took `(token, chatId)`, calling `sendMessage` directly.
// That made them unreachable from anywhere else, which is why `routeText` had to
// answer "/email isn't wired into the app yet — use Telegram for that one".
//
// Handlers now take a `Reply` sink and a `chatKey` instead:
//
//   Telegram  → each reply is sent as its own message, exactly as before
//   iOS app   → replies are collected and returned as one JSON body
//
// A sink rather than a return value because several handlers report progress
// before doing slow work ("📬 Checking your inbox…", "📷 Reading that…"). With a
// single return string those would vanish on Telegram, turning a responsive chat
// into a silent wait. The sink preserves them where they matter and joins them
// where they don't.

/** Somewhere to send a line of Alfred's response. */
export type Reply = (text: string) => Promise<void>;

/**
 * The key used for per-conversation state in KV (email drafts, the message list,
 * the active video session).
 *
 * On Telegram this is the chat id. The app has no equivalent, so it uses a fixed
 * key — Alfred is single-owner and the app is one client, so a constant is
 * honest. It is deliberately NOT the Telegram chat id: sharing that key would let
 * the app clobber a draft composed on Telegram, and vice versa.
 */
export const APP_CHAT_KEY = "app";

/** Collects replies in order so a request/response transport can return them. */
export function collectingReply(): { reply: Reply; text: () => string } {
  const parts: string[] = [];
  return {
    reply: async (t: string) => {
      const trimmed = t.trim();
      if (trimmed) parts.push(trimmed);
    },
    text: () => parts.join("\n\n"),
  };
}
