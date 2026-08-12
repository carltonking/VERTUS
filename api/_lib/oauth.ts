// Google OAuth2 for Alfred's mail: the "Sign in with Google" equivalent of the app-specific password
// path in accounts.ts. Letting the owner pick an account on Google's consent screen beats asking for
// an app password — and one consent flow per account is exactly the "add multiple mailboxes" story.
//
// Env: GOOGLE_CLIENT_ID / GOOGLE_CLIENT_SECRET — an OAuth client of type "Web application" from
// Google Cloud Console, with https://oauth2.googleapis.com/token authorized for its redirects and the
// deployment's /api/mail?action=googleCallback registered as a redirect URI.
//
// Two grants: the authorization-code flow (first connect) trades a code for a long-lived refresh
// token, and the refresh flow turns that into the short-lived access token IMAP/SMTP actually
// consume. Gmail over IMAP speaks XOAUTH2 with a regular full-access token — no Gmail API enabled.

const OAUTH_AUTHORIZE = "https://accounts.google.com/o/oauth2/v2/auth";
const OAUTH_TOKEN = "https://oauth2.googleapis.com/token";
const OAUTH_USERINFO = "https://www.googleapis.com/oauth2/v2/userinfo";

/** Full mailbox access. IMAP XOAUTH2 and SMTP OAuth2 both authenticate with it. */
const MAIL_SCOPE = "https://mail.google.com/";
/** Enough identity to read the signed-in address back — IMAP doesn't tell us who we are. */
const IDENTITY_SCOPE = "https://www.googleapis.com/auth/userinfo.email";

async function tokenPost(params: Record<string, string>): Promise<{ [k: string]: any } | null> {
  const clientId = (process.env.GOOGLE_CLIENT_ID || "").trim();
  const clientSecret = (process.env.GOOGLE_CLIENT_SECRET || "").trim();
  if (!clientId || !clientSecret) return null;

  const body = new URLSearchParams({
    client_id: clientId,
    client_secret: clientSecret,
    ...params,
  });

  const res = await fetch(OAUTH_TOKEN, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body,
    signal: AbortSignal.timeout(15_000),
  });
  const json: any = await res.json().catch(() => null);
  if (!res.ok || !json) {
    const detail = json?.error_description || json?.error || `HTTP ${res.status}`;
    throw new Error(`Google token endpoint rejected the request: ${detail}`);
  }
  return json;
}

/** Both Google clients set, so the OAuth path is usable at all. */
export function googleOAuthConfigured(): boolean {
  return !!(process.env.GOOGLE_CLIENT_ID && process.env.GOOGLE_CLIENT_SECRET);
}

/**
 * The redirect URI Google must send the code to. Built from the live request host, so it is the
 * exact deployment URL the owner registered in the Console; the callback handler passes the same
 * value back to Google when exchanging, or the exchange is rejected.
 */
export function oauthRedirectUri(hostHeader: string | undefined): string {
  const host = String(hostHeader || "").trim().replace(/^https?:\/\//, "");
  return `https://${host}/api/mail?action=googleCallback`;
}

/** The consent URL to open in the owner's browser. */
export function googleAuthUrl(opts: { state: string; redirectUri: string }): string {
  const url = new URL(OAUTH_AUTHORIZE);
  url.searchParams.set("client_id", (process.env.GOOGLE_CLIENT_ID || "").trim());
  url.searchParams.set("redirect_uri", opts.redirectUri);
  url.searchParams.set("response_type", "code");
  url.searchParams.set("scope", `${IDENTITY_SCOPE} ${MAIL_SCOPE}`);
  url.searchParams.set("access_type", "offline");
  url.searchParams.set("prompt", "consent"); // forces a refresh token on re-consent, never just a cookie
  url.searchParams.set("state", opts.state);
  url.searchParams.set("include_granted_scopes", "true");
  return url.toString();
}

/** Trade the authorization code from the consent callback for a refresh token (offline grant). */
export async function exchangeOAuthCode(code: string, redirectUri: string): Promise<{
  refreshToken: string;
  accessToken: string;
}> {
  const json = await tokenPost({
    code,
    redirect_uri: redirectUri,
    grant_type: "authorization_code",
  });
  if (!json?.refresh_token || !json?.access_token) {
    throw new Error("Google didn't return a usable token — try signing in again");
  }
  return { refreshToken: String(json.refresh_token), accessToken: String(json.access_token) };
}

/** The signed-in user's address, from the identity scope in the access token. */
export async function googleUserEmail(accessToken: string): Promise<string> {
  const res = await fetch(OAUTH_USERINFO, {
    headers: { Authorization: `Bearer ${accessToken}` },
    signal: AbortSignal.timeout(15_000),
  });
  const json: any = await res.json().catch(() => null);
  const email = String(json?.email || "").trim().toLowerCase();
  if (!email || !email.includes("@")) throw new Error("Google didn't return an email address");
  return email;
}

/** A fresh, short-lived access token from a stored refresh token — what each IMAP/SMTP call needs. */
export async function googleAccessToken(refreshToken: string): Promise<string> {
  const json = await tokenPost({
    refresh_token: refreshToken,
    grant_type: "refresh_token",
  });
  if (!json?.access_token) throw new Error("Google wouldn't refresh this account's access token");
  return String(json.access_token);
}