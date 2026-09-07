import type { AgentTool } from "@earendil-works/pi-agent-core";
import type { TextContent } from "@earendil-works/pi-ai";
import { Type } from "typebox";
import { getExperimentalToolSampling } from "../experimental.ts";
import type { ExtensionContext, ToolDefinition } from "../extensions/types.ts";
import { getTextOutput, str } from "./render-utils.ts";
import { wrapToolDefinition } from "./tool-definition-wrapper.ts";
import { Text } from "@earendil-works/pi-tui";
import { mkdir as fsMkdir, appendFile as fsAppendFile } from "node:fs/promises";
import { dirname } from "node:path";

const logSchema = Type.Object(
	{
		action: Type.Literal("append"),
		message: Type.String({ description: "Message to log" }),
		file: Type.Optional(
			Type.String({
				description: "Log file path (default: agent home / activity.log).",
			}),
		),
		level: Type.Optional(
			Type.Union([
				Type.Literal("info"),
				Type.Literal("warn"),
				Type.Literal("error"),
				Type.Literal("debug"),
			]),
		),
	},
	{ additionalProperties: false },
);

export type LogToolInput = {
	readonly action: "append";
	readonly message: string;
	readonly file?: string;
	readonly level?: "info" | "warn" | "error" | "debug";
};

export interface LogToolDetails {
	file?: string;
}

const DEFAULT_LOG_FILE = "activity.log";

export const logToolSystemPromptContribution = {
	snippet: "Append timestamped log entries for activity tracking and audit trails",
	guidelines: [
		"Use log append to record what you did, a decision you made, or a result you got.",
		"Use level=error for failures, level=warn for notable events, level=info for routine progress, level=debug for detail.",
		"Good for: activity logs, progress tracking, audit trails, debugging unattended runs.",
		"Logs are append-only — each entry gets a timestamp. Use notes for editable scratchpads; use log for immutable records.",
	],
} as const;

export function createLogToolDefinition(
	cwd: string,
	_options?: {},
): ToolDefinition<typeof logSchema, LogToolDetails | undefined> {
	return {
		name: "log",
		label: "log",
		description: `Append timestamped log entries to a log file. Use for activity tracking, audit trails, and progress records.

Default file: agent home / activity.log. Each entry gets: [timestamp] [LEVEL] message.`,
		promptSnippet: logToolSystemPromptContribution.snippet,
		promptGuidelines: [...logToolSystemPromptContribution.guidelines],
		parameters: logSchema,
		constrainedSampling: getExperimentalToolSampling(),
		executionMode: "sequential",
		async execute(
			_toolCallId,
			{ message, file, level }: LogToolInput,
			_signal?: AbortSignal,
			_onUpdate?: never,
			ctx?: ExtensionContext,
		) {
			const logPath = file ?? `${ctx?.cwd ?? cwd}/${DEFAULT_LOG_FILE}`;
			await fsMkdir(dirname(logPath), { recursive: true });
			const timestamp = new Date().toISOString();
			const levelStr = level ?? "info";
			const entry = `[${timestamp}] [${levelStr.toUpperCase()}] ${message}\n`;
			await fsAppendFile(logPath, entry);
			return {
				content: [{ type: "text", text: `[${levelStr.toUpperCase()}] ${message}` }],
				details: { file: logPath },
			};
		},
		renderCall(args, theme, context) {
			const text = context.lastComponent !== undefined && context.lastComponent !== null ? (context.lastComponent as unknown as Text) : new Text("", 0, 0);
			const level = str(args?.level ?? "info");
			const preview = str(args?.message).slice(0, 50);
			try { text.setText(theme.fg("toolTitle", theme.bold(`log [${level}] ${preview}${str(args?.message).length > 50 ? "…" : ""}`))); } catch {}
			return text;
		},
		renderResult(result, options, theme, context) {
			const text = context.lastComponent !== undefined && context.lastComponent !== null ? (context.lastComponent as unknown as Text) : new Text("", 0, 0);
			const output = getTextOutput(result, false);
			if (!options.expanded && !context.isError) {
				try { text.setText(""); } catch {}
			} else {
				try { text.setText(output); } catch {}
			}
			return text;
		},
	};
}

export function createLogTool(cwd: string, options?: {}): AgentTool<typeof logSchema> {
	return wrapToolDefinition(createLogToolDefinition(cwd, options));
}
