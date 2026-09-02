/**
 * ALFRED — Remote Approval Guard
 *
 * Blocks destructive bash commands when the request originates from a
 * non-local client (phone / remote tailnet peer). Local (CLI / quick
 * bar on the same machine) requests run trusted.
 *
 * The server sets ALFRED_REMOTE=1 when the prompt comes from a
 * non-local client; this extension reads it.
 *
 * Uses pi's `tool_call` event (ToolCallEventResult: { block, reason }).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const DESTRUCTIVE_PATTERNS: RegExp[] = [
	/\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*|--recursive)\b/i,
	/\b(mkfs|dd\s+if=|shutdown|reboot|halt)\b/i,
	/\bgit\s+push\b/i,
	/\b(drop|truncate)\s+(table|database)\b/i,
	/\bcurl\b[^|]*\|\s*(ba)?sh\b/i,
	/\bkill(all)?\s+-9\b/i,
	/\bdiskutil\s+(erase|eject)\b/i,
	/\bcsrutil\b/i,
	/\bdefaults\s+write\b.*\bcom\.apple/i,
];

export default function (pi: ExtensionAPI) {
	pi.on("before_agent_start", async (event) => {
		if (process.env.ALFRED_REMOTE !== "1") return; // local: trusted
		// Remote session: tag the system prompt so the model asks before
		// destructive actions.
		return {
			systemPrompt:
				event.systemPrompt +
				"\n\n## Remote session\n" +
				"You are being accessed remotely. Before running any command that " +
				"deletes data, pushes to a remote (git push), modifies system " +
				"settings, or is otherwise hard to undo, you MUST first ask the " +
				"user for confirmation and wait for the answer.",
		};
	});

	// Hard backstop: block destructive bash commands in remote mode even
	// if the model ignores the system-prompt instruction.
	pi.on("tool_call", async (event) => {
		if (process.env.ALFRED_REMOTE !== "1") return undefined;
		if (event.toolName !== "bash") return undefined;
		const command = (event.input?.command as string) ?? "";
		if (DESTRUCTIVE_PATTERNS.some((re) => re.test(command))) {
			return {
				block: true,
				reason:
					"ALFRED approval guard: destructive command blocked in remote session. Run it locally or ask the user to approve it.",
			};
		}
		return undefined;
	});
}
