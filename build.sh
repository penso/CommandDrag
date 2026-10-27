#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build this app on macOS 13 or later with Xcode Command Line Tools installed." >&2
  exit 1
fi
APP="$PWD/build/CommandDrag.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  -mmacosx-version-min=13.0 \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
  Sources/main.m -o "$APP/Contents/MacOS/CommandDrag"
cp Sources/Info.plist "$APP/Contents/Info.plist"
cp Sources/CommandDrag.icns "$APP/Contents/Resources/CommandDrag.icns"
# Set SIGN_IDENTITY to a Developer ID identity for a distributable build.
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "$APP"
echo "Built $APP"
echo "Copy it to /Applications before granting permissions or enabling launch at login."
