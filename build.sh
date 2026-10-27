#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ "$(uname -s)" != Darwin ]]; then
  echo "Build this app on macOS 13 or later with Xcode Command Line Tools installed." >&2
  exit 1
fi
APP="$PWD/build/CommandDrag.app"
ARCH_FLAGS=()
for arch in ${ARCHS:-arm64 x86_64}; do
  case "$arch" in
    arm64|x86_64) ARCH_FLAGS+=(-arch "$arch") ;;
    *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
  esac
done
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -O2 \
  "${ARCH_FLAGS[@]}" \
  -mmacosx-version-min=13.0 \
  -framework Cocoa -framework ApplicationServices -framework ServiceManagement \
  Sources/main.m Sources/Focus.m -o "$APP/Contents/MacOS/CommandDrag"
cp Sources/Info.plist "$APP/Contents/Info.plist"
if [[ -n "${APP_VERSION:-}" ]]; then
  [[ "$APP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "APP_VERSION must be X.Y.Z" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${BUILD_NUMBER:-}" ]]; then
  [[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { echo "BUILD_NUMBER must be a positive integer" >&2; exit 1; }
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
cp Sources/CommandDrag.icns "$APP/Contents/Resources/CommandDrag.icns"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
cp LICENSE "$APP/Contents/Resources/LICENSE"
# Set SIGN_IDENTITY to a Developer ID identity for a distributable build.
SIGN_FLAGS=()
if [[ "${SIGN_IDENTITY:--}" != "-" ]]; then SIGN_FLAGS+=(--timestamp); fi
if [[ -n "${SIGN_KEYCHAIN:-}" ]]; then SIGN_FLAGS+=(--keychain "$SIGN_KEYCHAIN"); fi
codesign --force --sign "${SIGN_IDENTITY:--}" --options runtime "${SIGN_FLAGS[@]}" "$APP"
echo "Built $APP"
echo "Copy it to /Applications before granting permissions or enabling launch at login."
