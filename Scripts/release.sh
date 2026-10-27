#!/bin/bash
set -euo pipefail
cd "${SOURCE_DIR:-$(dirname "$0")/..}"

# Secrets are supplied by GitHub Actions, never written into the repository.
for name in RELEASE_TAG DEVELOPER_ID_CERTIFICATE_BASE64 DEVELOPER_ID_CERTIFICATE_PASSWORD \
  DEVELOPER_ID_APPLICATION APPLE_API_KEY_ID APPLE_API_ISSUER_ID APPLE_API_PRIVATE_KEY BUILD_NUMBER; do
  if [[ -z "${!name:-}" ]]; then echo "Missing required configuration: $name" >&2; exit 1; fi
done
[[ "$RELEASE_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9]+(\.[a-zA-Z0-9]+)*)?$ ]] || {
  echo "Invalid release tag" >&2; exit 1;
}

umask 077
TEMP_DIR=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/commanddrag-release.XXXXXX")
KEYCHAIN="$TEMP_DIR/signing.keychain-db"
ORIGINAL_KEYCHAINS=()
while IFS= read -r keychain; do
  ORIGINAL_KEYCHAINS+=("$keychain")
done < <(security list-keychains -d user | sed 's/^[[:space:]]*"//; s/"[[:space:]]*$//')
cleanup() {
  security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" >/dev/null 2>&1 || true
  security delete-keychain "$KEYCHAIN" >/dev/null 2>&1 || true
  rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

KEYCHAIN_PASSWORD=$(openssl rand -hex 24)
printf '%s' "$DEVELOPER_ID_CERTIFICATE_BASE64" | base64 --decode > "$TEMP_DIR/certificate.p12"
printf '%s' "$APPLE_API_PRIVATE_KEY" > "$TEMP_DIR/AuthKey.p8"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
security import "$TEMP_DIR/certificate.p12" -k "$KEYCHAIN" \
  -P "$DEVELOPER_ID_CERTIFICATE_PASSWORD" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
IDENTITIES=$(security find-identity -v -p codesigning "$KEYCHAIN")
printf '%s\n' "$IDENTITIES"
if ! grep -Fq "\"$DEVELOPER_ID_APPLICATION\"" <<< "$IDENTITIES"; then
  echo "The imported certificate does not match DEVELOPER_ID_APPLICATION, or is not valid for signing." >&2
  exit 1
fi

umask 022
VERSION=${RELEASE_TAG#v}
export APP_VERSION=${VERSION%%-*}
export SIGN_IDENTITY="$DEVELOPER_ID_APPLICATION"
export SIGN_KEYCHAIN="$KEYCHAIN"
export ARCHS="arm64 x86_64"
bash build.sh
APP=build/CommandDrag.app
for arch in arm64 x86_64; do
  lipo "$APP/Contents/MacOS/CommandDrag" -verify_arch "$arch"
done
codesign --verify --strict --verbose=2 "$APP"

ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP_DIR/notarize.zip"
SUBMIT_STATUS=0
xcrun notarytool submit "$TEMP_DIR/notarize.zip" \
  --key "$TEMP_DIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
  --wait --timeout 20m --output-format json > "$TEMP_DIR/notarization.json" || SUBMIT_STATUS=$?
if [[ "$SUBMIT_STATUS" != 0 ]] || [[ "$(plutil -extract status raw -o - "$TEMP_DIR/notarization.json")" != "Accepted" ]]; then
  cat "$TEMP_DIR/notarization.json"
  SUBMISSION_ID=$(plutil -extract id raw -o - "$TEMP_DIR/notarization.json" 2>/dev/null) || SUBMISSION_ID=""
  if [[ -n "$SUBMISSION_ID" ]]; then
    xcrun notarytool log "$SUBMISSION_ID" \
      --key "$TEMP_DIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" || true
  fi
  exit 1
fi
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ARCHIVE="CommandDrag-${RELEASE_TAG}-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ARCHIVE"
(cd build && shasum -a 256 "$ARCHIVE" > SHA256SUMS)
