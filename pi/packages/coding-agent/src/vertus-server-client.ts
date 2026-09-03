// VERTUS server client for one-shot CLI prompts.
//
// When the VERTUS hub (vertus/server/vertus_server.py) is reachable, a
// one-shot `vertus "<text>"` proxies through it so the CLI shares the same
// agent session (and transcript) as the quick bar and the phone. If the hub
// is unreachable the CLI falls back to its normal local session.
//
// Env overrides:
//   VERTUS_SERVER_URL  base URL of the hub (default http://127.0.0.1:8787)
//   VERTUS_NO_SERVER=1 bypass the hub entirely

import { homedir } from "node:os";
import { join } from "node:path";
import { readFile } from "node:fs/promises";

const DEFAULT_SERVER_URL = "http://127.0.0.1:8787";
const HEALTH_TIMEOUT_MS = 1500;

interface ServerOneShotOptions {
	messages: string[];
	initialMessage?: string;
}

function serverUrl(): string | undefined {
	if (process.env.VERTUS_NO_SERVER === "1") return undefined;
	return process.env.VERTUS_SERVER_URL ?? DEFAULT_SERVER_URL;
}

async function readToken(): Promise<string | undefined> {
	try {
		const raw = await readFile(join(homedir(), ".vertus", "token"), "utf8");
		return raw.trim() || undefined;
	} catch {
		return undefined;
	}
}

async function isHubAvailable(base: string, token: string): Promise<boolean> {
	try {
		const res = await fetch(`${base}/api/health`, {
			headers: { Authorization: `Bearer ${token}` },
			signal: AbortSignal.timeout(HEALTH_TIMEOUT_MS),
		});
		return res.ok;
	} catch {
		return false;
	}
}

/**
 * Prompts through the hub and streams the reply to stdout.
 * Returns true when the server handled the request (or failed while serving
 * it), false when it should fall back to a local session.
 */
export async function tryRunViaVertusServer(options: ServerOneShotOptions): Promise<boolean> {
	const base = serverUrl();
	if (!base) return false;
	const text = [options.initialMessage, ...options.messages].filter(Boolean).join("\n").trim();
	if (!text) return false;

	const token = await readToken();
	if (!token) return false;

	if (!(await isHubAvailable(base, token))) return false;

	// Open the event stream first so no reply is lost, then submit.
	const eventsRes = await fetch(`${base}/api/events`, {
		headers: { Authorization: `Bearer ${token}` },
	});
	if (!eventsRes.ok || eventsRes.body === null) return false;

	const posted = await fetch(`${base}/api/prompt`, {
		method: "POST",
		headers: {
			"Content-Type": "application/json",
			Authorization: `Bearer ${token}`,
			"X-Vertus-Client": "cli",
		},
		body: JSON.stringify({ text }),
	});
	if (!posted.ok) return false;

	let hadError = false;
	let lastChar = "";
	const decoder = new TextDecoder();
	let buffer = "";
	try {
		const reader = eventsRes.body.getReader();
		for (;;) {
			const { done, value } = await reader.read();
			if (done) break;
			buffer += decoder.decode(value, { stream: true });
			let newline: number;
			while ((newline = buffer.indexOf("\n")) >= 0) {
				const line = buffer.slice(0, newline).trim();
				buffer = buffer.slice(newline + 1);
				if (!line.startsWith("data: ")) continue;
				let event: { type?: string; text?: string; message?: string };
				try {
					event = JSON.parse(line.slice(6));
				} catch {
					continue;
				}
				switch (event.type) {
					case "text":
						if (event.text) {
							process.stdout.write(event.text);
							lastChar = event.text.slice(-1);
						}
						break;
					case "done":
						reader.releaseLock();
						if (lastChar && lastChar !== "\n") process.stdout.write("\n");
						return !hadError;
					case "error":
						hadError = true;
						process.stderr.write(`\n⚠️ ${event.message ?? "hub error"}\n`);
						break;
				}
			}
		}
	} catch {
		process.stderr.write("\n⚠️ lost connection to the VERTUS hub\n");
		process.exitCode = 1;
	}
	return !hadError;
}
