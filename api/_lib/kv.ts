// Minimal Upstash Redis REST client (native fetch, no deps) — the small always-on state store the
// stateless webhook/cron functions share. Reads the env vars injected by Vercel's Upstash/KV
// integration (KV_REST_API_URL / KV_REST_API_TOKEN), falling back to the native Upstash names.
//
// Used for: the latest phone location (written by the Telegram webhook, read by the departure cron)
// and per-event "already nudged" markers. Everything degrades to a no-op if the store isn't wired,
// so the rest of the bot keeps working without it.

const restUrl = (): string => process.env.KV_REST_API_URL || process.env.UPSTASH_REDIS_REST_URL || "";
const restToken = (): string => process.env.KV_REST_API_TOKEN || process.env.UPSTASH_REDIS_REST_TOKEN || "";

/** True once the Upstash env vars are present — callers should skip their feature if this is false. */
export function kvConfigured(): boolean {
  return !!(restUrl() && restToken());
}

/**
 * How long a single Redis round trip may take before it is abandoned.
 *
 * `fetch` has no default timeout, so a store that accepts the connection and then
 * says nothing leaves the promise pending forever. That is not a slow request —
 * it is an unkillable one, and it takes the whole function down with it: the relay
 * in api/mac.ts polls inside a loop whose 25s deadline is only re-checked *between*
 * iterations, so one hung call runs to the 60s maxDuration and the caller gets
 * FUNCTION_INVOCATION_TIMEOUT instead of an answer. Every caller here already
 * treats null as "store unavailable", so a bounded failure is strictly better than
 * an unbounded wait.
 */
const COMMAND_TIMEOUT_MS = 5_000;

/** POST a single Redis command (`["SET","k","v","EX",60]`) to the Upstash REST endpoint. */
async function command(args: (string | number)[]): Promise<unknown> {
  const url = restUrl();
  const token = restToken();
  if (!url || !token) return null;
  try {
    const res = await fetch(url, {
      method: "POST",
      headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(COMMAND_TIMEOUT_MS),
    });
    if (!res.ok) {
      // Logged rather than swallowed: a 401 from a rotated token and a 429 from a
      // hit quota both surface here as "everything quietly stopped working", and
      // there is no other signal that the store is the reason.
      console.warn(`[kv] ${args[0]} failed: HTTP ${res.status}`);
      return null;
    }
    const json: any = await res.json();
    return json?.result ?? null;
  } catch (e: any) {
    console.warn(`[kv] ${args[0]} failed: ${e?.name === "TimeoutError" ? `no response in ${COMMAND_TIMEOUT_MS}ms` : e?.message ?? e}`);
    return null;
  }
}

export async function kvGet(key: string): Promise<string | null> {
  const r = await command(["GET", key]);
  return r == null ? null : String(r);
}

/** SET key=value, optionally expiring after `ttlSeconds` (so stale location/markers self-clean). */
export async function kvSet(key: string, value: string, ttlSeconds?: number): Promise<void> {
  await command(ttlSeconds && ttlSeconds > 0 ? ["SET", key, value, "EX", Math.ceil(ttlSeconds)] : ["SET", key, value]);
}

/** SET that reports whether the store actually took it. `kvSet` swallows failures because a dropped
 *  location ping or dedupe marker is survivable; a dropped mail account is not — the user would be
 *  told their mailbox was connected and then find it missing. */
export async function kvSetOK(key: string, value: string): Promise<boolean> {
  return (await command(["SET", key, value])) === "OK";
}

export async function kvDel(key: string): Promise<void> {
  await command(["DEL", key]);
}

/** Atomic set-if-absent with TTL. Returns true if THIS call set the key (i.e. it was new). Used to
 *  process each webhook update exactly once. Returns false if the store isn't configured. */
export async function kvSetNX(key: string, value: string, ttlSeconds: number): Promise<boolean> {
  const r = await command(["SET", key, value, "NX", "EX", Math.ceil(ttlSeconds)]);
  return r === "OK";
}
