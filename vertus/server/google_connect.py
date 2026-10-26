"""Connect a Google account to VERTUS with one tap — the hub runs the sign-in.

Instinct-style: the agent texts a link; the user taps it on their phone,
picks the Google account and approves; Google redirects to the hub, which
exchanges the code and saves the token the google-workspace skill reads. No
model drives any of it (a small local model cannot be trusted to), and the
user never copies a code back.

The redirect lands on the Mac's private HTTPS name on the user's tailnet
(Tailscale Serve forwards /connect/ to the hub), so it works from the phone
and from nowhere else. Google requires a "Web application" OAuth client whose
redirect URI is exactly ``callback_url()``; its JSON lives at
``~/.vertus/google_client_secret.json``.
"""

from __future__ import annotations

import json
import os
import secrets
import shutil
import subprocess
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover
    from . import vertus_paths  # type: ignore

# The scopes the google-workspace skill's setup asks for, plus who signed in.
SCOPES = [
    "openid", "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/gmail.readonly",
    "https://www.googleapis.com/auth/gmail.send",
    "https://www.googleapis.com/auth/gmail.modify",
    "https://www.googleapis.com/auth/calendar",
    "https://www.googleapis.com/auth/drive",
    "https://www.googleapis.com/auth/contacts.readonly",
    "https://www.googleapis.com/auth/spreadsheets",
    "https://www.googleapis.com/auth/documents",
]
AUTH_URI = "https://accounts.google.com/o/oauth2/v2/auth"
TOKEN_URI = "https://oauth2.googleapis.com/token"
USERINFO_URI = "https://openidconnect.googleapis.com/v1/userinfo"
LINK_TTL_S = 15 * 60

_pending: dict[str, float] = {}
_lock = threading.Lock()


class ConnectError(RuntimeError):
    pass


def client_secret_path() -> Path:
    return vertus_paths.vertus_root() / "google_client_secret.json"


def accounts_dir() -> Path:
    return vertus_paths.vertus_root() / "google" / "accounts"


def public_base() -> str:
    """https://<mac>.<tailnet>.ts.net — VERTUS_PUBLIC_URL, else Tailscale's name."""
    env = os.environ.get("VERTUS_PUBLIC_URL", "").strip().rstrip("/")
    if env:
        return env
    tailscale = shutil.which("tailscale") or "/opt/homebrew/bin/tailscale"
    try:
        out = subprocess.run([tailscale, "status", "--json"], capture_output=True, text=True, timeout=10)
        name = (json.loads(out.stdout).get("Self") or {}).get("DNSName", "").rstrip(".")
    except (OSError, ValueError, subprocess.SubprocessError):
        name = ""
    if not name:
        raise ConnectError("Tailscale is not running, so the phone cannot reach the sign-in page.")
    return f"https://{name}"


def callback_url() -> str:
    return public_base() + "/connect/google/callback"


def _client() -> dict:
    try:
        raw = json.loads(client_secret_path().read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise ConnectError(f"No Google client found at {client_secret_path()}.") from exc
    client = raw.get("web") or raw.get("installed") or {}
    if not client.get("client_id") or not client.get("client_secret"):
        raise ConnectError("The Google client file has no client_id/client_secret.")
    return client


def mint_link(now: float | None = None) -> str:
    """A one-time link to text the user; valid for LINK_TTL_S."""
    _client()  # fail now, in chat, rather than on the phone
    now = time.time() if now is None else now
    state = secrets.token_urlsafe(24)
    with _lock:
        for key in [k for k, exp in _pending.items() if exp < now]:
            del _pending[key]
        _pending[state] = now + LINK_TTL_S
    return f"{public_base()}/connect/google/start?s={state}"


def consent_url(state: str, now: float | None = None) -> str:
    """Where /connect/google/start sends the browser (state must be live)."""
    now = time.time() if now is None else now
    with _lock:
        if _pending.get(state, 0) < now:
            raise ConnectError("This link has expired. Ask VERTUS for a new one.")
    client = _client()
    return AUTH_URI + "?" + urllib.parse.urlencode({
        "client_id": client["client_id"], "redirect_uri": callback_url(),
        "response_type": "code", "scope": " ".join(SCOPES), "state": state,
        "access_type": "offline", "prompt": "consent select_account", "include_granted_scopes": "true",
    })


def _post_form(url: str, data: dict) -> dict:
    req = urllib.request.Request(url, data=urllib.parse.urlencode(data).encode(), method="POST",
                                 headers={"Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def _get_json(url: str, token: str) -> dict:
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req, timeout=20) as resp:
        return json.loads(resp.read())


def complete(state: str, code: str, homes: list[Path], now: float | None = None,
             post=_post_form, get=_get_json) -> str:
    """Exchange the code, save the token for every agent home; returns the email."""
    now = time.time() if now is None else now
    with _lock:
        live = _pending.pop(state, 0) >= now
    if not live or not code:
        raise ConnectError("This sign-in link has expired or was already used.")
    client = _client()
    tokens = post(TOKEN_URI, {"code": code, "client_id": client["client_id"],
                              "client_secret": client["client_secret"],
                              "redirect_uri": callback_url(), "grant_type": "authorization_code"})
    if not tokens.get("refresh_token"):
        raise ConnectError("Google did not grant offline access; try the link again.")
    email = str(get(USERINFO_URI, tokens["access_token"]).get("email") or "unknown")
    authorized_user = {
        "type": "authorized_user", "token": tokens["access_token"],
        "refresh_token": tokens["refresh_token"], "token_uri": TOKEN_URI,
        "client_id": client["client_id"], "client_secret": client["client_secret"],
        "scopes": [s for s in SCOPES if s.startswith("https://www.googleapis.com/auth/")
                   and "userinfo" not in s],
        "expiry": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(now + int(tokens.get("expires_in", 3600)))),
        "account": email,
    }
    payload = json.dumps(authorized_user, indent=2)
    accounts_dir().mkdir(parents=True, exist_ok=True)
    _write_private(accounts_dir() / f"{email}.json", payload)
    for home in homes:
        target = home / "google_token.json"
        if target.is_symlink():
            target = target.resolve()
        _write_private(target, payload)
        _write_private(home / "google_client_secret.json" if not (home / "google_client_secret.json").is_symlink()
                       else (home / "google_client_secret.json").resolve(),
                       client_secret_path().read_text(encoding="utf-8"))
    return email


def _write_private(path: Path, text: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(text, encoding="utf-8")
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)


def page(title: str, body: str) -> bytes:
    return (f"<!doctype html><meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<title>{title}</title><body style='font:17px -apple-system;padding:40px;"
            f"background:#000;color:#fff'><h2>{title}</h2><p>{body}</p></body>").encode()
