// The model chain — Alfred's single LLM entry point in the cloud.
//
// Instead of one hard-wired provider + one key, every call walks an ORDERED list of free-tier
// (provider, model, key) slots and returns the first one that answers. A slot that fails goes on a
// cooldown (shared across serverless invocations via KV) so the next request skips straight past it
// rather than paying the same timeout again. Nothing to switch by hand: add keys, and Alfred drains
// them in order as each free tier runs out.
//
// Config is all env — no code change to add a key, rotate a model id, or reorder the chain:
//   GEMINI_API_KEY / GROQ_API_KEY / CEREBRAS_API_KEY / OPENROUTER_API_KEY / MISTRAL_API_KEY
//   ...plus _2.._5 suffixes and/or comma-separated values for MULTIPLE keys per provider
//   GEMINI_MODEL / GROQ_MODEL / ...            override the text model for one provider
//   LLM_CHAIN="groq,gemini,cerebras"           reorder / restrict the chain (default: all, in order)
//
// Providers with no key are silently skipped, so an unconfigured provider costs nothing.

import { kvGet, kvSet, kvConfigured } from "./kv";

// MARK: - Neutral request shape

export type Capability = "text" | "vision" | "video";

/** One piece of a user turn, in a provider-neutral form the transports translate. */
export type Part =
  | { text: string }
  | { image: { mimeType: string; data: string } } // base64
  | { video: { url: string } };                   // e.g. a YouTube link (Gemini ingests natively)

interface ProviderSpec {
  id: string;
  label: string;
  kind: "gemini" | "openai";  // wire format
  endpoint?: string;          // openai-compatible providers only
  envKey: string;             // base env var name for the key(s)
  caps: Capability[];
  models: { text: string; vision?: string; video?: string };
  keyURL: string;             // where to get a free key (shown by /models)
}

// Default order: fastest + most generous free tiers first. Gemini leads because it's the only one
// here that reads images AND video, so a multimodal call doesn't have to fall through the chain.
const PROVIDERS: ProviderSpec[] = [
  {
    id: "gemini",
    label: "Google Gemini",
    kind: "gemini",
    envKey: "GEMINI_API_KEY",
    caps: ["text", "vision", "video"],
    models: { text: "gemini-2.5-flash-lite", vision: "gemini-2.5-flash-lite", video: "gemini-2.5-flash" },
    keyURL: "https://aistudio.google.com/apikey",
  },
  {
    id: "groq",
    label: "Groq",
    kind: "openai",
    endpoint: "https://api.groq.com/openai/v1/chat/completions",
    envKey: "GROQ_API_KEY",
    caps: ["text", "vision"],
    models: { text: "llama-3.3-70b-versatile", vision: "meta-llama/llama-4-scout-17b-16e-instruct" },
    keyURL: "https://console.groq.com/keys",
  },
  {
    id: "cerebras",
    label: "Cerebras",
    kind: "openai",
    endpoint: "https://api.cerebras.ai/v1/chat/completions",
    envKey: "CEREBRAS_API_KEY",
    caps: ["text"],
    models: { text: "llama-3.3-70b" },
    keyURL: "https://cloud.cerebras.ai/",
  },
  {
    id: "openrouter",
    label: "OpenRouter",
    kind: "openai",
    endpoint: "https://openrouter.ai/api/v1/chat/completions",
    envKey: "OPENROUTER_API_KEY",
    caps: ["text", "vision"],
    models: { text: "meta-llama/llama-3.3-70b-instruct:free", vision: "meta-llama/llama-4-maverick:free" },
    keyURL: "https://openrouter.ai/keys",
  },
  {
    id: "mistral",
    label: "Mistral",
    kind: "openai",
    endpoint: "https://api.mistral.ai/v1/chat/completions",
    envKey: "MISTRAL_API_KEY",
    caps: ["text", "vision"],
    models: { text: "mistral-small-latest", vision: "pixtral-12b-2409" },
    keyURL: "https://console.mistral.ai/api-keys/",
  },
];

/** Providers in the configured order (LLM_CHAIN wins; unknown ids are ignored). */
function chain(): ProviderSpec[] {
  const raw = (process.env.LLM_CHAIN || "").trim();
  if (!raw) return PROVIDERS;
  const wanted = raw.split(/[,\s]+/).map((s) => s.trim().toLowerCase()).filter(Boolean);
  const picked = wanted.map((id) => PROVIDERS.find((p) => p.id === id)).filter(Boolean) as ProviderSpec[];
  return picked.length ? picked : PROVIDERS;
}

/** Every key configured for a provider: BASE, BASE_2..BASE_5, each optionally comma-separated. */
function keysFor(p: ProviderSpec): string[] {
  const raw = [p.envKey, ...[2, 3, 4, 5].map((n) => `${p.envKey}_${n}`)]
    .map((name) => process.env[name] || "")
    .join(",");
  return [...new Set(raw.split(/[,\s]+/).map((k) => k.trim()).filter(Boolean))];
}

function modelFor(p: ProviderSpec, cap: Capability): string | null {
  // <PROVIDER>_MODEL overrides the text model — the one that churns most (ids get retired upstream).
  if (cap === "text") return process.env[`${p.id.toUpperCase()}_MODEL`] || p.models.text;
  return p.models[cap] || null;
}

// MARK: - Cooldowns
//
// A slot that just failed shouldn't be re-tried on the very next message. The in-memory map covers a
// warm Fluid instance; KV shares the verdict with cold ones. Both are best-effort — a lost cooldown
// only costs one wasted attempt.

const memCooldown = new Map<string, number>(); // slot -> epoch ms when it becomes usable again

const slotKey = (providerID: string, keyIndex: number) => `${providerID}#${keyIndex}`;

async function coolingUntil(slot: string): Promise<number> {
  const local = memCooldown.get(slot) ?? 0;
  if (local > Date.now()) return local;
  if (!kvConfigured()) return 0;
  const v = await kvGet(`llm:cool:${slot}`);
  const until = v ? Number(v) : 0;
  if (until > Date.now()) memCooldown.set(slot, until);
  return until > Date.now() ? until : 0;
}

async function cool(slot: string, seconds: number, why: string): Promise<void> {
  const until = Date.now() + seconds * 1000;
  memCooldown.set(slot, until);
  console.log(`[llm] ${slot} cooling ${seconds}s — ${why}`);
  if (kvConfigured()) await kvSet(`llm:cool:${slot}`, String(until), seconds);
}

function clearCool(slot: string): void {
  memCooldown.delete(slot);
}

/**
 * How long to sideline a slot, by failure kind. Quota exhaustion is the long one. 0 = don't cool:
 * a 400/413/422 is usually about THIS request (too big, bad image), not the provider — cooling on it
 * would let one oversized message knock the whole chain out for half an hour.
 */
function penalty(status: number, retryAfter: number | null): number {
  if (retryAfter && retryAfter > 0) return Math.min(Math.max(retryAfter, 30), 3600);
  if (status === 401 || status === 403) return 6 * 3600;  // bad/revoked key — stop retrying it today
  if (status === 429) return 300;                          // rate limit or daily free-tier cap
  if (status === 404) return 1800;                         // stale/retired model id
  if (status === 400 || status === 413 || status === 422) return 0;
  return 60;                                               // 5xx, timeout, network blip
}

function retryAfterSeconds(res: Response): number | null {
  const h = res.headers.get("retry-after");
  if (!h) return null;
  const n = Number(h);
  return Number.isFinite(n) ? n : null;
}

// MARK: - Transports

const TIMEOUT_MS = Number(process.env.LLM_TIMEOUT_MS || 30000);

interface Attempt {
  ok: boolean;
  text?: string;
  status: number;        // 0 = network/timeout
  retryAfter: number | null;
  detail?: string;
}

async function callGemini(
  key: string, model: string, system: string, parts: Part[], temperature: number
): Promise<Attempt> {
  const body = {
    systemInstruction: system ? { parts: [{ text: system }] } : undefined,
    contents: [
      {
        role: "user",
        parts: parts.map((p) =>
          "text" in p
            ? { text: p.text }
            : "image" in p
            ? { inlineData: { mimeType: p.image.mimeType, data: p.image.data } }
            : { fileData: { fileUri: p.video.url } }
        ),
      },
    ],
    generationConfig: { temperature },
  };
  const url = `https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent?key=${key}`;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) {
      return { ok: false, status: res.status, retryAfter: retryAfterSeconds(res), detail: (await res.text()).slice(0, 200) };
    }
    const data: any = await res.json();
    const text: string = (data?.candidates?.[0]?.content?.parts ?? [])
      .map((p: any) => p?.text)
      .filter(Boolean)
      .join("")
      .trim();
    return text ? { ok: true, text, status: 200, retryAfter: null }
                : { ok: false, status: 200, retryAfter: null, detail: "empty completion" };
  } catch (e: any) {
    return { ok: false, status: 0, retryAfter: null, detail: String(e?.message || e).slice(0, 200) };
  }
}

async function callOpenAICompatible(
  p: ProviderSpec, key: string, model: string, system: string, parts: Part[], temperature: number
): Promise<Attempt> {
  // Video isn't expressible on the chat-completions wire — the caller filters these out already.
  const content = parts.map((part) =>
    "text" in part
      ? { type: "text", text: part.text }
      : "image" in part
      ? { type: "image_url", image_url: { url: `data:${part.image.mimeType};base64,${part.image.data}` } }
      : { type: "text", text: (part as any).video.url }
  );
  const messages: unknown[] = [];
  if (system) messages.push({ role: "system", content: system });
  // Text-only turns use the plain string form — a few providers reject the parts array without images.
  messages.push({
    role: "user",
    content: content.every((c: any) => c.type === "text")
      ? content.map((c: any) => c.text).join("\n")
      : content,
  });

  try {
    const res = await fetch(p.endpoint!, {
      method: "POST",
      headers: { Authorization: `Bearer ${key}`, "Content-Type": "application/json" },
      body: JSON.stringify({ model, messages, temperature, max_tokens: 4096 }),
      signal: AbortSignal.timeout(TIMEOUT_MS),
    });
    if (!res.ok) {
      return { ok: false, status: res.status, retryAfter: retryAfterSeconds(res), detail: (await res.text()).slice(0, 200) };
    }
    const data: any = await res.json();
    const text: string = String(data?.choices?.[0]?.message?.content ?? "").trim();
    return text ? { ok: true, text, status: 200, retryAfter: null }
                : { ok: false, status: 200, retryAfter: null, detail: "empty completion" };
  } catch (e: any) {
    return { ok: false, status: 0, retryAfter: null, detail: String(e?.message || e).slice(0, 200) };
  }
}

// MARK: - The chain

interface Slot {
  provider: ProviderSpec;
  model: string;
  key: string;
  keyIndex: number;
  id: string;
}

/** Every usable (provider, model, key) slot for a capability, in chain order. */
function slotsFor(cap: Capability): Slot[] {
  const out: Slot[] = [];
  for (const provider of chain()) {
    if (!provider.caps.includes(cap)) continue;
    const model = modelFor(provider, cap);
    if (!model) continue;
    keysFor(provider).forEach((key, i) => {
      out.push({ provider, model, key, keyIndex: i, id: slotKey(provider.id, i) });
    });
  }
  return out;
}

/**
 * Run a completion against the chain: first slot that answers wins. A cooling slot is moved to the
 * BACK rather than dropped — a rate-limited retry still beats returning nothing when everything is
 * cooling. Returns null only when every slot failed (or none is configured).
 */
export async function callLLM(
  system: string,
  parts: Part[],
  opts: { capability?: Capability; temperature?: number } = {}
): Promise<string | null> {
  const cap = opts.capability ?? "text";
  const temperature = opts.temperature ?? 0.5;
  const all = slotsFor(cap);
  if (!all.length) {
    console.error(`[llm] no provider configured for "${cap}" — set one of: ${PROVIDERS.filter((p) => p.caps.includes(cap)).map((p) => p.envKey).join(", ")}`);
    return null;
  }

  const cooling = await Promise.all(all.map((s) => coolingUntil(s.id)));
  const ready = all.filter((_, i) => !cooling[i]);
  const benched = all.filter((_, i) => !!cooling[i]);
  const ordered = [...ready, ...benched];

  for (const slot of ordered) {
    const attempt =
      slot.provider.kind === "gemini"
        ? await callGemini(slot.key, slot.model, system, parts, temperature)
        : await callOpenAICompatible(slot.provider, slot.key, slot.model, system, parts, temperature);

    if (attempt.ok && attempt.text) {
      clearCool(slot.id);
      console.log(`[llm] ${slot.id} ${slot.model} answered (${cap})`);
      return attempt.text;
    }
    const seconds = penalty(attempt.status, attempt.retryAfter);
    if (seconds > 0) await cool(slot.id, seconds, `HTTP ${attempt.status}: ${attempt.detail ?? ""}`);
    else console.log(`[llm] ${slot.id} rejected this request (HTTP ${attempt.status}: ${attempt.detail ?? ""}) — not cooling`);
  }

  console.error(`[llm] all ${ordered.length} slot(s) failed for "${cap}"`);
  return null;
}

// MARK: - Call-site helpers (drop-in for the old gemini.ts API)

/** Text-only completion. */
export function llmText(system: string, user: string, temperature = 0.5): Promise<string | null> {
  return callLLM(system, [{ text: user }], { temperature });
}

/** Vision: a prompt plus one inline image (base64). Routed to a vision-capable slot. */
export function llmVision(
  system: string,
  prompt: string,
  imageBase64: string,
  mimeType = "image/jpeg",
  temperature = 0.3
): Promise<string | null> {
  return callLLM(system, [{ text: prompt }, { image: { mimeType, data: imageBase64 } }], {
    capability: "vision",
    temperature,
  });
}

/** Watch a video URL and answer a question about it (visual + audio, no download). Gemini-only today. */
export function llmVideo(
  system: string,
  prompt: string,
  videoURL: string,
  temperature = 0.4
): Promise<string | null> {
  return callLLM(system, [{ text: prompt }, { video: { url: videoURL } }], {
    capability: "video",
    temperature,
  });
}

// MARK: - Diagnostics

/** Human-readable chain health, for /models in Telegram. */
export async function chainStatus(): Promise<string> {
  const lines: string[] = [];
  for (const p of chain()) {
    const keys = keysFor(p);
    if (!keys.length) {
      lines.push(`⚪️ ${p.label} — no key (${p.envKey}) · ${p.keyURL}`);
      continue;
    }
    const cools = await Promise.all(keys.map((_, i) => coolingUntil(slotKey(p.id, i))));
    const down = cools.filter(Boolean).length;
    const mins = Math.max(0, ...cools.map((u) => (u ? Math.ceil((u - Date.now()) / 60000) : 0)));
    const state = down === 0 ? "🟢 ready" : down < keys.length ? `🟡 ${keys.length - down}/${keys.length} keys ready` : `🔴 cooling ~${mins}m`;
    lines.push(`${state} — ${p.label} · ${modelFor(p, "text")} · ${keys.length} key${keys.length > 1 ? "s" : ""}`);
  }
  return `Model chain (tried top to bottom):\n\n${lines.join("\n")}`;
}
