#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

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

notarize() {
  local target=$1 status=0 submission_id
  xcrun notarytool submit "$target" \
    --key "$TEMP_DIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" \
    --wait --timeout 20m --output-format json > "$TEMP_DIR/notarization.json" || status=$?
  if [[ "$status" != 0 ]] || [[ "$(plutil -extract status raw -o - "$TEMP_DIR/notarization.json")" != "Accepted" ]]; then
    cat "$TEMP_DIR/notarization.json"
    submission_id=$(plutil -extract id raw -o - "$TEMP_DIR/notarization.json" 2>/dev/null) || submission_id=""
    if [[ -n "$submission_id" ]]; then
      xcrun notarytool log "$submission_id" \
        --key "$TEMP_DIR/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER_ID" || true
    fi
    exit 1
  fi
}

staple() {
  local target=$1 attempt
  # Apple's ticket service can briefly drop connections or lag after acceptance.
  for attempt in 1 2 3 4; do
    # Validation also contacts Apple's ticket service and can fail transiently.
    if xcrun stapler staple "$target" && xcrun stapler validate "$target"; then
      return 0
    fi
    if [[ "$attempt" -lt 4 ]]; then
      echo "Ticket stapling or validation failed; retrying in $((attempt * 10)) seconds…" >&2
      sleep "$((attempt * 10))"
    fi
  done
  echo "Could not staple and validate the notarization ticket: $target" >&2
  return 1
}

ditto -c -k --sequesterRsrc --keepParent "$APP" "$TEMP_DIR/notarize.zip"
notarize "$TEMP_DIR/notarize.zip"
staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

ARCHIVE="CommandDrag-${RELEASE_TAG}-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "build/$ARCHIVE"
DMG="CommandDrag-${RELEASE_TAG}-universal.dmg"
bash Scripts/package-dmg.sh "$APP" "build/$DMG"
codesign --force --sign "$SIGN_IDENTITY" --keychain "$KEYCHAIN" --timestamp "build/$DMG"
codesign --verify --strict --verbose=2 "build/$DMG"
notarize "build/$DMG"
staple "build/$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "build/$DMG"
(cd build && shasum -a 256 "$ARCHIVE" "$DMG" > SHA256SUMS)
