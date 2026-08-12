#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<USAGE
Usage: ./scripts/generate_app_icon.sh [--source PATH] [--output PATH]

Generates Alfred/Resources/AppIcon.icns from an existing PNG logo using macOS
tools only. The script does not overwrite source logo assets.

Options:
  --source PATH   Source PNG. Defaults to Alfred/Resources/alfred-big-logo.png.
  --output PATH   Output .icns. Defaults to Alfred/Resources/AppIcon.icns.
  -h, --help      Show this help.
USAGE
}

step() { echo; echo "▶ $*"; }
ok() { echo "  ✓ $*"; }
die() { echo "✗ ERROR: $*" >&2; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "$SCRIPT_DIR")"
SOURCE="$(dirname "$REPO_ROOT")/Logos/small logo.png"
OUTPUT="$REPO_ROOT/Alfred/Resources/AppIcon.icns"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      SOURCE="${2:?--source requires a path}"
      shift 2
      ;;
    --output)
      OUTPUT="${2:?--output requires a path}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

[[ -f "$SOURCE" ]] || die "Source PNG not found: $SOURCE"
command -v sips >/dev/null 2>&1 || die "sips is required and was not found"
command -v iconutil >/dev/null 2>&1 || die "iconutil is required and was not found"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/alfred-iconset.XXXXXX")"
ICONSET="$WORK_DIR/AppIcon.iconset"
mkdir -p "$ICONSET"
trap 'rm -rf "$WORK_DIR"' EXIT

step "Generating iconset from $(basename "$SOURCE")"

make_icon() {
  local points="$1"
  local scale="$2"
  local pixels=$((points * scale))
  local suffix=""
  if [[ "$scale" -eq 2 ]]; then
    suffix="@2x"
  fi
  sips -s format png -z "$pixels" "$pixels" --padToHeightWidth "$pixels" "$pixels" "$SOURCE" --out "$ICONSET/icon_${points}x${points}${suffix}.png" >/dev/null
}

make_icon 16 1
make_icon 16 2
make_icon 32 1
make_icon 32 2
make_icon 128 1
make_icon 128 2
make_icon 256 1
make_icon 256 2
make_icon 512 1
make_icon 512 2

step "Writing $(basename "$OUTPUT")"
mkdir -p "$(dirname "$OUTPUT")"
if ! iconutil -c icns "$ICONSET" -o "$OUTPUT" 2>/dev/null; then
  echo "  iconutil rejected the iconset; falling back to sips ICNS conversion."
  sips -s format png -z 1024 1024 --padToHeightWidth 1024 1024 "$SOURCE" --out "$WORK_DIR/AppIcon-1024.png" >/dev/null
  sips -s format icns "$WORK_DIR/AppIcon-1024.png" --out "$OUTPUT" >/dev/null
fi
ok "Generated $OUTPUT"
