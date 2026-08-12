// Encryption for the one class of secret Alfred stores rather than reads from env: the app-specific
// mail passwords the owner adds from his phone.
//
// Upstash is a hosted store Alfred doesn't control, so a plaintext password there would be readable by
// anyone who ever gets the KV token — a far wider blast radius than the mailbox itself. AES-256-GCM
// keeps them unreadable without MAIL_SECRET_KEY (which lives in Vercel env, a different system), and
// being authenticated encryption it also detects tampering rather than silently decrypting garbage
// into an SMTP login attempt.
//
// Env: MAIL_SECRET_KEY — 32 random bytes, base64. Generate with:
//   node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"

import { createCipheriv, createDecipheriv, createHash, randomBytes } from "crypto";

/** Version tag on every ciphertext, so the scheme can change later without guessing at old blobs. */
const SCHEME = "v1";

/**
 * The 32-byte key. A correct base64 key is used verbatim; anything else is hashed to length rather
 * than rejected, so a hand-typed passphrase degrades to "weaker key" instead of "mail silently broken".
 */
function key(): Buffer | null {
  const raw = (process.env.MAIL_SECRET_KEY || "").trim();
  if (!raw) return null;
  const decoded = Buffer.from(raw, "base64");
  if (decoded.length === 32) return decoded;
  return createHash("sha256").update(raw, "utf8").digest();
}

/** True once MAIL_SECRET_KEY is set. Callers refuse to store credentials when this is false. */
export function secretsConfigured(): boolean {
  return key() !== null;
}

export function encryptSecret(plaintext: string): string {
  const k = key();
  if (!k) throw new Error("MAIL_SECRET_KEY is not set — refusing to store a mail password unencrypted");

  const iv = randomBytes(12); // 96-bit nonce, the size GCM is defined for
  const cipher = createCipheriv("aes-256-gcm", k, iv);
  const body = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return [SCHEME, iv.toString("base64"), cipher.getAuthTag().toString("base64"), body.toString("base64")].join(".");
}

export function decryptSecret(blob: string): string {
  const k = key();
  if (!k) throw new Error("MAIL_SECRET_KEY is not set — stored mail passwords can't be read");

  const [scheme, ivB64, tagB64, bodyB64] = String(blob).split(".");
  if (scheme !== SCHEME || !ivB64 || !tagB64 || !bodyB64) throw new Error("stored credential is malformed");

  const decipher = createDecipheriv("aes-256-gcm", k, Buffer.from(ivB64, "base64"));
  decipher.setAuthTag(Buffer.from(tagB64, "base64"));
  // .final() throws if the tag doesn't verify — a rotated key or an edited record fails loudly here.
  return Buffer.concat([decipher.update(Buffer.from(bodyB64, "base64")), decipher.final()]).toString("utf8");
}
