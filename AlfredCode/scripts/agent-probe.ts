#!/usr/bin/env tsx
/**
 * agent-probe.ts — boots a real ACP agent (freebuff or opencode), completes
 * the handshake, runs one short turn, and prints every event the TUI would
 * receive. Proves the wire protocol end to end without a terminal UI.
 *
 *   npm run probe                 # default agent
 *   npm run probe -- --agent opencode --prompt "say hi"
 */

import { AgentClient, resolveLauncher } from "../src/agent.js";
import { resolve } from "node:path";

const args = process.argv.slice(2);
const agentFlag = flag(args, "--agent") ?? process.env.ALFRED_AGENT;
const prompt = flag(args, "--prompt") ?? "Reply with exactly: probe ok";
const cwd = flag(args, "--path") ?? process.cwd();

function flag(argv: string[], name: string): string | undefined {
  const i = argv.indexOf(name);
  return i >= 0 && i + 1 < argv.length ? argv[i + 1] : undefined;
}

const launcher = resolveLauncher(agentFlag);
console.log(`[probe] launching ${launcher.binary} ${launcher.args.join(" ")} in ${cwd}`);
console.log(`[probe] prompt: ${prompt}\n`);

const events: string[] = [];
const client = new AgentClient(launcher, {
  binary: launcher.binary,
  args: launcher.args,
  cwd,
  name: launcher.name,
  turnTimeout: 120,
  onEvent: (ev) => {
    switch (ev.kind) {
      case "text": process.stdout.write(ev.text); break;
      case "thought": events.push(`[thought] ${ev.text.slice(0, 60).replace(/\n/g, " ")}`); break;
      case "toolStart": events.push(`[tool] start  ${ev.toolKind || ev.title}`); break;
      case "toolUpdate": events.push(`[tool] update ${ev.id} → ${ev.status ?? "…"}`); break;
      case "usage": events.push(`[usage] ${ev.used}/${ev.size}`); break;
      case "finished": events.push(`\n[finished] stopReason=${ev.stopReason}`); break;
      case "failed": events.push(`\n[FAILED] ${ev.message}`); break;
      case "log": events.push(`[log] ${ev.line.slice(0, 80)}`); break;
      case "permission": events.push(`[permission] ${ev.title} — auto-allow`); ev.respond("allow"); break;
    }
  },
});

try {
  const info = await client.start();
  console.log(`[probe] connected: ${info.serverName} ${info.serverVersion} | model=${info.model || "?"} | session=${info.sessionId.slice(0, 8)}…\n`);
  await client.prompt(prompt);
} catch (err) {
  console.error(`\n[probe] ERROR: ${err instanceof Error ? err.message : String(err)}`);
  process.exitCode = 1;
} finally {
  client.stop();
  console.log("\n\n[probe] event summary:");
  for (const e of events) console.log(`  ${e}`);
  console.log(`[probe] usage: ${client.lastUsage.used}/${client.lastUsage.size} tokens`);
}
