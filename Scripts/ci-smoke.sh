#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"
swift build -c release

SMOKE_APP="$ROOT_DIR/.build/ThermalForge-smoke.app"
rm -rf "$SMOKE_APP"
"$ROOT_DIR/Scripts/build-app-bundle.sh" "$SMOKE_APP"
plutil -lint "$SMOKE_APP/Contents/Info.plist" >/dev/null

test -x "$SMOKE_APP/Contents/MacOS/ThermalForgeApp"
test -x "$SMOKE_APP/Contents/Resources/thermalforge"
"$SMOKE_APP/Contents/Resources/thermalforge" --help > "$ROOT_DIR/.build/smoke-help.txt"
/usr/bin/grep -q 'recovery' "$ROOT_DIR/.build/smoke-help.txt"
if find "$SMOKE_APP" -iname '*fixture*' | /usr/bin/grep . >/dev/null; then
  echo "ERROR: integration fixtures leaked into the app bundle" >&2
  exit 1
fi
codesign --verify --deep --strict "$SMOKE_APP"
echo "CI smoke checks passed."
