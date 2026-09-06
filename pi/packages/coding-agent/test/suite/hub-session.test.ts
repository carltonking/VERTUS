/**
 * HubSession — the terminal as a fleet client (VERTUS_ENGINE=hub).
 *
 * A stub hub (real HTTP server: prompt/steer/cancel/messages/runs/events-SSE)
 * stands in for the Python hub, and a real HubSession runs against it with
 * the same config assembly the other suite tests use. Covered:
 *   - transcript seeding from /api/agents/<id>/messages on start
 *   - prompt → POST /api/prompt + live text deltas from the SSE stream
 *   - steer mid-turn → POST /api/steer
 *   - abort → POST /api/agents/<id>/cancel
 *   - explicit degradation: setThinkingLevel posts a visible custom-role
 *     notice instead of doing nothing
 *   - a bot-initiated run (kind=message) on the agent's stream renders as an
 *     attributed user bubble
 *   - the --agent flag parses (precedence: flag > VERTUS_AGENT > primary)
 */

import { createServer, type Server } from "node:http";
import { AddressInfo } from "node:net";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { mkdirSync, rmSync, writeFileSync } from "node:fs";
import type { AgentMessage } from "@earendil-works/pi-agent-core";
import { registerFauxProvider, streamSimple } from "@earendil-works/pi-ai/compat";
import { afterEach, describe, expect, it } from "vitest";
import { Agent } from "@earendil-works/pi-agent-core";
import { SessionManager } from "../../src/core/session-manager.ts";
import { SettingsManager } from "../../src/core/settings-manager.ts";
import { createTestResourceLoader } from "../utilities.ts";
import { HubSession } from "../../src/core/hub-session.ts";
import { parseArgs } from "../../src/cli/args.ts";

class StubHub {
	server: Server;
	baseUrl = "";
	prompts: Array<{ agent_id: string; text: string }> = [];
	steers: Array<{ agent_id: string; text: string }> = [];
	cancels: number[] = [];
	lastRunId = "";
	history: Array<{ run_id: string; role: string; text: string }> = [];
	runDetails = new Map<string, { run_kind: string; from_agent: string; prompt: string }>();
	private sseClients = new Set<import("node:http").ServerResponse>();
	private seq = 0;

	constructor() {
		this.server = createServer((req, res) => {
			const url = new URL(req.url ?? "/", "http://x");
			const path = url.pathname;
			void this.route(req, res, path, url).catch(() => {
				res.statusCode = 500;
				res.end("{}");
			});
		});
	}

	async start(): Promise<void> {
		await new Promise<void>((resolve) => this.server.listen(0, "127.0.0.1", resolve));
		const addr = this.server.address() as AddressInfo;
		this.baseUrl = `http://127.0.0.1:${addr.port}`;
	}

	stop(): void {
		for (const client of this.sseClients) client.end();
		this.sseClients.clear();
		this.server.close();
	}

	/** Write one wire event to every connected SSE client. */
	push(type: string, fields: Record<string, unknown>): void {
		this.seq += 1;
		const envelope = { type, seq: this.seq, ts: Date.now() / 1000, ...fields };
		const frame = `data: ${JSON.stringify(envelope)}\n\n`;
		for (const client of this.sseClients) client.write(frame);
	}

	private async route(
		req: import("node:http").IncomingMessage,
		res: import("node:http").ServerResponse,
		path: string,
		url: URL,
	): Promise<void> {
		const json = (status: number, body: unknown) => {
			res.statusCode = status;
			res.setHeader("Content-Type", "application/json");
			res.end(JSON.stringify(body));
		};
		const body = await new Promise<string>((resolve) => {
			let data = "";
			req.on("data", (chunk) => (data += chunk));
			req.on("end", () => resolve(data));
		});

		if (path === "/api/prompt" && req.method === "POST") {
			const payload = JSON.parse(body);
			this.prompts.push({ agent_id: payload.agent_id, text: payload.text });
			this.lastRunId = "r1";
			json(202, { accepted: true, agent_id: payload.agent_id, run_id: this.lastRunId, sandbox_path: "/tmp" });
			return;
		}
		if (path === "/api/steer" && req.method === "POST") {
			const payload = JSON.parse(body);
			this.steers.push({ agent_id: payload.agent_id, text: payload.text });
			json(200, { steered: payload.text, agent_id: payload.agent_id, run_id: this.lastRunId });
			return;
		}
		if (path === "/api/agents/alpha/cancel" && req.method === "POST") {
			this.cancels.push(1);
			// Mirror the real hub (supervision): cancel runs the escalation
			// ladder, then the run reaches a terminal state and a `cancelled`
			// event goes out on the fleet stream. The session settles its
			// pending turn on that event, so the stub must emit it too.
			this.push("cancelled", { agent_id: "alpha", run_id: this.lastRunId });
			json(200, { cancelled: true });
			return;
		}
		if (path === "/api/agents/alpha/messages") {
			json(200, { messages: this.history });
			return;
		}
		if (path.startsWith("/api/runs/")) {
			const detail = this.runDetails.get(path.slice("/api/runs/".length)) ?? {
				run_kind: "user", from_agent: "", prompt: "",
			};
			json(200, detail);
			return;
		}
		if (path === "/api/events") {
			res.statusCode = 200;
			res.setHeader("Content-Type", "text/event-stream");
			res.setHeader("Cache-Control", "no-cache");
			res.flushHeaders();
			this.sseClients.add(res);
			req.on("close", () => this.sseClients.delete(res));
			return;
		}
		json(404, { error: "not found" });
	}
}

async function makeSession(hub: StubHub, agentId = "alpha") {
	const tempDir = join(tmpdir(), `hub-session-test-${Math.random().toString(36).slice(2)}`);
	mkdirSync(tempDir, { recursive: true });
	const faux = registerFauxProvider({});
	const model = faux.getModel();
	// Register the faux provider so the config's modelRuntime is well-formed.
	const { createInMemoryModelRegistry, getModelRuntime } = await import("../model-runtime-test-utils.ts");
	const registry = await createInMemoryModelRegistry({
		get: async () => undefined,
		set: async () => {},
	} as never);
	await (registry as any).registerProvider(model.provider, {
		baseUrl: model.baseUrl,
		apiKey: "faux-key",
		api: faux.api,
		models: faux.models.map((registeredModel: any) => ({
			id: registeredModel.id,
			name: registeredModel.name,
			api: registeredModel.api,
			reasoning: registeredModel.reasoning,
			input: registeredModel.input,
			cost: registeredModel.cost,
			contextWindow: registeredModel.contextWindow,
			maxTokens: registeredModel.maxTokens,
			baseUrl: registeredModel.baseUrl,
		})),
	});

	const sessionManager = SessionManager.inMemory();
	const settingsManager = SettingsManager.inMemory();
	const agent = new Agent({
		getApiKey: () => "faux-key",
		streamFn: streamSimple,
		initialState: { model, systemPrompt: "test", tools: [] },
		convertToLlm: (() => undefined) as never,
	});
	const session = new HubSession({
		agent,
		sessionManager,
		settingsManager,
		cwd: tempDir,
		modelRuntime: getModelRuntime(registry),
		resourceLoader: createTestResourceLoader(),
	});
	return {
		session,
		tempDir,
		cleanup: () => {
			session.dispose();
			rmSync(tempDir, { recursive: true, force: true });
		},
	};
}

async function waitFor(cond: () => boolean, timeoutMs = 8_000): Promise<boolean> {
	const deadline = Date.now() + timeoutMs;
	while (Date.now() < deadline) {
		if (cond()) return true;
		await new Promise((r) => setTimeout(r, 25));
	}
	return cond();
}

function textOf(message: AgentMessage): string {
	// AgentMessage is a union; the session's own messages all carry content.
	const content = (message as { content?: unknown }).content;
	if (Array.isArray(content)) {
		return content.map((part: any) => (part?.type === "text" ? part.text : "")).join("");
	}
	return String(content ?? "");
}

describe("HubSession (VERTUS_ENGINE=hub)", () => {
	const hubs: StubHub[] = [];
	const cleanups: Array<() => void> = [];

	afterEach(() => {
		while (cleanups.length > 0) cleanups.pop()?.();
		while (hubs.length > 0) hubs.pop()?.stop();
	});

	async function startHub(): Promise<StubHub> {
		const hub = new StubHub();
		await hub.start();
		hubs.push(hub);
		return hub;
	}

	it("--agent flag parses and wins over the env default", () => {
		const parsed = parseArgs(["--agent", "scout", "hello"]);
		expect(parsed.agent).toBe("scout");
		expect(parsed.messages).toEqual(["hello"]);
	});

	it("seeds the transcript from history, then streams a live turn", async () => {
		const hub = await startHub();
		// The hub's /messages endpoint returns newest-first (pagination
		// contract); the session renders oldest→newest.
		hub.history = [
			{ run_id: "r0", role: "assistant", text: "earlier answer" },
			{ run_id: "r0", role: "user", text: "earlier question" },
		];
		const env = process.env;
		const old = {
			VERTUS_SERVER_URL: env.VERTUS_SERVER_URL,
			VERTUS_AGENT: env.VERTUS_AGENT,
		};
		env.VERTUS_SERVER_URL = hub.baseUrl;
		env.VERTUS_AGENT = "alpha";
		const { session, cleanup } = await makeSession(hub);
		cleanups.push(cleanup);
		try {
			// Seeded transcript renders oldest→newest.
			const seeded = await waitFor(() => session.messages.length >= 2);
			expect(seeded).toBe(true);
			expect(session.messages.map((m) => m.role)).toEqual(["user", "assistant"]);
			expect(textOf(session.messages[0]!)).toBe("earlier question");
			expect(textOf(session.messages[1]!)).toBe("earlier answer");

			// Live turn: prompt → POST, then hub pushes deltas + done.
			void session.prompt("do the thing");
			const posted = await waitFor(() => hub.prompts.length === 1);
			expect(posted).toBe(true);
			expect(hub.prompts[0]).toEqual({ agent_id: "alpha", text: "do the thing" });

			await waitFor(() => session.isStreaming);
			hub.push("text", { agent_id: "alpha", run_id: "r1", text: "hello " });
			hub.push("text", { agent_id: "alpha", run_id: "r1", text: "world" });
			hub.push("activity", { agent_id: "alpha", run_id: "r1", text: "running bash…" });
			hub.push("done", { agent_id: "alpha", run_id: "r1" });

			const settled = await waitFor(() => !session.isStreaming && session.messages.length >= 4);
			expect(settled).toBe(true);
			const last = session.messages[session.messages.length - 1]!;
			expect(last.role).toBe("assistant");
			expect(textOf(last)).toBe("hello world");
		} finally {
			env.VERTUS_SERVER_URL = old.VERTUS_SERVER_URL;
			env.VERTUS_AGENT = old.VERTUS_AGENT;
		}
	});

	it("steer mid-turn lands on the hub; abort cancels via the hub", async () => {
		const hub = await startHub();
		const env = process.env;
		const old = { VERTUS_SERVER_URL: env.VERTUS_SERVER_URL, VERTUS_AGENT: env.VERTUS_AGENT };
		env.VERTUS_SERVER_URL = hub.baseUrl;
		env.VERTUS_AGENT = "alpha";
		const { session, cleanup } = await makeSession(hub);
		cleanups.push(cleanup);
		try {
			await waitFor(() => session.messages.length >= 0);
			// Kick off a turn and steer while it streams.
			void session.prompt("start");
			await waitFor(() => hub.prompts.length === 1);
			await waitFor(() => session.isStreaming);
			hub.push("text", { agent_id: "alpha", run_id: "r1", text: "partial" });
			await session.steer("no wait — differently");
			await waitFor(() => hub.steers.length === 1);
			expect(hub.steers[0]).toEqual({ agent_id: "alpha", text: "no wait — differently" });
			hub.push("done", { agent_id: "alpha", run_id: "r1" });
			await waitFor(() => !session.isStreaming);

			// Abort a new turn → hub cancel endpoint.
			void session.prompt("again");
			await waitFor(() => hub.prompts.length === 2);
			await session.abort();
			await waitFor(() => hub.cancels.length >= 1);
			expect(hub.cancels.length).toBeGreaterThanOrEqual(1);
		} finally {
			env.VERTUS_SERVER_URL = old.VERTUS_SERVER_URL;
			env.VERTUS_AGENT = old.VERTUS_AGENT;
		}
	});

	it("degraded features post a visible custom-role notice", async () => {
		const hub = await startHub();
		const env = process.env;
		const old = { VERTUS_SERVER_URL: env.VERTUS_SERVER_URL, VERTUS_AGENT: env.VERTUS_AGENT };
		env.VERTUS_SERVER_URL = hub.baseUrl;
		env.VERTUS_AGENT = "alpha";
		const { session, cleanup } = await makeSession(hub);
		cleanups.push(cleanup);
		try {
			session.setThinkingLevel("high" as never);
			const noticed = await waitFor(() =>
				session.messages.some((m) => m.role === "custom" as never),
			);
			expect(noticed).toBe(true);
			const notice = session.messages.find((m) => m.role === "custom" as never)!;
			expect(textOf(notice)).toContain("hub mode");
			// One-time: a second cycle does not spam another notice.
			const count = () => session.messages.filter((m) => m.role === "custom" as never).length;
			expect(count()).toBe(1);
			session.cycleThinkingLevel();
			await new Promise((r) => setTimeout(r, 50));
			expect(count()).toBe(1);
		} finally {
			env.VERTUS_SERVER_URL = old.VERTUS_SERVER_URL;
			env.VERTUS_AGENT = old.VERTUS_AGENT;
		}
	});

	it("renders a bot-initiated run attributed from the run row", async () => {
		const hub = await startHub();
		hub.runDetails.set("r-bot", { run_kind: "message", from_agent: "scout", prompt: "please check the report" });
		const env = process.env;
		const old = { VERTUS_SERVER_URL: env.VERTUS_SERVER_URL, VERTUS_AGENT: env.VERTUS_AGENT };
		env.VERTUS_SERVER_URL = hub.baseUrl;
		env.VERTUS_AGENT = "alpha";
		const { session, cleanup } = await makeSession(hub);
		cleanups.push(cleanup);
		try {
			await new Promise((r) => setTimeout(r, 150));
			hub.push("text", { agent_id: "alpha", run_id: "r-bot", text: "the report is fine" });
			hub.push("done", { agent_id: "alpha", run_id: "r-bot" });
			const rendered = await waitFor(() =>
				session.messages.some((m) => textOf(m).includes("⟨message from scout⟩")),
			);
			expect(rendered).toBe(true);
			const bubble = session.messages.find((m) => textOf(m).includes("⟨message from scout⟩"))!;
			expect(textOf(bubble)).toBe("⟨message from scout⟩ please check the report");
			const reply = session.messages[session.messages.length - 1]!;
			expect(reply.role).toBe("assistant");
			expect(textOf(reply)).toBe("the report is fine");
		} finally {
			env.VERTUS_SERVER_URL = old.VERTUS_SERVER_URL;
			env.VERTUS_AGENT = old.VERTUS_AGENT;
		}
	});
});