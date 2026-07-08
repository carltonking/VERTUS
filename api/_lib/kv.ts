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
    });
    if (!res.ok) return null;
    const json: any = await res.json();
    return json?.result ?? null;
  } catch {
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

export async function kvDel(key: string): Promise<void> {
  await command(["DEL", key]);
}
