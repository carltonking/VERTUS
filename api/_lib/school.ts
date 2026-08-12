// Course-schedule commands, shared by Telegram and the iOS app.
//
// Lifted out of the Telegram webhook so `/school` works from any surface; see
// _lib/reply.ts for why handlers take a Reply sink.

import { deleteSchool } from "./caldav";
import { normCode } from "./keys";
import type { Reply } from "./reply";

export async function schoolCommand(args: string, reply: Reply, chatKey: string): Promise<void> {
  const [subRaw, ...rest] = args.split(" ");
  const sub = (subRaw || "").toLowerCase();
  const code = rest.join(" ").trim();
  if (sub === "delete" || sub === "drop" || sub === "remove") {
    if (!code) return reply("Which course? e.g. /school delete CS 101");
    await reply(`🗑️ Removing ${code} items…`);
    const deleted = await deleteSchool((tok) => tok.c === normCode(code));
    if (deleted === null) return reply("Calendar isn't set up yet.");
    return reply(deleted ? `Removed ${deleted} ${code} item${deleted === 1 ? "" : "s"}.` : `No ${code} items found.`);
  }
  return reply("Usage: /school delete <course code> — e.g. /school delete CS 101");
}
