import { mkdir as fsMkdir, readFile as fsReadFile, writeFile as fsWriteFile } from "node:fs/promises";
import { dirname } from "node:path";
import net from "node:net";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { TextContent } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { getExperimentalToolSampling } from "../experimental.ts";
import type { ExtensionContext, ToolDefinition, ToolRenderResultOptions } from "../extensions/types.ts";
import { getTextOutput, str } from "./render-utils.ts";
import { wrapToolDefinition } from "./tool-definition-wrapper.ts";
import { DEFAULT_MAX_BYTES, formatSize, truncateHead } from "./truncate.ts";
import { Text } from "@earendil-works/pi-tui";

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const emailSchema = Type.Object(
	{
		action: Type.Union([
				Type.Literal("connect"),
				Type.Literal("list"),
				Type.Literal("read"),
				Type.Literal("search"),
				Type.Literal("disconnect"),
				Type.Literal("status"),
			]),
		creds_path: Type.Optional(
			Type.String({
				description:
					"Path to the email creds JSON file (default: agent home / email-creds.json). Format: { host, port, user, password, mailbox? }.",
			}),
		),
		mailbox: Type.Optional(
			Type.String({ description: "Mailbox to list/read/search (default: INBOX). Used by list/read/search." }),
		),
		uid: Type.Optional(Type.Number({ description: "Message UID to read (required for action=read)" })),
		uid_valid: Type.Optional(Type.Boolean({ description: "Whether uid is a UIDVALIDITY-stable UID (default true). False uses sequence numbers." })),
		query: Type.Optional(
			Type.Union([
				Type.String({ description: "Search query string passed to IMAP SEARCH (e.g. 'SUBJECT newsletter', 'FROM acme.com', 'SINCE 01-Jan-2026')." }),
				Type.Object({
					subject: Type.Optional(Type.String({ description: "Match messages with this subject substring." })),
					from: Type.Optional(Type.String({ description: "Match messages from this address/substring." })),
					after: Type.Optional(Type.String({ description: "Messages received after this date (DD-Mon-YYYY, e.g. '01-Jan-2026')." })),
					before: Type.Optional(Type.String({ description: "Messages received before this date (DD-Mon-YYYY)." })),								unseen: Type.Optional(Type.Union([Type.Literal(true)], { description: "Only unseen (unread) messages." })),
				}, { description: "Structured search: combine subject/from/after/before/unseen." }),
			]),
		),
		limit: Type.Optional(Type.Number({ description: "Max messages to return for list/search (default 50)." })),
		max_body_bytes: Type.Optional(
			Type.Number({
				description: `Maximum message body bytes to read (default ${DEFAULT_MAX_BYTES}). Larger bodies are truncated and saved to a temp file.`,
			}),
		),
	},
	{ additionalProperties: false },
);

export type EmailToolInput = {
	readonly action: "connect" | "list" | "read" | "search" | "disconnect" | "status";
	readonly creds_path?: string;
	readonly mailbox?: string;
	readonly uid?: number;
	readonly uid_valid?: boolean;
	readonly query?: string | { subject?: string; from?: string; after?: string; before?: string; unseen?: true };
	readonly limit?: number;
	readonly max_body_bytes?: number;
};

export interface EmailToolDetails {
	/** Mailbox name currently selected */
	mailbox?: string;
	/** Total messages in the selected mailbox */
	message_count?: number;
	/** UIDVALIDITY of the selected mailbox (for uid-based reads) */
	uidvalidity?: number;
	/** Temp file path when a body was truncated and saved */
	full_body_path?: string;
	/** Active connection state */
	connected?: boolean;
}

// ---------------------------------------------------------------------------
// IMAP client (lightweight, socket-based, no external dependency)
// ---------------------------------------------------------------------------

interface Creds {
	host: string;
	port: number;
	user: string;
	password: string;
	mailbox?: string;
}

function defaultCredsPath(cwd: string): string {
	// When running as a pi agent, the home dir is the agent's HERMES_HOME.
	// Email creds live alongside auth.json — per-agent, never in memory files.
	return `${cwd}/email-creds.json`;
}

async function loadCreds(credsPath: string, cwd: string): Promise<Creds> {
	const resolved = credsPath ?? defaultCredsPath(cwd);
	try {
		const text = await fsReadFile(resolved, "utf-8");
		const creds = JSON.parse(text) as Creds;
		if (!creds.host || !creds.user || !creds.password) {
			throw new Error(`email creds at ${resolved} missing required fields: host, user, password`);
		}
		return {
			host: creds.host,
			port: creds.port ?? 993,
			user: creds.user,
			password: creds.password,
			mailbox: creds.mailbox ?? "INBOX",
		};
	} catch (error) {
		const message = error instanceof Error ? error.message : String(error);
		throw new Error(`Failed to load email creds from ${resolved}: ${message}`);
	}
}

// A single connection/session. Reused across calls in the same tool lifetime
// so the agent can list → read → search without re-authenticating each time.
let imapSocket: net.Socket | null = null;
let imapConnected = false;
let imapCapabilities: Set<string> | null = null;
let imapUidValidity: number | null = null;
let imapSelectedMailbox: string | null = null;
let imapMessageCount: number | null = null;
let imapError: string | null = null;
let imapLogger: ((msg: string) => void) | null = null;

function setLogger(fn: (msg: string) => void | null) {
	imapLogger = fn;
}

function log(msg: string) {
	if (imapLogger) imapLogger(`[imap] ${msg}`);
}

function raise(msg: string): never {
	imapError = msg;
	throw new Error(msg);
}

function encodeIMAP(s: string): string {
	// IMAP literals: escape NUL and use {len} literal syntax for special chars.
	// For search queries we use the UTF8=ON prefix when available.
	if (/[\x00-\x1f\x7f]/.test(s)) {
		const buf = Buffer.from(s, "utf-8");
		return `{${buf.length}}${buf.toString("binary")}`;
	}
	return s;
}

// IMAP responses are either tagged (A1 OK ...) or untagged (A1 ...). We parse
// line-by-line, handling continuations (the server sends a "continuation" prompt
	// usually "+ " when it expects more data, e.g. for literals).
interface ImapLine {
	tag: string;
	type: "tagged" | "untagged" | "continuation";
	data: string;
}

function parseImapLine(line: string): ImapLine {
	if (line.startsWith("+")) {
		return { tag: "", type: "continuation", data: line.slice(1).trim() };
	}
	const match = line.match(/^([A-Za-z0-9]+) (?:\[([^\]]*)\])? (.*)$/);
	if (match) {
		const type = match[1] === "a000" || line.endsWith(")") ? "tagged" : "untagged";
		return { tag: match[1], type, data: match[3] };
	}
	return { tag: "", type: "untagged", data: line };
}

function waitForTagged(socket: net.Socket, tag: string, timeoutMs: number): Promise<string> {
	return new Promise((resolve, reject) => {
		const timer = setTimeout(() => reject(new Error(`IMAP timeout waiting for ${tag}`)), timeoutMs);
		const onData = (data: Buffer) => {
			const text = data.toString("utf-8");
			const lines = text.split(/\r?\n/);
			for (const line of lines) {
				const trimmed = line.trim();
				if (!trimmed) continue;
				const parsed = parseImapLine(trimmed);
				if (parsed.type === "tagged" && trimmed.startsWith(tag)) {
					clearTimeout(timer);
					socket.off("data", onData);
					resolve(trimmed);
					return;
				}
				// Continuation: we need to send more data. For our simple client
				// we don't send literals in the common path, so continuations
				// indicate something unexpected — log and continue.
				if (parsed.type === "continuation") {
					log(`unexpected continuation: ${trimmed}`);
				}
			}
		};
		socket.on("data", onData);
		socket.on("error", (err) => {
			clearTimeout(timer);
			socket.off("data", onData);
			reject(err);
		});
	});
}


// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export const emailToolSystemPromptContribution = {
	snippet: "Read and search emails via IMAP (connect, list, read, search, disconnect)",
	guidelines: [
		"Use email connect to authenticate and select a mailbox before listing or reading.",
		"Use email list to see recent messages in a mailbox (returns UID, from, subject, date, size).",
		"Use email read with a uid to read a full message (headers + body). Large bodies are truncated and saved to a temp file.",
		"Use email search to find messages by subject, from, date, or unseen status. Returns matching UIDs.",
		"Use email disconnect when done to free the connection.",
		"Unattended runs: if IMAP auth fails, record the creds path and error in memory and continue.",
	],
} as const;

export function createEmailToolDefinition(
	cwd: string,
	_options?: {},
): ToolDefinition<typeof emailSchema, EmailToolDetails | undefined> {
	return {
		name: "email",
		label: "email",
		description: `Read and search emails via IMAP. Actions: connect (authenticate + select mailbox), list (recent messages), read (full message by UID), search (find by subject/from/date/unseen), disconnect, status (connection state).

Email creds are a JSON file (default: agent home / email-creds.json) with { host, port (default 993 for IMAPS), user, password, mailbox? }. Creds live in the agent's engine home — never in the fleet memory files.`,
		promptSnippet: emailToolSystemPromptContribution.snippet,
		promptGuidelines: [...emailToolSystemPromptContribution.guidelines],
		parameters: emailSchema,
		constrainedSampling: getExperimentalToolSampling(),
		executionMode: "sequential",
		async execute(
			_toolCallId,
			input: EmailToolInput,
			signal?: AbortSignal,
			_onUpdate?,
			ctx?: ExtensionContext,
		) {
			// Expose a logger so tests can inspect IMAP traffic.
			setLogger(ctx?.isIdle ? () => null : () => null);

			if (signal?.aborted) throw new Error("Operation aborted");
			if (imapError) throw new Error(imapError);

			const credsPath = input.creds_path;
			const action = input.action;
			const mailbox = input.mailbox ?? "INBOX";
			const uid = input.uid;
			const uidValid = input.uid_valid ?? true;
			const limit = input.limit ?? 50;
			const maxBodyBytes = input.max_body_bytes ?? DEFAULT_MAX_BYTES;

			try {
				switch (action) {
					case "connect": {
						const resolvedCredsPath = credsPath ?? defaultCredsPath(ctx?.cwd ?? cwd);
						const creds = await loadCreds(resolvedCredsPath, ctx?.cwd ?? cwd);
						const timeoutMs = 30_000;
						const socket = net.createConnection({
							host: creds.host,
							port: creds.port,
						});
						imapSocket = socket;
						imapConnected = false;
						imapCapabilities = null;
						imapUidValidity = null;
						imapSelectedMailbox = null;
						imapMessageCount = null;

						return new Promise<{ content: (TextContent)[]; details: EmailToolDetails }>(
							(resolve, reject) => {
								const onError = (err: Error) => {
									reject(new Error(`IMAP connection failed: ${err.message}`));
								};
								socket.on("error", onError);
								socket.on("close", () => {
									if (!imapConnected) {
										reject(new Error("IMAP connection closed before ready"));
									}
								});

								socket.on("data", async (data) => {
									const text = data.toString("utf-8");
									const lines = text.split(/\r?\n/);
									const firstLine = lines.find((l) => l.trim());
									if (!firstLine) return;

									// Server greeting: * OK ...
									if (firstLine.startsWith("* OK") || firstLine.startsWith("* PREAUTH")) {
										log("greeting received");
										try {
											// CAPABILITY
											const capTag = "a000";
											socket.write(`${capTag} CAPABILITY\r\n`);
											const capResponse = await waitForTagged(socket, capTag, timeoutMs);
					const caps: string[] = [];
					for (const line of capResponse.split(/\r?\n/)) {
						const trimmed = line.trim();
						if (trimmed.startsWith("* CAPABILITY")) {
							const parts = trimmed.split(/\s+/);
							for (let i = 1; i < parts.length; i++) {
								if (parts[i]) caps.push(parts[i]);
							}
						}
						if (trimmed.startsWith(capTag) && trimmed.includes("OK")) break;
					}
					imapCapabilities = new Set(caps);
											log(`capabilities: ${caps.join(", ")}`);

											// LOGIN
											const loginTag = "a001";
											const user = creds.user;
											const pass = creds.password;
											// Use LOGIN (not AUTHENTICATE PLAIN) for broadest server support.
											socket.write(`${loginTag} LOGIN ${encodeIMAP(user)} ${encodeIMAP(pass)}\r\n`);
											await waitForTagged(socket, loginTag, timeoutMs);
											imapConnected = true;
											log("logged in");

											// Select mailbox
											const selTag = "a002";
											socket.write(`${selTag} SELECT ${encodeIMAP(mailbox)}\r\n`);
											const selResponse = await waitForTagged(socket, selTag, timeoutMs);
											for (const line of selResponse.split(/\r?\n/)) {
												const trimmed = line.trim();
												const uidMatch = trimmed.match(/^\* OK \[UIDVALIDITY (\d+)\]/);
												if (uidMatch) imapUidValidity = parseInt(uidMatch[1], 10);
												const countMatch = trimmed.match(/^\* (\d+) EXISTS/);
												if (countMatch) imapMessageCount = parseInt(countMatch[1], 10);
												if (trimmed.startsWith(selTag) && trimmed.includes("OK")) break;
											}
											imapSelectedMailbox = mailbox;
											log(`selected ${mailbox}, exists=${imapMessageCount}, uidvalidity=${imapUidValidity}`);

											const details: EmailToolDetails = {
												mailbox,
												message_count: imapMessageCount ?? 0,
												uidvalidity: imapUidValidity ?? 0,
												connected: true,
											};
											resolve({
												content: [{ type: "text", text: `Connected to ${creds.host}:${creds.port}, selected ${mailbox}, ${imapMessageCount ?? 0} messages` }],
												details,
											});
										} catch (err) {
											reject(err instanceof Error ? err : new Error(String(err)));
										}
									}
								});
							},
						);
					}

					case "list": {
						if (!imapConnected) throw new Error("Not connected. Use email connect first.");
						const tag = "a003";
						const sinceDate = input.query && typeof input.query === "object" && input.query.after ? input.query.after : undefined;
						const searchCond =
							sinceDate ? ` SINCE ${sinceDate}` : "";
						// Use FETCH to get summary for recent messages. IMAP LIST gives mailbox names;
						// for message summaries we FETCH FLAGS + UID + INTERNALDATE on a range.
						const endUid = Math.min((imapMessageCount ?? 50) + 1, (imapMessageCount ?? 50) + 100);
						const startUid = Math.max(1, (imapMessageCount ?? 50) - limit + 1);
						// Use UID RANGE FETCH.
						const fetchTag = "a004";
						imapSocket!.write(
							`${fetchTag} FETCH ${startUid}:${endUid} (FLAGS UID INTERNALDATE)\r\n`,
						);
						const fetchResponse = await waitForTagged(imapSocket!, fetchTag, 30_000);
						const messages: { uid: number; from: string; subject: string; date: string; size: number; flags: string[] }[] = [];
						const parsedUids: number[] = [];

						// Parse FETCH responses.
						const lines = fetchResponse.split(/\r?\n/);
						let currentUid: number | null = null;
						let currentFrom = "";
						let currentSubject = "";
						let currentDate = "";
						let currentSize = 0;
						let currentFlags: string[] = [];
						let inFetch = false;

						for (const line of lines) {
							const trimmed = line.trim();
							if (!trimmed) continue;
							const parsed = parseImapLine(trimmed);
							if (parsed.type === "tagged") continue;

							if (trimmed.startsWith("* ")) {
								inFetch = true;
								// * FETCH (UID 123 FLAGS (...) INTERNALDATE ... ENVELOPE ...)
								const fetchMatch = trimmed.match(/^\* (\d+) FETCH \((.*)\)/s);
								if (fetchMatch) {
									const seq = parseInt(fetchMatch[1], 10);
									const parts = fetchMatch[2].split(/\s+/);
									for (const part of parts) {
										if (part === "UID") {
											const uidVal = parseInt(parts[parts.indexOf(part) + 1], 10);
											currentUid = uidVal;
										}
										if (part.startsWith("FLAGS")) {
											currentFlags = [];
											// FLAGS (\Seen \Flagged)
										}
									}
									// Simpler: parse FLAGS, UID, INTERNALDATE via regex.
									const flagsMatch = trimmed.match(/FLAGS \(\(([^)]*)\)\)/);
									if (flagsMatch) {
										currentFlags = flagsMatch[1].split(/\s+/).filter(Boolean);
									}
									const uidMatch = trimmed.match(/UID (\d+)/);
									if (uidMatch) currentUid = parseInt(uidMatch[1], 10);
									const dateMatch = trimmed.match(/INTERNALDATE "([^"]+)"/);
									if (dateMatch) currentDate = dateMatch[1];
									// Size from RFC822.SIZE is in the FETCH response for ENVELOPE.
									const sizeMatch = trimmed.match(/RFC822\.SIZE (\d+)/);
									if (sizeMatch) currentSize = parseInt(sizeMatch[1], 10);

									// Extract from/subject from ENVELOPE if present.
									const envMatch = trimmed.match(/ENVELOPE \(\d+ ((?:\\N)?"([^"]*)"((?:\\N)?\d+)?)/);
									// Simpler: parse ENVELOPE field by field.
									const envelopeFields = trimmed.match(/ENVELOPE \((.*)\)/s);
									if (envelopeFields) {
										// ENVELOPE fields: date, subject, from, sender, reply-to, to, cc, bcc, in-reply-to, message-id
										// We only need subject and from for the list view.
										const env = envelopeFields[1];
										const subjMatch = env.match(/"([^"]*)"/);
										if (subjMatch) currentSubject = subjMatch[1];
									}
					// From is the 3rd field in ENVELOPE — extract the first address.
					const envStr = envelopeFields?.[1];
					const fromMatch = envStr ? envStr.match(/"([^"]*)"/) : undefined;
									// Fallback: try BODY[HEADER.FIELDS] later.
									if (currentUid && !messages.find((m) => m.uid === currentUid)) {
										messages.push({
											uid: currentUid,
											from: currentFrom || "(unknown)",
											subject: currentSubject || "(no subject)",
											date: currentDate || "",
											size: currentSize,
											flags: currentFlags,
										});
										parsedUids.push(currentUid);
									}
								}
							}
						}

						// Sort by uid descending (newest first).
						messages.sort((a, b) => b.uid - a.uid);

						const listText = messages
							.slice(0, limit)
							.map((m) => {
								const flagStr = m.flags.length > 0 ? ` [${m.flags.join(" ")}]` : "";
								return `[${m.uid}]${flagStr} ${m.date} ${m.size}B\n  From: ${m.from}\n  Subject: ${m.subject}`;
							})
							.join("\n\n");

						const summary = messages.length > 0
							? `Listed ${messages.length} recent messages in ${mailbox} (newest first):\n\n${listText}`
							: `No messages in ${mailbox}.`;

						return {
							content: [{ type: "text", text: summary }],
							details: { mailbox, message_count: imapMessageCount ?? 0, uidvalidity: imapUidValidity ?? 0, connected: true },
						};
					}

					case "read": {
						if (!imapConnected) throw new Error("Not connected. Use email connect first.");
						if (uid === undefined) throw new Error("email read requires a uid");
						const tag = "a005";
						const uidCond = uidValid ? `UID ${uid}` : `${uid}`;
						imapSocket!.write(`${tag} FETCH ${uidCond} (RFC822)\r\n`);
						const fetchResponse = await waitForTagged(imapSocket!, tag, 30_000);

						// Collect the RFC822 body across continuation lines.
						let bodyBuffer = "";
						const lines = fetchResponse.split(/\r?\n/);
						let inBody = false;
						for (const line of lines) {
							const trimmed = line.trim();
							if (!trimmed) continue;
							if (trimmed.startsWith("* ")) {
								const fetchMatch = trimmed.match(/^\* (\d+) FETCH \((.*)\)/s);
								if (fetchMatch) {
									const fields = fetchMatch[2];
									if (fields.includes("RFC822")) {
										inBody = true;
									}
								}
							} else if (inBody) {
								bodyBuffer += trimmed + "\n";
							}
						}

						if (!bodyBuffer) {
							return {
								content: [{ type: "text", text: `No message found with uid ${uid}.` }],
								details: { mailbox, message_count: imapMessageCount ?? 0, connected: true },
							};
						}

						// Parse headers + body.
						const headerEnd = bodyBuffer.indexOf("\n\n");
						const headerSection = headerEnd >= 0 ? bodyBuffer.slice(0, headerEnd) : bodyBuffer;
						const bodySection = headerEnd >= 0 ? bodyBuffer.slice(headerEnd + 2) : "";

						const headers: Record<string, string> = {};
						for (const line of headerSection.split(/\r?\n/)) {
							const hMatch = line.match(/^([^:]+): (.+)/);
							if (hMatch) {
								headers[hMatch[1].toLowerCase()] = hMatch[2].trim();
							}
						}

						const subject = headers["subject"] ?? "(no subject)";
						const from = headers["from"] ?? "(unknown)";
						const date = headers["date"] ?? "";
						const to = headers["to"] ?? "";
						const contentType = headers["content-type"] ?? "";

						let bodyText = bodySection;
						// Try to extract text/plain from multipart.
						if (contentType.includes("multipart")) {
							const plainMatch = bodySection.match(/--=[^\n]*\nContent-Type: text\/plain[^\n]*\n\n([\s\S]*?)(?:\n--|=$)/);
							if (plainMatch) bodyText = plainMatch[1];
						}

						const totalBytes = Buffer.byteLength(bodyText, "utf-8");
						const truncatedBody = truncateHead(bodyText, { maxBytes: maxBodyBytes });
						let savedPath: string | undefined;
						if (truncatedBody.truncated && totalBytes > 0) {
							savedPath = `/tmp/vertus-email-${Date.now()}.body`;
							await fsMkdir(dirname(savedPath), { recursive: true });
							await fsWriteFile(savedPath, bodyText);
						}

						const bodyPreview = truncatedBody.content;
						const headerSummary = [
							`Message ${uid}`,
							`From: ${from}`,
							`Date: ${date}`,
							`To: ${to}`,
							`Subject: ${subject}`,
							`Size: ${totalBytes}B` + (savedPath ? `\nFull body saved to ${savedPath} (truncated)` : ""),
						].join("\n");

						const text = `${headerSummary}\n\n---\n${bodyPreview}` + (savedPath ? `\n\n[Full body truncated to ${formatSize(maxBodyBytes)}. Read ${savedPath} for the full message.]` : "");

						return {
							content: [{ type: "text", text }],
							details: { mailbox, message_count: imapMessageCount ?? 0, uidvalidity: imapUidValidity ?? 0, full_body_path: savedPath, connected: true },
						};
					}

					case "search": {
						if (!imapConnected) throw new Error("Not connected. Use email connect first.");
						const tag = "a006";

						// Build IMAP SEARCH command from the query.
						let searchCmd = "SEARCH";
						if (input.query) {
							if (typeof input.query === "string") {
								searchCmd += ` ${input.query}`;
							} else {
								const q = input.query;
								const parts: string[] = [];
								if (q.subject)
									parts.push(`SUBJECT ${encodeIMAP(q.subject)}`);
								if (q.from)
									parts.push(`FROM ${encodeIMAP(q.from)}`);
								if (q.after)
									parts.push(`SINCE ${q.after}`);
								if (q.before)
									parts.push(`BEFORE ${q.before}`);
								if (q.unseen)
									parts.push("UNSEEN");
								if (parts.length > 0) searchCmd += ` ${parts.join(" ")}`;
								else searchCmd += " ALL";
							}
						} else {
							searchCmd += " ALL";
						}

						imapSocket!.write(`${tag} ${searchCmd}\r\n`);
						const searchResponse = await waitForTagged(imapSocket!, tag, 30_000);

						const uids: number[] = [];
						for (const line of searchResponse.split(/\r?\n/)) {
							const trimmed = line.trim();
							if (trimmed.startsWith("* ")) {
								const searchMatch = trimmed.match(/^\* SEARCH (.+)/);
							if (searchMatch) {
								const nums = searchMatch[1].split(/\s+/).filter((n) => /^\d+$/.test(n));
								for (const n of nums) uids.push(parseInt(n, 10));
							}
							}
						}

						// Deduplicate and sort descending.
						const uniqueUids = [...new Set(uids)].sort((a, b) => b - a);
						const summary =
							uniqueUids.length > 0
								? `Found ${uniqueUids.length} messages${input.query ? ` matching the query` : ""}:\n\n${uniqueUids.slice(0, limit).map((u) => `[${u}]`).join("\n")}`
								: "No matching messages found.";

						return {
							content: [{ type: "text", text: summary }],
							details: { mailbox, message_count: imapMessageCount ?? 0, uidvalidity: imapUidValidity ?? 0, connected: true },
						};
					}

					case "disconnect": {
						if (imapSocket) {
							try { imapSocket.end(); } catch {}
							imapSocket = null;
						}
						imapConnected = false;
						imapUidValidity = null;
						imapSelectedMailbox = null;
						imapMessageCount = null;
						imapCapabilities = null;
						return {
							content: [{ type: "text", text: "Disconnected from IMAP server." }],
							details: { connected: false },
						};
					}

					case "status": {
						return {
							content: [{ type: "text", text: `IMAP status:\n  Connected: ${imapConnected}\n  Mailbox: ${imapSelectedMailbox ?? "none"}\n  Messages: ${imapMessageCount ?? 0}\n  UIDVALIDITY: ${imapUidValidity ?? "none"}\n  Capabilities: ${imapCapabilities ? [...imapCapabilities].join(", ") : "none"}${imapError ? `\n  Error: ${imapError}` : ""}` }],
							details: {
								mailbox: imapSelectedMailbox ?? undefined,
								message_count: imapMessageCount ?? undefined,
								uidvalidity: imapUidValidity ?? undefined,
								connected: imapConnected,
							},
						};
					}

					default:
						throw new Error(`Unknown email action: ${action}`);
				}
			} catch (error) {
				const message = error instanceof Error ? error.message : String(error);
				imapError = message;
				return {
					content: [{ type: "text", text: `email ${action} failed: ${message}` }],
					details: { connected: imapConnected, mailbox: imapSelectedMailbox ?? undefined },
				};
			}
		},
		renderCall(args, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const action = str(args?.action);
			const label = action === "read" ? `email read uid=${str(args?.uid)}` : action === "search" ? `email search …` : `email ${action}`;
			text.setText(theme.fg("toolTitle", theme.bold(label)));
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

export function createEmailTool(cwd: string, options?: {}): AgentTool<typeof emailSchema> {
	return wrapToolDefinition(createEmailToolDefinition(cwd, options));
}
