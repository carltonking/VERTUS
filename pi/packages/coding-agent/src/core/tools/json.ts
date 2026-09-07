import { mkdir as fsMkdir, readFile as fsReadFile, writeFile as fsWriteFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { TextContent } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { getExperimentalToolSampling } from "../experimental.ts";
import type { ExtensionContext, ToolDefinition } from "../extensions/types.ts";
import { getTextOutput, str } from "./render-utils.ts";
import { wrapToolDefinition } from "./tool-definition-wrapper.ts";
import { Text } from "@earendil-works/pi-tui";

// ---------------------------------------------------------------------------
// Schema
// ---------------------------------------------------------------------------

const jsonSchema = Type.Object(
	{
		action: Type.Union([
			Type.Literal("read"),
			Type.Literal("write"),
			Type.Literal("get"),
			Type.Literal("set"),
			Type.Literal("delete"),
		]),
		file: Type.Optional(
			Type.String({
				description: "JSON file path (default: agent home / data.json). Used by read, write, get, set, delete.",
			}),
		),
		data: Type.Optional(
			Type.Union([
				Type.Object({}, { description: "JSON object to write" }),
				Type.Array(Type.Any(), { description: "JSON array to write" }),
				Type.String({ description: "JSON string to parse and write" }),
				Type.Number({ description: "Numeric value to write" }),
				Type.Boolean({ description: "Boolean value to write" }),
				Type.Null({ description: "Null value to write" }),
			]),
		),
		key: Type.Optional(
			Type.String({
				description: "Key to get/set/delete within the JSON object (dot notation for nested: 'user.settings.theme').",
			}),
		),
	},
	{ additionalProperties: false },
);

export type JsonToolInput = {
	readonly action: "read" | "write" | "get" | "set" | "delete";
	readonly file?: string;
	readonly data?: unknown;
	readonly key?: string;
};

export interface JsonToolDetails {
	file?: string;
	value?: unknown;
}

const DEFAULT_JSON_FILE = "data.json";

// ---------------------------------------------------------------------------
// Tool definition
// ---------------------------------------------------------------------------

export const jsonToolSystemPromptContribution = {
	snippet: "Read and write JSON data files — persistent structured data storage",
	guidelines: [
		"Use json write to save structured data (settings, results, state) to a JSON file.",
		"Use json read to load a JSON file and see its contents.",
		"Use json get with a key (dot notation for nested) to read one value from a JSON object.",
		"Use json set to update one key in a JSON file without rewriting the whole thing.",
		"Use json delete to remove a key from a JSON object.",
		"Good for: saving settings the agent configured, persisting results across runs, maintaining a simple key-value store.",
	],
} as const;

function getNestedValue(obj: unknown, path: string): unknown {
	const parts = path.split(".");
	let current: unknown = obj;
	for (const part of parts) {
		if (current && typeof current === "object" && part in current) {
			current = (current as Record<string, unknown>)[part];
		} else {
			return undefined;
		}
	}
	return current;
}

function setNestedValue(obj: Record<string, unknown>, path: string, value: unknown): Record<string, unknown> {
	const parts = path.split(".");
	let current: Record<string, unknown> = obj;
	for (let i = 0; i < parts.length - 1; i++) {
		const part = parts[i];
		if (!(part in current) || typeof current[part] !== "object" || current[part] === null) {
			current[part] = {};
		}
		current = current[part] as Record<string, unknown>;
	}
	current[parts[parts.length - 1]] = value;
	return obj;
}

function deleteNestedKey(obj: Record<string, unknown>, path: string): Record<string, unknown> {
	const parts = path.split(".");
	let current: Record<string, unknown> = obj;
	for (let i = 0; i < parts.length - 1; i++) {
		const part = parts[i];
		if (!(part in current) || typeof current[part] !== "object" || current[part] === null) {
			return obj;
		}
		current = current[part] as Record<string, unknown>;
	}
	delete current[parts[parts.length - 1]];
	return obj;
}

export function createJsonToolDefinition(
	cwd: string,
	_options?: {},
): ToolDefinition<typeof jsonSchema, JsonToolDetails | undefined> {
	return {
		name: "json",
		label: "json",
		description: `Read and write JSON data files for structured persistent storage. Actions: read (load full file), write (save data to file), get (read one value by key, dot notation for nested), set (update one key), delete (remove a key).

Default file: agent home / data.json. Use when you need to persist structured data across turns — settings, results, state, a simple key-value store.`,
		promptSnippet: jsonToolSystemPromptContribution.snippet,
		promptGuidelines: [...jsonToolSystemPromptContribution.guidelines],
		parameters: jsonSchema,
		constrainedSampling: getExperimentalToolSampling(),
		executionMode: "sequential",
		async execute(
			_toolCallId,
			{ action, file, data, key }: JsonToolInput,
			_signal?: AbortSignal,
			_onUpdate?: never,
			ctx?: ExtensionContext,
		) {
			const jsonPath = file ?? `${ctx?.cwd ?? cwd}/${DEFAULT_JSON_FILE}`;

			switch (action) {
				case "read": {
					try {
						const raw = await fsReadFile(jsonPath, "utf-8");
						const parsed = JSON.parse(raw);
						const pretty = JSON.stringify(parsed, null, 2);
						return {
							content: [{ type: "text", text: `${jsonPath}:\n\n${pretty}` }],
							details: { file: jsonPath },
						};
					} catch {
						return {
							content: [{ type: "text", text: `No JSON file at ${jsonPath}` }],
							details: { file: jsonPath },
						};
					}
				}
				case "write": {
					await fsMkdir(dirname(jsonPath), { recursive: true });
					let payload: unknown = data;
					if (typeof data === "string") {
						try {
							payload = JSON.parse(data);
						} catch {
							payload = data;
						}
					}
					await fsWriteFile(jsonPath, JSON.stringify(payload, null, 2));
					return {
						content: [{ type: "text", text: `Wrote ${jsonPath}` }],
						details: { file: jsonPath },
					};
				}
				case "get": {
					try {
						const raw = await fsReadFile(jsonPath, "utf-8");
						const parsed = JSON.parse(raw);
						if (!key) {
							return {
								content: [{ type: "text", text: `${jsonPath}:\n\n${JSON.stringify(parsed, null, 2)}` }],
								details: { file: jsonPath, value: parsed },
							};
						}
						const value = getNestedValue(parsed, key);
						if (value === undefined) {
							return {
								content: [{ type: "text", text: `Key not found: ${key}` }],
								details: { file: jsonPath, value: undefined },
							};
						}
						return {
							content: [{ type: "text", text: `${jsonPath}.${key} = ${JSON.stringify(value)}` }],
							details: { file: jsonPath, value },
						};
					} catch {
						return {
							content: [{ type: "text", text: `No JSON file at ${jsonPath}` }],
							details: { file: jsonPath },
						};
					}
				}
				case "set": {
					try {
						const raw = await fsReadFile(jsonPath, "utf-8");
						const parsed = JSON.parse(raw);
						if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
							throw new Error("json set requires an object at the root");
						}
						const obj = parsed as Record<string, unknown>;
						if (!key) throw new Error("json set requires a key");
						const updated = setNestedValue(obj, key, data);
						await fsWriteFile(jsonPath, JSON.stringify(updated, null, 2));
						return {
							content: [{ type: "text", text: `Set ${jsonPath}.${key}` }],
							details: { file: jsonPath },
						};
					} catch (err) {
						const message = err instanceof Error ? err.message : String(err);
						return {
							content: [{ type: "text", text: `json set failed: ${message}` }],
							details: { file: jsonPath },
						};
					}
				}
				case "delete": {
					try {
						const raw = await fsReadFile(jsonPath, "utf-8");
						const parsed = JSON.parse(raw);
						if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
							throw new Error("json delete requires an object at the root");
						}
						const obj = parsed as Record<string, unknown>;
						if (!key) throw new Error("json delete requires a key");
						const updated = deleteNestedKey(obj, key);
						await fsWriteFile(jsonPath, JSON.stringify(updated, null, 2));
						return {
							content: [{ type: "text", text: `Deleted ${jsonPath}.${key}` }],
							details: { file: jsonPath },
						};
					} catch (err) {
						const message = err instanceof Error ? err.message : String(err);
						return {
							content: [{ type: "text", text: `json delete failed: ${message}` }],
							details: { file: jsonPath },
						};
					}
				}
				default:
					throw new Error(`Unknown json action: ${action}`);
			}
		},
		renderCall(args, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const action = str(args?.action);
			const label =
				action === "get" ? `json get ${str(args?.key)}` : action === "set" ? `json set ${str(args?.key)}` : `json ${action}`;
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

export function createJsonTool(cwd: string, options?: {}): AgentTool<typeof jsonSchema> {
	return wrapToolDefinition(createJsonToolDefinition(cwd, options));
}
