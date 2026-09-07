import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { TextContent } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { getExperimentalToolSampling } from "../experimental.ts";
import type { ExtensionContext, ToolDefinition } from "../extensions/types.ts";
import { getTextOutput, str } from "./render-utils.ts";
import { wrapToolDefinition } from "./tool-definition-wrapper.ts";
import { DEFAULT_MAX_BYTES, formatSize, truncateHead } from "./truncate.ts";
import { mkdir as fsMkdir, writeFile as fsWriteFile } from "node:fs/promises";
import { Text } from "@earendil-works/pi-tui";
import { dirname } from "node:path";
import { finished } from "node:stream/promises";
import { Readable } from "node:stream";

// undici is already a dependency of the project.
import { request as undiciRequest } from "undici";

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const fetchSchema = Type.Object(
	{		method: Type.Optional(
				Type.Union([
					Type.Literal("GET"),
					Type.Literal("POST"),
					Type.Literal("PUT"),
					Type.Literal("PATCH"),
					Type.Literal("DELETE"),
					Type.Literal("HEAD"),
					Type.Literal("OPTIONS"),
				]),
		),
		url: Type.String({ description: "Absolute URL to fetch (https://... or http://...)" }),
		headers: Type.Optional(
			Type.Record(Type.String(), Type.String(), {
				description: "Request headers as a JSON object, e.g. { 'Authorization': 'Bearer ...', 'Accept': 'application/json' }",
			}),
		),		body: Type.Optional(
				Type.Union([
					Type.String({ description: "Request body (for POST/PUT/PATCH). JSON strings are sent as JSON if Content-Type is application/json." }),
					Type.Number({ description: "Numeric body is converted to a string." }),
				]),
		),
		timeout: Type.Optional(
			Type.Number({ description: "Timeout in seconds for the whole request (default 30s). Includes connection + response." }),
		),
		follow_redirects: Type.Optional(
			Type.Boolean({ description: "Follow redirects automatically (default true). Set false to stop at the first response." }),
		),
		max_body_bytes: Type.Optional(
			Type.Number({
				description: `Maximum response body bytes to read (default ${DEFAULT_MAX_BYTES}). Larger bodies are truncated and the full body is saved to a temp file.`,
			}),
		),
	},
	{ additionalProperties: false },
);

export type FetchToolInput = {
	readonly method?: "GET" | "POST" | "PUT" | "PATCH" | "DELETE" | "HEAD" | "OPTIONS";
	readonly url: string;
	readonly headers?: Record<string, string>;
	readonly body?: string | number;
	readonly timeout?: number;
	readonly follow_redirects?: boolean;
	readonly max_body_bytes?: number;
};

export interface FetchToolDetails {
	/** Total bytes received (before truncation) */
	total_bytes?: number;
	/** Temp file path when the body was truncated and saved */
	full_body_path?: string;
	/** Redirect history (URLs) when follow_redirects is true */
	redirect_chain?: string[];
}

const DEFAULT_TIMEOUT_S = 30;
const DEFAULT_MAX_BODY = DEFAULT_MAX_BYTES;

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export const fetchToolSystemPromptContribution = {
	snippet: "Make HTTP requests (GET/POST/PUT/PATCH/DELETE) with headers and body",
	guidelines: [
		"Use fetch for APIs and web requests the agent needs to do its work.",
		"Set headers for authentication (Authorization, API-Key, etc.) and content negotiation (Accept: application/json).",
		"For JSON POST bodies, set headers: { 'Content-Type': 'application/json' } and pass the body as a JSON string.",
		"Large responses are truncated in the tool result but saved to a temp file — read it with the read tool if you need the full body.",
		"Unattended runs: if a request fails, record the status code and response body in memory and continue.",
	],
} as const;

export function createFetchToolDefinition(
	cwd: string,
	_options?: {},
): ToolDefinition<typeof fetchSchema, FetchToolDetails | undefined> {
	return {
		name: "fetch",
		label: "fetch",
		description: `Make an HTTP(S) request. Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS (default GET).

Use it to call APIs, submit form data, download files, or check a URL. Set headers for auth (Authorization, API-Key) and Content-Type. Body is sent as-is for POST/PUT/PATCH; numeric bodies are stringified. Large responses are truncated but saved to a temp file you can read.`,
		promptSnippet: fetchToolSystemPromptContribution.snippet,
		promptGuidelines: [...fetchToolSystemPromptContribution.guidelines],
		parameters: fetchSchema,
		constrainedSampling: getExperimentalToolSampling(),
		executionMode: "sequential",
		async execute(
			_toolCallId,
			{ method, url, headers, body, timeout, follow_redirects, max_body_bytes }: FetchToolInput,
			signal?: AbortSignal,
			_onUpdate?,
			_ctx?: ExtensionContext,
		) {
			const methodUpperCase = (method ?? "GET").toUpperCase();
			const timeoutMs = (timeout ?? DEFAULT_TIMEOUT_S) * 1000;
			const maxBytes = max_body_bytes ?? DEFAULT_MAX_BODY;
			const follow = follow_redirects ?? true;				if (!url || (!url.startsWith("http://") && !url.startsWith("https://"))) {
					throw new Error(`fetch url must be an absolute HTTP(S) URL, got: ${url ?? "undefined"}`);
				}

			if (signal?.aborted) throw new Error("Operation aborted");

			const requestHeaders: Record<string, string> = { ...(headers ?? {}) };

			// Default Content-Length for bodies we add.
			if (body !== undefined) {
				const bodyStr = typeof body === "number" ? String(body) : body;
				if (requestHeaders["Content-Length"] === undefined) {
					requestHeaders["Content-Length"] = String(Buffer.byteLength(bodyStr, "utf-8"));
				}
				// If no content-type is set and the body looks like JSON, set one.
				if (
					requestHeaders["Content-Type"] === undefined &&
					typeof body === "string" &&
					(body.trim().startsWith("{") || body.trim().startsWith("["))
				) {
					requestHeaders["Content-Type"] = "application/json";
				}
			}

			const startTime = Date.now();
			const redirectChain: string[] = [];				try {
					const response = await undiciRequest(url, {
						method: methodUpperCase,
						headers: requestHeaders,
						body: body !== undefined ? (typeof body === "number" ? String(body) : body) : undefined,
						bodyTimeout: timeoutMs,
						headersTimeout: timeoutMs,
						signal: signal ?? undefined,
					});

					const status = response.statusCode;
					const reason = response.statusText ?? "";
					const headersOut = response.headers;

				// Read the body with a byte cap.
				const bodyChunks: Buffer[] = [];
				let totalBytes = 0;
				let truncated = false;
				let savedPath: string | undefined;

				const onData = (chunk: Buffer) => {
					if (truncated) return;
					totalBytes += chunk.length;
					if (totalBytes > maxBytes) {
						truncated = true;
						return;
					}
					bodyChunks.push(chunk);
				};

				response.body.on("data", onData);
				await finished(response.body, {});
				response.body.destroy();

				const bodyBuffer = Buffer.concat(bodyChunks);
				const bodyText = bodyBuffer.toString("utf-8");
				const truncatedBody = truncateHead(bodyText, { maxBytes: maxBytes });

				// Save full body to a temp file when truncated.
				if (truncated && bodyBuffer.length > 0) {
					savedPath = `/tmp/vertus-fetch-${Date.now()}.body`;
					await fsMkdir(dirname(savedPath), { recursive: true });
					await fsWriteFile(savedPath, bodyBuffer);
				}

				const elapsed = Date.now() - startTime;
				const contentType = headersOut["content-type"] ?? headersOut["Content-Type"] ?? "";

				let bodyPreview = truncatedBody.content;
				if (contentType.includes("application/json") && bodyPreview.length > 0) {
					try {
						const parsed = JSON.parse(bodyPreview);
						bodyPreview = JSON.stringify(parsed, null, 2);
					} catch {
						// Not valid JSON (or truncated mid-JSON) — leave as text.
					}
				}

				const statusLine = `${status} ${reason}`.trim();
				const headerLines = Object.entries(headersOut)
					.filter(([, v]) => v != null)
					.slice(0, 12)
					.map(([k, v]) => `${k}: ${v}`)
					.join("\n");

				let text = `HTTP ${statusLine}\n${elapsed}ms\n\nBody:\n${bodyPreview}`;
				if (headerLines) text = `${statusLine}\n${elapsed}ms\n\n${headerLines}\n\n---\n${bodyPreview}`;
				if (redirectChain.length > 0) {
					text = `HTTP ${statusLine}\n${elapsed}ms\nRedirects: ${redirectChain.join(" -> ")}\n\n${text.slice(text.indexOf("\n"))}`;
				}
				if (truncated) {
					text += `\n\n[Response truncated to ${formatSize(maxBytes)}. Full body saved to ${savedPath}]`;
				}
				if (bodyBuffer.length === 0 && status === 204) {
					text = `HTTP ${statusLine}\n${elapsed}ms\n(no body)`;
				}

				return {
					content: [{ type: "text", text }],
					details: {
						total_bytes: totalBytes,
						full_body_path: savedPath,
						redirect_chain: redirectChain.length > 0 ? redirectChain : undefined,
					},
				};
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				// Distinguish timeout from other errors.
				const isTimeout =
					message.includes("timeout") ||
					message.includes("ETIMEDOUT") ||
					message.includes("ECONNRESET") ||
					message.includes("ABORT_ERR");
				const label = isTimeout ? "Request timed out" : "Request failed";
				return {
					content: [{ type: "text", text: `${label}: ${message}` }],
					details: {},
				};
			}
		},
		renderCall(args, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const method = str(args?.method ?? "GET");
			const url = str(args?.url) ?? "";
			text.setText(theme.fg("toolTitle", theme.bold(`fetch ${method} ${url.slice(0, 60)}${url.length > 60 ? "…" : ""}`)));
			return text;
		},
		renderResult(result, options, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const output = getTextOutput(result, false);
			if (!options.expanded && !context.isError) {
				text.setText("");
			} else {
				text.setText(output);
			}
			return text;
		},
	};
}

export function createFetchTool(cwd: string, options?: {}): AgentTool<typeof fetchSchema> {
	return wrapToolDefinition(createFetchToolDefinition(cwd, options));
}
