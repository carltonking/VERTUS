// VERTUS pi bridge — hosts ONE pi agent session for the Python server.
//
// JSON-lines protocol over stdio:
//   stdin:  {"cmd":"prompt","text":"..."}
//   stdout: {"type":"ready"} | {"type":"event","event":<pi event>}
//           | {"type":"done"} | {"type":"error","message":"..."}
//
// Run with bun (resolves pi's TypeScript sources directly):
//   bun vertus/server/pi_bridge.mjs

import { createAgentSession, SessionManager } from "../../pi/packages/coding-agent/src/index.ts";

function out(obj) {
  process.stdout.write(JSON.stringify(obj) + "\n");
}

// Pi events are plain objects (or classes with enumerable fields); make sure
// everything we forward is JSON-safe and keeps the `type` discriminator the
// server expects (message_update / tool_execution_start / agent_end / error...).
function serializeEvent(evt) {
  if (evt === null || evt === undefined) return { type: "raw" };
  if (typeof evt === "string") return { type: "raw", text: evt };
  if (typeof evt !== "object") return { type: "raw", value: String(evt) };
  try {
    const json = JSON.stringify(evt, (_k, v) => {
      if (typeof v === "bigint") return v.toString();
      if (typeof v === "function") return undefined;
      return v;
    });
    return json === undefined ? { type: "raw", value: String(evt) } : JSON.parse(json);
  } catch {
    return { type: "raw", value: String(evt) };
  }
}

async function main() {
  // In-memory sessions: never restore a stale model from an old session
  // file — always resolve the current settings default model.
  const { session, modelFallbackMessage } = await createAgentSession({
    sessionManager: SessionManager.inMemory(),
    cwd: process.env.VERTUS_CWD ?? process.cwd(),
  });
  if (modelFallbackMessage) out({ type: "log", message: modelFallbackMessage });
  session.subscribe((evt) => out({ type: "event", event: serializeEvent(evt) }));
  out({ type: "ready" });

  const rl = (await import("node:readline")).createInterface({ input: process.stdin });
  for await (const line of rl) {
    let cmd;
    try {
      cmd = JSON.parse(line);
    } catch {
      continue;
    }
    if (cmd.cmd !== "prompt") continue;
    const text = typeof cmd.text === "string" ? cmd.text.trim() : "";
    if (!text) {
      out({ type: "error", message: "empty prompt" });
      continue;
    }
    try {
      await session.prompt(text);
      out({ type: "done" });
    } catch (err) {
      out({ type: "error", message: err instanceof Error ? err.message : String(err) });
    }
  }
}

main().catch((err) => {
  out({ type: "error", message: err instanceof Error ? err.message : String(err) });
  process.exit(1);
});
