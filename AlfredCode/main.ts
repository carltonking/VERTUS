#!/usr/bin/env node
/**
 * main.ts — AlfredCode's entry point.
 *
 *   alfred-code [path] [prompt...]
 *   alfred-code --path ./src --prompt "add error handling"
 *   alfred-code --agent opencode
 *
 * Launches freebuff (default) or opencode in ACP mode, and renders the TUI.
 */

import React from "react";
import { render } from "ink";
import { spawnSync } from "node:child_process";
import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { AgentClient, resolveLauncher } from "./src/agent.js";
import App from "./src/ui.js";

const VERSION = "1.0.0";

interface Args {
  cwd: string;
  prompt: string;
  agent?: string;
  help: boolean;
}

function parseArgs(argv: string[]): Args {
  const out: Args = { cwd: process.cwd(), prompt: "", help: false };
  const positional: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") { out.help = true; continue; }
    if (a === "--version" || a === "-v") { console.log(`alfred-code ${VERSION}`); process.exit(0); }
    if (a === "--path" || a === "-p") { out.cwd = resolve(argv[++i] ?? ""); continue; }
    if (a === "--agent") { out.agent = argv[++i]; continue; }
    if (a === "--prompt") { out.prompt = argv[++i] ?? ""; continue; }
    if (a.startsWith("--")) { console.error(`Unknown flag: ${a}`); out.help = true; continue; }
    positional.push(a);
  }
  if (positional.length > 0) {
    // First positional is the project path; the rest is the initial prompt.
    const maybeDir = resolve(positional[0]);
    if (existsSync(maybeDir) && statSync(maybeDir).isDirectory()) {
      out.cwd = maybeDir;
      out.prompt = positional.slice(1).join(" ");
    } else {
      out.prompt = positional.join(" ");
    }
  }
  return out;
}

function printHelp() {
  console.log(`alfred-code ${VERSION} — a Claude Code-style TUI powered by freebuff/opencode (ACP).

USAGE
  alfred-code [path] [prompt...]     open a project, optionally start a prompt
  alfred-code --path <dir>           open a specific folder
  alfred-code --agent <name>         freebuff (default) or opencode
  alfred-code --prompt "<text>"      send an initial prompt after boot

KEYS
  enter          send · select          esc      interrupt / clear / close
  shift+enter    new line               /        command palette
  @              file mention finder    shift+tab  plan mode (read-only)
  ctrl+r         cycle collapsed blocks j / k    scroll (empty input)
  ctrl+c         quit

ENV
  ALFRED_AGENT        force the agent binary name ("freebuff" | "opencode")
  ALFRED_FREEBUFF_BIN path to the freebuff CLI
  ALFRED_OPENCODE_BIN path to the opencode CLI
`);
}

function gitBranch(cwd: string): string {
  try {
    const r = spawnSync("git", ["branch", "--show-current"], { cwd, encoding: "utf8", timeout: 3000 });
    return (r.stdout ?? "").trim();
  } catch {
    return "";
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    process.exit(0);
  }

  const launcher = resolveLauncher(args.agent);
  const branch = gitBranch(args.cwd);
  let agent: AgentClient | null = null;
  const getAgent = () => {
    if (!agent) {
      agent = new AgentClient(launcher, {
        binary: launcher.binary,
        args: launcher.args,
        cwd: args.cwd,
        name: launcher.name,
        onEvent: () => { /* the UI swaps this in at boot */ },
      });
    }
    return agent;
  };

  const { waitUntilExit } = render(
    React.createElement(App, {
      cwd: args.cwd,
      branch,
      agentName: launcher.name,
      initialPrompt: args.prompt || undefined,
      agent: getAgent,
    }),
  );

  await waitUntilExit();
  getAgent().stop();
  process.exit(0);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
