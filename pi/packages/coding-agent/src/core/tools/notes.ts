import { mkdir as fsMkdir, readFile as fsReadFile, writeFile as fsWriteFile, appendFile as fsAppendFile } from "node:fs/promises";
import { dirname } from "node:path";
import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { TextContent } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { getExperimentalToolSampling } from "../experimental.ts";
import type { ExtensionContext, ToolDefinition } from "../extensions/types.ts";
import { getTextOutput, str } from "./render-utils.ts";
import { wrapToolDefinition } from "./tool-definition-wrapper.ts";
import { Text } from "@earendil-works/pi-tui";

const notesSchema = Type.Object(
	{
		action: Type.Union([
			Type.Literal("append"),
			Type.Literal("read"),
			Type.Literal("list"),
			Type.Literal("clear"),
		]),
		text: Type.Optional(Type.String({ description: "Text to append (required for action=append)" })),
		file: Type.Optional(
			Type.String({
				description: "Notes file path (default: agent home / notes.md). Used by append, read, clear.",
			}),
		),
	},
	{ additionalProperties: false },
);

export type NotesToolInput = {
	readonly action: "append" | "read" | "list" | "clear";
	readonly text?: string;
	readonly file?: string;
};

export interface NotesToolDetails {
	file?: string;
	line_count?: number;
}

const DEFAULT_NOTES_FILE = "notes.md";

export const notesToolSystemPromptContribution = {
	snippet: "Capture text snippets to a notes file — append, read, list, clear",
	guidelines: [
		"Use notes append to save a snippet, observation, or result for later reference.",
		"Use notes read to review what you've saved.",
		"Use notes list to quickly scan recent notes (last 20 lines).",
		"Use notes clear to start fresh when the notes file gets too long.",
		"Notes persist across turns in the same session — use them to remember intermediate results.",
	],
} as const;

export function createNotesToolDefinition(
	cwd: string,
	_options?: {},
): ToolDefinition<typeof notesSchema, NotesToolDetails | undefined> {
	return {
		name: "notes",
		label: "notes",
		description: `Capture and review text snippets in a notes file. Actions: append (add text to notes.md), read (read the full file), list (show last 20 lines), clear (empty the file).

Default file: agent home / notes.md. Use when you need to remember intermediate results across turns.`,
		promptSnippet: notesToolSystemPromptContribution.snippet,
		promptGuidelines: [...notesToolSystemPromptContribution.guidelines],
		parameters: notesSchema,
		constrainedSampling: getExperimentalToolSampling(),
		executionMode: "sequential",
		async execute(
			_toolCallId,
			{ action, text, file }: NotesToolInput,
			_signal?: AbortSignal,
			_onUpdate?: never,
			ctx?: ExtensionContext,
		) {
			const notesPath = file ?? `${ctx?.cwd ?? cwd}/${DEFAULT_NOTES_FILE}`;

			switch (action) {
				case "append": {
					if (!text) throw new Error("notes append requires text");
					await fsMkdir(dirname(notesPath), { recursive: true });
					const timestamp = new Date().toISOString();
					await fsAppendFile(notesPath, `\n## ${timestamp}\n${text}\n`);
					const content = await fsReadFile(notesPath, "utf-8");
					const lineCount = content.split("\n").length;
					return {
						content: [{ type: "text", text: `Appended to ${notesPath}` }],
						details: { file: notesPath, line_count: lineCount },
					};
				}
				case "read": {
					try {
						const content = await fsReadFile(notesPath, "utf-8");
						const lineCount = content.split("\n").length;
						return {
							content: [{ type: "text", text: `notes.md:\n\n${content || "(empty)"}` }],
							details: { file: notesPath, line_count: lineCount },
						};
					} catch {
						return {
							content: [{ type: "text", text: `No notes file at ${notesPath}` }],
							details: { file: notesPath, line_count: 0 },
						};
					}
				}
				case "list": {
					try {
						const content = await fsReadFile(notesPath, "utf-8");
						const lines = content.split("\n");
						const recent = lines.slice(-20).join("\n");
						const totalLines = lines.length;
						return {
							content: [{ type: "text", text: `notes.md (${totalLines} lines, showing last 20):\n\n${recent || "(empty)"}` }],
							details: { file: notesPath, line_count: totalLines },
						};
					} catch {
						return {
							content: [{ type: "text", text: `No notes file at ${notesPath}` }],
							details: { file: notesPath, line_count: 0 },
						};
					}
				}
				case "clear": {
					await fsMkdir(dirname(notesPath), { recursive: true });
					await fsWriteFile(notesPath, "# Notes\n");
					return {
						content: [{ type: "text", text: `Cleared ${notesPath}` }],
						details: { file: notesPath, line_count: 1 },
					};
				}
				default:
					throw new Error(`Unknown notes action: ${action}`);
			}
		},
		renderCall(args, theme, context) {
			const text = (context.lastComponent as Text | undefined) ?? new Text("", 0, 0);
			const action = str(args?.action);
			const label =
				action === "append" ? `notes append …` : action === "read" ? `notes read` : `notes ${action}`;
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

export function createNotesTool(cwd: string, options?: {}): AgentTool<typeof notesSchema> {
	return wrapToolDefinition(createNotesToolDefinition(cwd, options));
}
