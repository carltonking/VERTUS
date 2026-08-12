// The VIP list — a short, always-available set of sender addresses the user has starred.
//
// Stored as a JSON array in Upstash, deliberately separate from accounts: a VIP is "mail from this
// person belongs at the top of my inbox", and that survives account changes. Matches are made on the
// lowercase address, which is what IMAP search compares against.

import { kvConfigured, kvGet, kvSetOK } from "./kv";

const VIP_KEY = "mail:vips:v1";

export async function vipAddresses(): Promise<string[]> {
  if (!kvConfigured()) return [];
  const raw = await kvGet(VIP_KEY);
  if (!raw) return [];
  try {
    const list = JSON.parse(raw);
    return Array.isArray(list) ? list.filter((a): a is string => typeof a === "string") : [];
  } catch {
    return [];
  }
}

/** Adds or removes one address. Throws when the store rejects the write. */
export async function setVipAddress(address: string, vip: boolean): Promise<void> {
  const key = address.trim().toLowerCase();
  if (!key) return;
  const list = await vipAddresses();
  const next = vip
    ? list.includes(key)
      ? list
      : [...list, key]
    : list.filter((a) => a !== key);
  const ok = await kvSetOK(VIP_KEY, JSON.stringify(next));
  if (!ok) throw new Error("couldn't write the VIP list — check the Upstash (KV_REST_API_*) configuration");
}
