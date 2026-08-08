// APNs push sender — "time to leave" and other nudges, delivered straight to the Alfred iOS app.
//
// Vercel's Node runtime ships the `http2` module, and APNs REQUIRES HTTP/2 — plain fetch (HTTP/1.1)
// is rejected with `BadRequest`. Provider auth uses an ES256 JWT signed with the .p8 auth key from the
// Apple Developer portal, so there is no long-lived client certificate to manage and nothing to
// refresh: the JWT is minted per request (and reused within the same warm function instance).
//
// Env (all required for push to work; anything missing → sendApnsPush returns null and callers
// fall back to their existing channel):
//   APNS_KEY_ID      the 10-char Key ID shown under "Keys" in the Apple Developer portal
//   APNS_TEAM_ID     the team id
//   APNS_AUTH_KEY    the p8 file's contents (the -----BEGIN PRIVATE KEY----- blob), or a path to it
//   APNS_BUNDLE_ID   the app's bundle id (Carlton.Alfred)
//   APNS_ENV         development | production (default production; the sandbox host is
//                    api.development.push.apple.com, which the Xcode debug build's aps-environment
//                    entitlement needs)

import { createPrivateKey, sign, timingSafeEqual } from "crypto";
import { readFileSync } from "fs";
import * as http2 from "http2";
import { kvGet, kvSet } from "./kv";

const TOKEN_KEY = "dev:apns:token";
const TOKEN_TTL_S = 90 * 24 * 3600; // device tokens are stable; refresh on every app launch

const SANDBOX_HOST = "api.development.push.apple.com";
const PROD_HOST = "api.push.apple.com";
const P8_PEM_RE = /-----BEGIN [A-Z ]*PRIVATE KEY-----/;

/** Remember this device token so nudges can reach this install. */
export async function registerDeviceToken(token: string): Promise<boolean> {
  const clean = token.trim();
  if (!/^[0-9a-fA-F]{32,200}$/.test(clean)) return false;
  await kvSet(TOKEN_KEY, clean, TOKEN_TTL_S);
  return true;
}

async function readDeviceToken(): Promise<string | null> {
  const raw = await kvGet(TOKEN_KEY);
  return raw && raw.trim().length ? raw.trim() : null;
}

/** The p8 key as PEM — either inline env contents or a path the function can read. */
function authKeyPem(): string | null {
  const v = process.env.APNS_AUTH_KEY ?? "";
  if (!v) return null;
  if (P8_PEM_RE.test(v)) return v;
  try {
    return readFileSync(v, "utf8") as string;
  } catch {
    return null;
  }
}

function apnsConfigured(): boolean {
  return !!(process.env.APNS_KEY_ID && process.env.APNS_TEAM_ID && process.env.APNS_BUNDLE_ID && authKeyPem());
}

/** Fresh ES256 provider token: `{alg:ES256,kid}` header, `{iss:teamId,iat:now}` claims. */
function providerToken(): string | null {
  const keyId = process.env.APNS_KEY_ID;
  const teamId = process.env.APNS_TEAM_ID;
  const pem = authKeyPem();
  if (!keyId || !teamId || !pem) return null;
  try {
    const header = Buffer.from(JSON.stringify({ alg: "ES256", kid: keyId })).toString("base64url");
    const claims = Buffer.from(JSON.stringify({ iss: teamId, iat: Math.floor(Date.now() / 1000) })).toString("base64url");
    const payload = `${header}.${claims}`;
    const sig = sign("sha256", Buffer.from(payload), createPrivateKey(pem));
    return `${payload}.${sig.toString("base64url")}`;
  } catch {
    return null;
  }
}

export interface ApnsMessage {
  title: string;
  body: string;
}

/** Send one push. Resolves `true` on APNs "200 OK", `false`/`null` on any failure or misconfig. */
export async function sendApnsPush(message: ApnsMessage): Promise<boolean> {
  if (!apnsConfigured()) return false;
  const token = await readDeviceToken();
  if (!token) return false;
  const jwt = providerToken();
  if (!jwt) return false;

  const host = process.env.APNS_ENV === "development" ? SANDBOX_HOST : PROD_HOST;
  const path = `/3/device/${token}`;
  const payload = JSON.stringify({
    aps: {
      alert: { title: message.title, body: message.body },
      sound: "default",
      "content-available": 1,
    },
  });

  return new Promise<boolean>((resolve) => {
    const client = http2.connect(`https://${host}`, { timeout: 10_000 });
    const settled = (ok: boolean): void => {
      try { client.close(); } catch { /* already closed */ }
      resolve(ok);
    };
    client.on("error", () => settled(false));

    const req = client.request({
      ":method": "POST",
      ":path": path,
      authorization: `bearer ${jwt}`,
      "apns-topic": process.env.APNS_BUNDLE_ID!,
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": "0",
      "content-type": "application/json",
      "content-length": Buffer.byteLength(payload),
    });
    req.on("response", (headers) => settled(headers[":status"] === 200));
    req.on("error", () => settled(false));
    req.setTimeout(10_000, () => settled(false));
    req.end(payload);
  });
}

export const pushConfigured = apnsConfigured;

/** Compare in constant time — device tokens are bearer credentials in KV. */
export function tokenMatches(presented: string, expected: string): boolean {
  const a = Buffer.from(presented, "utf8");
  const b = Buffer.from(expected, "utf8");
  if (a.length !== b.length) {
    timingSafeEqual(a, a);
    return false;
  }
  return timingSafeEqual(a, b);
}
