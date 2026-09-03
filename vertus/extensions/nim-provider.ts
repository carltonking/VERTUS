/**
 * VERTUS — NVIDIA NIM provider extension for pi
 *
 * Registers NVIDIA NIM (https://integrate.api.nvidia.com/v1) as an
 * OpenAI-compatible provider. No fork of pi-ai needed.
 *
 * Env: NVIDIA_API_KEY   (server-side only — never ship to clients)
 *
 * Model list: NIM catalog changes often; add/remove entries here.
 * Costs are placeholders (NIM pricing varies per model / credits).
 */
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
	pi.registerProvider("nvidia-nim", {
		name: "NVIDIA NIM",
		baseUrl: "https://integrate.api.nvidia.com/v1",
		apiKey: "$NVIDIA_API_KEY",
		api: "openai-completions",
		models: [
			{
				// Default — frontier reasoning + tool use, free tier
				id: "nvidia/nemotron-3-ultra:free",
				name: "Nemotron 3 Ultra (free, NIM)",
				reasoning: true,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 131072,
				maxTokens: 16384,
			},
			{
				// Default workhorse — strong reasoning + tool use
				id: "meta/llama-3.3-70b-instruct",
				name: "Llama 3.3 70B (NIM)",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 8192,
			},
			{
				// Long-context tasks (docs, big diffs)
				id: "meta/llama-3.1-405b-instruct",
				name: "Llama 3.1 405B (NIM)",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 8192,
			},
			{
				// Fast/cheap tier for quick bar one-liners
				id: "meta/llama-3.1-8b-instruct",
				name: "Llama 3.1 8B (NIM)",
				reasoning: false,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 4096,
			},
			{
				// Reasoning-capable (DeepSeek R1 distill on NIM)
				id: "deepseek-ai/deepseek-r1",
				name: "DeepSeek R1 (NIM)",
				reasoning: true,
				input: ["text"],
				cost: { input: 0, output: 0, cacheRead: 0, cacheWrite: 0 },
				contextWindow: 128000,
				maxTokens: 16384,
			},
		],
	});
}
