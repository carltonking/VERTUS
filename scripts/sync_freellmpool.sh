#!/usr/bin/env bash
# Sync the vendored freellmpool copy in this repo to the latest upstream
# release from https://github.com/0xzr/freellmpool (MIT).
#
# Alfred vendors freellmpool so the cloud API and the Mac's Hermes sessions
# always run a pinned, reviewed copy rather than whatever pip resolves.
# Run this after upstream cuts a new release, then commit the diff.
#
# Usage:  ./scripts/sync_freellmpool.sh          # sync + report
#         ./scripts/sync_freellmpool.sh --check  # just report drift
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDORED="$REPO_ROOT/freellmpool"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

step() { echo "▶ $*"; }
ok()   { echo "  ✓ $*"; }
warn() { echo "  ⚠ $*"; }

git clone --depth 1 --quiet https://github.com/0xzr/freellmpool "$TMP/upstream"
UPSTREAM_VERSION="$(grep -m1 '^version' "$TMP/upstream/pyproject.toml" | sed 's/.*= *"\(.*\)".*/\1/')"
VENDORED_VERSION="$(grep -m1 '^version' "$VENDORED/pyproject.toml" | sed 's/.*= *"\(.*\)".*/\1/')"

step "upstream: $UPSTREAM_VERSION  vendored: $VENDORED_VERSION"
if [ "$UPSTREAM_VERSION" = "$VENDORED_VERSION" ]; then
  ok "versions match — checking tree drift…"
else
  warn "version bump $VENDORED_VERSION → $UPSTREAM_VERSION"
fi

# Compare the shipped package tree. __pycache__ is build noise — ignore it.
DIFFS="$(diff -rq "$TMP/upstream/src" "$VENDORED/src" 2>/dev/null | grep -v '__pycache__' || true)"
if [ -z "$DIFFS" ]; then
  ok "source trees are identical"
else
  if [ "${1:-}" = "--check" ]; then
    echo "$DIFFS"
    warn "drift found — run without --check to apply"
    exit 1
  fi
  echo "$DIFFS"
  warn "applying upstream changes…"
  rsync -a --delete --exclude '__pycache__' "$TMP/upstream/src/" "$VENDORED/src/"
  cp "$TMP/upstream/pyproject.toml" "$VENDORED/pyproject.toml"
  cp "$TMP/upstream/README.md" "$VENDORED/README.md" 2>/dev/null || true
  ok "synced to $UPSTREAM_VERSION — review with: git diff freellmpool/"
fi
