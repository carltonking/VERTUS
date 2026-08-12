// Which mailboxes Alfred can reach, and where that list comes from.
//
// Two sources, deliberately:
//   env    — APPLE_ID/APPLE_APP_PASSWORD, GMAIL_ADDRESS/GMAIL_APP_PASSWORD, MAIL_ACCOUNTS JSON.
//            Set by whoever deploys. The phone can see these but can't delete them, because an app
//            shouldn't be able to unpick the server's own configuration.
//   stored — added from the iOS app, kept in Upstash with the password encrypted (see crypto.ts).
//
// Both feed one resolved list so the iOS app, the Telegram /email flow and the cron briefings all
// read exactly the same mailboxes — the alternative (per-client account lists) means "Alfred didn't
// mention that email" bugs that are impossible to reason about.
//
// This module owns account identity; mail.ts owns talking IMAP/SMTP. Keeping them apart is what stops
// the two files importing each other in a cycle.

import { ImapFlow } from "imapflow";
import nodemailer from "nodemailer";
import { randomUUID } from "crypto";
import { kvGet, kvSetOK, kvConfigured } from "./kv";
import { encryptSecret, decryptSecret, secretsConfigured } from "./crypto";

export interface MailAccount {
  label: string; // unique; also what MailMsg.account carries and sendMail resolves on
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
  user: string; // full email address
  pass: string; // app-specific password (password auth)
  source: "env" | "stored";
  id?: string; // stored accounts only — what the app deletes by
  provider?: string;
  /** "password" (default) logs in with `pass`; "oauth" uses Google XOAUTH2 via refreshToken. */
  auth?: "password" | "oauth";
  /** OAuth accounts only — the Google refresh token, encrypted by crypto.ts. */
  refreshToken?: string;
}

/** What the app is told about an account. Note the absence of `pass` — it never leaves the server. */
export interface AccountSummary {
  id: string;
  label: string;
  address: string;
  provider: string;
  source: "env" | "stored";
  removable: boolean;
}

interface StoredAccount {
  id: string;
  label: string;
  provider: string;
  address: string;
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
  secret: string; // password auth — encrypted by crypto.ts
  /** OAuth auth only — the Google refresh token, encrypted by crypto.ts. */
  refreshToken?: string;
  auth?: "password" | "oauth";
  addedAt: string;
}

const STORE_KEY = "mail:accounts:v1";

// MARK: - Providers the app offers

export interface ProviderPreset {
  id: string;
  name: string;
  imapHost: string;
  imapPort: number;
  smtpHost: string;
  smtpPort: number;
  /** Shown in the app under the password field — every one of these needs an app-specific password,
   *  not the account password, and that is the single most common reason an add fails. */
  passwordHint: string;
  helpUrl?: string;
  /** OAuth providers aren't added with an address + password; the app signs in via Google instead. */
  oauth?: boolean;
}

export const PROVIDERS: ProviderPreset[] = [
  {
    id: "icloud",
    name: "iCloud",
    imapHost: "imap.mail.me.com",
    imapPort: 993,
    smtpHost: "smtp.mail.me.com",
    smtpPort: 587,
    passwordHint: "Needs an app-specific password from appleid.apple.com — your Apple ID password won't work.",
    helpUrl: "https://support.apple.com/en-us/102654",
  },
  {
    id: "gmail",
    name: "Gmail",
    imapHost: "imap.gmail.com",
    imapPort: 993,
    smtpHost: "smtp.gmail.com",
    smtpPort: 587,
    passwordHint: "Turn on 2-Step Verification, then create a 16-character app password. Your normal password is rejected.",
    helpUrl: "https://myaccount.google.com/apppasswords",
  },
  {
    id: "outlook",
    name: "Outlook",
    imapHost: "outlook.office365.com",
    imapPort: 993,
    smtpHost: "smtp-mail.outlook.com",
    smtpPort: 587,
    passwordHint: "Microsoft is switching personal accounts to OAuth-only; if this is rejected, IMAP may no longer be available for it.",
  },
  {
    id: "yahoo",
    name: "Yahoo",
    imapHost: "imap.mail.yahoo.com",
    imapPort: 993,
    smtpHost: "smtp.mail.yahoo.com",
    smtpPort: 587,
    passwordHint: "Needs an app password generated in Yahoo Account Security.",
  },
  {
    id: "fastmail",
    name: "Fastmail",
    imapHost: "imap.fastmail.com",
    imapPort: 993,
    smtpHost: "smtp.fastmail.com",
    smtpPort: 587,
    passwordHint: "Create an app password with Mail (IMAP/SMTP) access.",
  },
  {
    id: "custom",
    name: "Other (IMAP)",
    imapHost: "",
    imapPort: 993,
    smtpHost: "",
    smtpPort: 587,
    passwordHint: "Enter the IMAP and SMTP hostnames your provider documents.",
  },
  {
    id: "google",
    name: "Google",
    oauth: true,
    imapHost: "imap.gmail.com",
    imapPort: 993,
    smtpHost: "smtp.gmail.com",
    smtpPort: 587,
    // The app never shows a password field for this one; Google's consent screen is the whole login.
    passwordHint: "Signed in by Google — no password needed. Connect one Google account per mail address.",
  },
];

export function providerById(id: string): ProviderPreset | undefined {
  return PROVIDERS.find((p) => p.id === id);
}

// MARK: - Accounts configured by env

function envAccounts(): MailAccount[] {
  const accts: MailAccount[] = [];

  const appleUser = process.env.APPLE_ID;
  const applePass = process.env.MAIL_ICLOUD_APP_PASSWORD || process.env.APPLE_APP_PASSWORD;
  if (appleUser && applePass) {
    accts.push({ label: "iCloud", imapHost: "imap.mail.me.com", imapPort: 993, smtpHost: "smtp.mail.me.com", smtpPort: 587, user: appleUser, pass: applePass, source: "env", provider: "icloud" });
  }

  const gUser = process.env.GMAIL_ADDRESS;
  const gPass = process.env.GMAIL_APP_PASSWORD;
  if (gUser && gPass) {
    accts.push({ label: "Gmail", imapHost: "imap.gmail.com", imapPort: 993, smtpHost: "smtp.gmail.com", smtpPort: 587, user: gUser, pass: gPass, source: "env", provider: "gmail" });
  }

  try {
    const extra = process.env.MAIL_ACCOUNTS ? JSON.parse(process.env.MAIL_ACCOUNTS) : [];
    if (Array.isArray(extra)) {
      for (const a of extra) {
        if (a?.user && a?.pass && a?.imapHost) {
          accts.push({
            label: a.label || a.user,
            imapHost: a.imapHost,
            imapPort: a.imapPort || 993,
            smtpHost: a.smtpHost || String(a.imapHost).replace(/^imap/, "smtp"),
            smtpPort: a.smtpPort || 587,
            user: a.user,
            pass: a.pass,
            source: "env",
            provider: a.provider || "custom",
          });
        }
      }
    }
  } catch {
    /* a malformed MAIL_ACCOUNTS shouldn't take the working accounts down with it */
  }

  return accts;
}

// MARK: - Accounts added from the app

async function loadStored(): Promise<StoredAccount[]> {
  if (!kvConfigured()) return [];
  const raw = await kvGet(STORE_KEY);
  if (!raw) return [];
  try {
    const list = JSON.parse(raw);
    return Array.isArray(list) ? (list as StoredAccount[]) : [];
  } catch {
    return [];
  }
}

/** Writes the whole list. Throws when the store rejects it, so "added" is never reported on a lost write. */
async function saveStored(list: StoredAccount[]): Promise<void> {
  const ok = await kvSetOK(STORE_KEY, JSON.stringify(list));
  if (!ok) throw new Error("couldn't write to the account store — check the Upstash (KV_REST_API_*) configuration");
}

function storedToAccount(s: StoredAccount): MailAccount | null {
  const base = {
    label: s.label,
    imapHost: s.imapHost,
    imapPort: s.imapPort,
    smtpHost: s.smtpHost,
    smtpPort: s.smtpPort,
    user: s.address,
    source: "stored" as const,
    id: s.id,
    provider: s.provider,
  };
  try {
    if (s.auth === "oauth") {
      if (!s.refreshToken) return null;
      return {
        ...base,
        auth: "oauth",
        pass: "",
        refreshToken: decryptSecret(s.refreshToken),
      };
    }
    return { ...base, auth: "password", pass: decryptSecret(s.secret) };
  } catch {
    // Undecryptable (key rotated, record edited) — drop it from the usable list rather than
    // handing IMAP a garbage password and getting the account locked for repeated bad logins.
    return null;
  }
}

// MARK: - The resolved list

/** Labels have to stay unique: they're how a message says which inbox it came from and how a reply
 *  picks the account to send from. Two "Gmail"s would silently send from whichever sorted first. */
function withUniqueLabels(accts: MailAccount[]): MailAccount[] {
  const seen = new Set<string>();
  return accts.map((a) => {
    let label = a.label;
    if (seen.has(label)) {
      label = a.user; // the address always distinguishes them
      let n = 2;
      while (seen.has(label)) label = `${a.user} (${n++})`;
    }
    seen.add(label);
    return { ...a, label };
  });
}

/**
 * Every mailbox Alfred can reach right now. Env accounts come first and win on address collisions,
 * so adding an address in the app that's already deployed by env doesn't create a duplicate inbox.
 */
export async function resolveAccounts(): Promise<MailAccount[]> {
  const env = envAccounts();
  const taken = new Set(env.map((a) => a.user.toLowerCase()));

  const stored = (await loadStored())
    .map(storedToAccount)
    .filter((a): a is MailAccount => a !== null)
    .filter((a) => !taken.has(a.user.toLowerCase()));

  return withUniqueLabels([...env, ...stored]);
}

export async function mailConfigured(): Promise<boolean> {
  return (await resolveAccounts()).length > 0;
}

/** The account list as the app sees it — no passwords, and marked with what it's allowed to delete. */
export async function accountSummaries(): Promise<AccountSummary[]> {
  return (await resolveAccounts()).map((a) => ({
    id: a.id ?? `env:${a.label}`,
    label: a.label,
    address: a.user,
    provider: a.provider ?? "custom",
    source: a.source,
    removable: a.source === "stored",
  }));
}

// MARK: - Adding and removing

export interface AddAccountInput {
  provider: string;
  address: string;
  password: string;
  label?: string;
  imapHost?: string;
  imapPort?: number;
  smtpHost?: string;
  smtpPort?: number;
}

/** Try a real IMAP login. Adding an account that can't actually log in is the failure worth catching
 *  here rather than at 7am when the briefing quietly comes back empty. */
async function verifyImap(a: { imapHost: string; imapPort: number; user: string; pass: string }): Promise<void> {
  const client = new ImapFlow({
    host: a.imapHost,
    port: a.imapPort,
    secure: true,
    auth: { user: a.user, pass: a.pass },
    logger: false,
  });
  await client.connect();
  try {
    const lock = await client.getMailboxLock("INBOX");
    lock.release();
  } finally {
    try {
      await client.logout();
    } catch {
      /* best effort */
    }
  }
}

/** SMTP is checked separately and non-fatally: a mailbox you can read but not send from is still
 *  worth having, and some providers refuse a bare SMTP handshake while accepting real sends. */
async function verifySmtp(a: { smtpHost: string; smtpPort: number; user: string; pass: string }): Promise<string | null> {
  try {
    const transport = nodemailer.createTransport({
      host: a.smtpHost,
      port: a.smtpPort,
      secure: false,
      requireTLS: true,
      auth: { user: a.user, pass: a.pass },
    });
    await transport.verify();
    return null;
  } catch (e: any) {
    return String(e?.message ?? e);
  }
}

export interface AddAccountResult {
  account: AccountSummary;
  /** Non-fatal problem worth showing — today, only "reading works but sending didn't verify". */
  warning: string | null;
}

export async function addAccount(input: AddAccountInput): Promise<AddAccountResult> {
  if (!kvConfigured()) throw new Error("no account store configured — the deployment needs Upstash (KV_REST_API_URL / KV_REST_API_TOKEN)");
  if (!secretsConfigured()) throw new Error("MAIL_SECRET_KEY is not set, so a password can't be stored safely");

  const address = String(input.address || "").trim();
  const password = String(input.password || "");
  if (!address.includes("@")) throw new Error("that doesn't look like an email address");
  if (!password) throw new Error("an app-specific password is required");

  const preset = providerById(input.provider) ?? providerById("custom")!;
  const imapHost = (input.imapHost || preset.imapHost).trim();
  const smtpHost = (input.smtpHost || preset.smtpHost || imapHost.replace(/^imap/, "smtp")).trim();
  if (!imapHost) throw new Error("an IMAP hostname is required for a custom provider");

  const imapPort = Number(input.imapPort || preset.imapPort) || 993;
  const smtpPort = Number(input.smtpPort || preset.smtpPort) || 587;

  // Reject before verifying: a duplicate is a user mistake, not a credentials problem, and a failed
  // IMAP login on an address that's already working would read as the existing account breaking.
  const existing = await resolveAccounts();
  if (existing.some((a) => a.user.toLowerCase() === address.toLowerCase())) {
    throw new Error(`${address} is already connected`);
  }

  await verifyImap({ imapHost, imapPort, user: address, pass: password });
  const warning = await verifySmtp({ smtpHost, smtpPort, user: address, pass: password });

  const stored: StoredAccount = {
    id: randomUUID(),
    label: (input.label || "").trim() || address,
    provider: preset.id,
    address,
    imapHost,
    imapPort,
    smtpHost,
    smtpPort,
    secret: encryptSecret(password),
    addedAt: new Date().toISOString(),
  };

  const list = await loadStored();
  list.push(stored);
  await saveStored(list);

  return {
    account: { id: stored.id, label: stored.label, address, provider: stored.provider, source: "stored", removable: true },
    warning: warning ? `Reading works, but sending couldn't be verified: ${warning}` : null,
  };
}

/** Returns false when there was no such stored account — an env account can't be removed this way. */
export async function removeAccount(id: string): Promise<boolean> {
  const list = await loadStored();
  const next = list.filter((a) => a.id !== id);
  if (next.length === list.length) return false;
  await saveStored(next);
  return true;
}

// MARK: - Google OAuth accounts

export async function addOAuthAccount(input: {
  email: string;
  refreshToken: string;
  label?: string;
}): Promise<{ account: AccountSummary }> {
  if (!kvConfigured()) throw new Error("no account store configured — the deployment needs Upstash (KV_REST_API_URL / KV_REST_API_TOKEN)");
  if (!secretsConfigured()) throw new Error("MAIL_SECRET_KEY is not set, so a refresh token can't be stored safely");

  const email = String(input.email || "").trim().toLowerCase();
  if (!email.includes("@")) throw new Error("Google didn't return a usable email address");
  if (!input.refreshToken) throw new Error("Google didn't return a refresh token");

  // The consent screen already proved the login; the only real mistake left is a duplicate.
  const existing = await resolveAccounts();
  if (existing.some((a) => a.user.toLowerCase() === email)) {
    throw new Error(`${email} is already connected`);
  }

  const stored: StoredAccount = {
    id: randomUUID(),
    label: (input.label || "").trim() || `Google · ${email}`,
    provider: "google",
    address: email,
    imapHost: "imap.gmail.com",
    imapPort: 993,
    smtpHost: "smtp.gmail.com",
    smtpPort: 587,
    secret: "",
    auth: "oauth",
    refreshToken: encryptSecret(input.refreshToken),
    addedAt: new Date().toISOString(),
  };

  const list = await loadStored();
  list.push(stored);
  await saveStored(list);

  return {
    account: {
      id: stored.id,
      label: stored.label,
      address: email,
      provider: stored.provider,
      source: "stored",
      removable: true,
    },
  };
}
