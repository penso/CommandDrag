#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP=${1:-"$ROOT/build/CommandDrag.app"}
DMG=${2:-"$ROOT/build/CommandDrag-universal.dmg"}
PYTHON=${DMG_PYTHON:-"$ROOT/build/dmg-venv/bin/python"}

if [[ ! -d "$APP" ]]; then echo "App not found: $APP. Run bash build.sh first." >&2; exit 1; fi
if ! "$PYTHON" -c 'import dmgbuild' 2>/dev/null; then
  echo "Install the packaging tools first (see docs/releases.md)." >&2
  exit 1
fi
# dmgbuild writes Finder metadata directly; no Finder/AppleScript access is needed.
"$PYTHON" -m dmgbuild -s "$ROOT/Scripts/dmg-settings.py" \
  -D "app=$APP" -D "background=$ROOT/assets/dmg-background.png" \
  -D "icon=$ROOT/Sources/CommandDrag.icns" "CommandDrag" "$DMG"
hdiutil verify "$DMG"
"$PYTHON" "$ROOT/Scripts/verify-dmg.py" "$DMG"
echo "Built $DMG"
