"""One-tap Google sign-in run by the hub (google_connect.py)."""
from __future__ import annotations
import json, sys, urllib.parse
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))  # noqa: E402
import pytest  # noqa: E402
import google_connect as gc  # noqa: E402


@pytest.fixture()
def env(tmp_path, monkeypatch):
    monkeypatch.setenv("VERTUS_ROOT", str(tmp_path))
    monkeypatch.setenv("VERTUS_PUBLIC_URL", "https://mac.tail.ts.net")
    (tmp_path / "google_client_secret.json").write_text(json.dumps(
        {"web": {"client_id": "cid", "client_secret": "csec"}}))
    gc._pending.clear()
    return tmp_path


def _state(link):
    return urllib.parse.parse_qs(urllib.parse.urlsplit(link).query)["s"][0]


def test_link_leads_to_google_consent_with_the_hub_callback(env):
    link = gc.mint_link(now=100)
    assert link.startswith("https://mac.tail.ts.net/connect/google/start?s=")
    url = gc.consent_url(_state(link), now=101)
    q = urllib.parse.parse_qs(urllib.parse.urlsplit(url).query)
    assert url.startswith(gc.AUTH_URI) and q["client_id"] == ["cid"]
    assert q["redirect_uri"] == ["https://mac.tail.ts.net/connect/google/callback"]
    assert q["access_type"] == ["offline"] and "gmail.send" in q["scope"][0]


def test_completing_saves_the_token_the_skill_reads_for_every_home(env):
    homes = [env / "a" / "home", env / "b" / "home"]
    state = _state(gc.mint_link(now=100))
    post = lambda url, data: {"access_token": "at", "refresh_token": "rt", "expires_in": 3600}  # noqa: E731
    get = lambda url, tok: {"email": "me@gmail.com"}  # noqa: E731
    assert gc.complete(state, "code", homes, now=101, post=post, get=get) == "me@gmail.com"
    for home in homes:
        tok = json.loads((home / "google_token.json").read_text())
        assert tok["refresh_token"] == "rt" and tok["client_id"] == "cid" and tok["type"] == "authorized_user"
        assert (home / "google_token.json").stat().st_mode & 0o777 == 0o600
    assert (env / "google" / "accounts" / "me@gmail.com.json").is_file()
    with pytest.raises(gc.ConnectError):  # a link works once
        gc.complete(state, "code", homes, now=102, post=post, get=get)


def test_expired_or_unknown_links_are_refused(env):
    state = _state(gc.mint_link(now=100))
    with pytest.raises(gc.ConnectError):
        gc.consent_url(state, now=100 + gc.LINK_TTL_S + 1)
    with pytest.raises(gc.ConnectError):
        gc.consent_url("forged", now=101)


def test_no_client_file_fails_in_chat_not_on_the_phone(env):
    (env / "google_client_secret.json").unlink()
    with pytest.raises(gc.ConnectError):
        gc.mint_link()


@pytest.mark.parametrize("text", ["connect my google account", "Link my Gmail please",
                                  "can you sign in to google for me", "gmail connect", "set up google calendar"])
def test_connect_requests_get_the_real_link(env, text):
    out = gc.rewrite_prompt(text)
    assert "Do not use any tools" in out and "https://mac.tail.ts.net/connect/google/start?s=" in out


@pytest.mark.parametrize("text", ["what's on my calendar", "search google for ramen near nyu",
                                  "summarize my unread email"])
def test_other_requests_pass_through(env, text):
    assert gc.rewrite_prompt(text) == text


def test_imessage_plugin_matches_the_same_requests():
    import importlib.util
    plugin = Path(__file__).resolve().parents[1] / "hermes-plugins" / "vertus-intents" / "__init__.py"
    spec = importlib.util.spec_from_file_location("vi", plugin)
    vi = importlib.util.module_from_spec(spec); spec.loader.exec_module(vi)
    assert vi.wants_google_connect("connect my google account")
    assert not vi.wants_google_connect("search google for ramen")
    assert "Tap to connect your Google account: https://x" in vi.instruction("https://x", None)
