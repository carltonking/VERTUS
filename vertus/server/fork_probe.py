"""One-shot completion through the fork's own provider machinery.

Shared by the doctor's provider-health probe (``vertus_doctor.provider_checks``)
and the hub's automatic memory capture (``memory_capture.py``): a tiny Python
snippet run with the FORK'S venv python, cwd in the fork repo, resolving the
provider through ``hermes_cli`` — the same registry, base URLs, and key env
vars the engine itself uses — with retries disabled and a bounded timeout so a
hung provider can never leak the fork's 600s silent retry loop into the hub.

The key is read from the scope's ``.env`` (fleet home or agent home — the same
file the hub seeds each gateway with), never from the hub env.

``run_completion`` is deliberately provider-agnostic: the script speaks the
OpenAI chat-completions dialect against the resolved ``base_url`` (exactly what
the doctor's probe did before this module existed). Providers the fork routes
through a non-OpenAI-compatible endpoint report their error the same way the
doctor already surfaces it; capture treats any failure as "nothing to remember".
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

try:
    import vertus_paths  # type: ignore
except ImportError:  # pragma: no cover - only hit under package invocation
    from . import vertus_paths  # type: ignore

PROBE_SCRIPT = r'''
import json, os, sys, time

def _load_env_file(path):
    if not path:
        return
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                os.environ.setdefault(k.strip(), v.strip())
    except OSError:
        pass

_load_env_file(os.environ.get("VERTUS_PROBE_ENV_FILE", ""))
provider = os.environ.get("VERTUS_PROBE_PROVIDER", "")
model = os.environ.get("VERTUS_PROBE_MODEL", "")
base_url = os.environ.get("VERTUS_PROBE_BASE_URL", "")
key_vars: list = []
try:
    from hermes_cli.auth import PROVIDER_REGISTRY
    p = PROVIDER_REGISTRY.get(provider)
    if p is not None and getattr(p, "api_key_env_vars", None):
        key_vars = list(p.api_key_env_vars)
except Exception:
    pass
pdef = None
try:
    from hermes_cli.providers import get_provider
    pdef = get_provider(provider, allow_network=False)
except Exception as exc:
    print(json.dumps({"ok": False, "kind": "resolve_error",
                      "detail": str(exc)[:200]}))
    sys.exit(2)
if not base_url:
    base_url = (pdef.base_url if pdef is not None else "") or ""
if not key_vars and pdef is not None:
    key_vars = list(pdef.api_key_env_vars or ())
if pdef is None and not key_vars:
    print(json.dumps({"ok": False, "kind": "unknown_provider",
                      "detail": provider}))
    sys.exit(2)
key = None
for var in key_vars:
    if os.environ.get(var):
        key = os.environ[var]
        break
if not key:
    print(json.dumps({"ok": False, "kind": "no_key",
                      "detail": ",".join(key_vars)}))
    sys.exit(2)
if not base_url:
    print(json.dumps({"ok": False, "kind": "no_base_url",
                      "detail": provider}))
    sys.exit(2)
import openai
try:
    client = openai.OpenAI(
        api_key=key, base_url=base_url,
        timeout=float(os.environ.get("VERTUS_PROBE_TIMEOUT_S", "8")),
        max_retries=0,
    )
    system = os.environ.get("VERTUS_PROBE_SYSTEM", "")
    user = os.environ.get("VERTUS_PROBE_USER", "ping")
    try:
        max_tokens = int(os.environ.get("VERTUS_PROBE_MAX_TOKENS", "1"))
    except ValueError:
        max_tokens = 1
    messages = []
    if system:
        messages.append({"role": "system", "content": system})
    messages.append({"role": "user", "content": user})
    t0 = time.monotonic()
    resp = client.chat.completions.create(
        model=model, max_tokens=max_tokens, messages=messages,
    )
    text = ""
    try:
        text = resp.choices[0].message.content or ""
    except Exception:
        pass
    print(json.dumps({"ok": True,
                      "model": getattr(resp, "model", None) or model,
                      "latency_s": round(time.monotonic() - t0, 2),
                      "text": text}))
except openai.APITimeoutError as exc:
    print(json.dumps({"ok": False, "kind": "hang",
                      "detail": str(exc)[:200]}))
    sys.exit(1)
except Exception as exc:
    status = ""
    body = ""
    if hasattr(exc, "response"):
        r = exc.response
        try:
            status = str(getattr(r, "status_code", ""))
        except Exception:
            pass
        try:
            body = (getattr(r, "text", "") or "")[:600]
        except Exception:
            pass
    print(json.dumps({"ok": False, "kind": "http_error",
                      "status": status, "body": body,
                      "detail": str(exc)[:300]}))
    sys.exit(1)
'''


def run_completion(
    cfg: dict,
    timeout_s: float,
    base_url_override: str = "",
    system: str | None = None,
    user: str = "ping",
    max_tokens: int = 1,
) -> dict:
    """One completion against one config, through the fork's venv.

    ``cfg`` carries ``provider``, ``model``, and ``home`` (the engine home
    whose ``.env`` holds the key and whose ``config.yaml`` named the
    provider/model). Returns the parsed JSON dict the script prints:

      ok      → {"ok": True, "model", "latency_s", "text"}
      failure → {"ok": False, "kind": hang|http_error|no_key|resolve_error|
                 unknown_provider|no_base_url|script_error, ...}

    The subprocess timeout is ``timeout_s + 10`` of import slack; the probe's
    OWN client timeout (``max_retries=0``) is what actually bounds the call —
    the fork's 600s retry sleep can never leak in because retries are disabled
    at the client.
    """
    venv_py = vertus_paths.venv_python()
    fork = vertus_paths.fork_repo()
    env = dict(os.environ)
    env.update({
        "VERTUS_PROBE_PROVIDER": cfg.get("provider") or "",
        "VERTUS_PROBE_MODEL": cfg.get("model") or "",
        "VERTUS_PROBE_ENV_FILE": str(cfg["home"] / ".env"),
        "VERTUS_PROBE_TIMEOUT_S": str(timeout_s),
        "VERTUS_PROBE_BASE_URL": base_url_override,
        "VERTUS_PROBE_USER": user,
        "VERTUS_PROBE_MAX_TOKENS": str(max_tokens),
    })
    if system is not None:
        env["VERTUS_PROBE_SYSTEM"] = system
    try:
        r = subprocess.run(
            [str(venv_py), "-u", "-c", PROBE_SCRIPT],
            cwd=str(fork), env=env, capture_output=True, text=True,
            timeout=timeout_s + 10, check=False,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "kind": "hang",
                "detail": f"probe subprocess exceeded {timeout_s + 10:.0f}s"}
    except Exception as exc:
        return {"ok": False, "kind": "script_error", "detail": str(exc)[:200]}
    try:
        return json.loads(r.stdout.strip().splitlines()[-1] or "{}")
    except Exception:
        return {"ok": False, "kind": "script_error",
                "detail": (r.stderr or r.stdout).strip()[-200:]}