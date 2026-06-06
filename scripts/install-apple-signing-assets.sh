#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${RUNNER_TEMP:-"$ROOT_DIR/build/apple-signing"}"
KEYCHAIN_NAME="${APPLE_SIGNING_KEYCHAIN_NAME:-vk-turn-proxy-signing.keychain-db}"
KEYCHAIN_PASSWORD="${APPLE_SIGNING_KEYCHAIN_PASSWORD:-$(uuidgen)}"
CERT_BASE64="${APPLE_DISTRIBUTION_CERT_P12_BASE64:-}"
CERT_PASSWORD="${APPLE_DISTRIBUTION_CERT_PASSWORD:-}"
PROFILES_BASE64="${APPLE_PROVISIONING_PROFILES_BASE64:-}"
APPSTORE_KEY_ID="${APPSTORE_KEY_ID:-}"
APPSTORE_ISSUER_ID="${APPSTORE_ISSUER_ID:-}"
APPSTORE_KEY_BASE64="${APPSTORE_CONNECT_API_KEY_P8_BASE64:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/install-apple-signing-assets.sh

Required environment:
  APPLE_DISTRIBUTION_CERT_P12_BASE64    base64-encoded Apple Distribution .p12
  APPLE_DISTRIBUTION_CERT_PASSWORD      .p12 import password
  APPLE_PROVISIONING_PROFILES_BASE64    base64-encoded zip with .mobileprovision/.provisionprofile files
  APPSTORE_KEY_ID                       App Store Connect API key id
  APPSTORE_ISSUER_ID                    App Store Connect issuer UUID
  APPSTORE_CONNECT_API_KEY_P8_BASE64    base64-encoded AuthKey_<key-id>.p8

Optional:
  APPLE_SIGNING_KEYCHAIN_NAME
  APPLE_SIGNING_KEYCHAIN_PASSWORD
EOF
}

decode_base64() {
  local input="$1"
  local output="$2"
  if base64 --decode <<<"$input" >"$output" 2>/dev/null; then
    return 0
  fi
  if base64 -D <<<"$input" >"$output" 2>/dev/null; then
    return 0
  fi
  echo "ERROR: base64 decode failed for $output" >&2
  return 1
}

require_env() {
  local name="$1"
  if [[ -z "${!name:-}" ]]; then
    echo "ERROR: $name is required." >&2
    usage
    exit 64
  fi
}

require_env APPLE_DISTRIBUTION_CERT_P12_BASE64
require_env APPLE_DISTRIBUTION_CERT_PASSWORD
require_env APPLE_PROVISIONING_PROFILES_BASE64
require_env APPSTORE_KEY_ID
require_env APPSTORE_ISSUER_ID
require_env APPSTORE_CONNECT_API_KEY_P8_BASE64

if [[ ! "$APPSTORE_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
  echo "ERROR: APPSTORE_KEY_ID should be a 10-character App Store Connect key id." >&2
  exit 64
fi
if [[ ! "$APPSTORE_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
  echo "ERROR: APPSTORE_ISSUER_ID should be a UUID." >&2
  exit 64
fi

mkdir -p "$WORK_DIR"
chmod 700 "$WORK_DIR"

cert_path="$WORK_DIR/apple-distribution.p12"
profiles_zip="$WORK_DIR/provisioning-profiles.zip"
profiles_dir="$WORK_DIR/provisioning-profiles"
appstore_key_path="$WORK_DIR/AuthKey_$APPSTORE_KEY_ID.p8"
keychain_path="$WORK_DIR/$KEYCHAIN_NAME"

decode_base64 "$CERT_BASE64" "$cert_path"
decode_base64 "$PROFILES_BASE64" "$profiles_zip"
decode_base64 "$APPSTORE_KEY_BASE64" "$appstore_key_path"
chmod 600 "$cert_path" "$appstore_key_path"

security create-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"
security set-keychain-settings -lut 21600 "$keychain_path"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$keychain_path"

existing_keychains="$(security list-keychains -d user | sed 's/[",]//g' | tr '\n' ' ')"
# shellcheck disable=SC2086
security list-keychains -d user -s "$keychain_path" $existing_keychains
security default-keychain -s "$keychain_path"

security import "$cert_path" \
  -k "$keychain_path" \
  -P "$CERT_PASSWORD" \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  -T /usr/bin/xcodebuild >/dev/null
security set-key-partition-list \
  -S apple-tool:,apple: \
  -s \
  -k "$KEYCHAIN_PASSWORD" \
  "$keychain_path" >/dev/null

mkdir -p "$profiles_dir" "$HOME/Library/MobileDevice/Provisioning Profiles"
unzip -q "$profiles_zip" -d "$profiles_dir"
profile_count=0
while IFS= read -r profile; do
  cp "$profile" "$HOME/Library/MobileDevice/Provisioning Profiles/$(basename "$profile")"
  profile_count=$((profile_count + 1))
done < <(find "$profiles_dir" -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) | sort)

if [[ "$profile_count" -lt 1 ]]; then
  echo "ERROR: APPLE_PROVISIONING_PROFILES_BASE64 zip did not contain provisioning profiles." >&2
  exit 1
fi

APPSTORE_KEY_ID="$APPSTORE_KEY_ID" \
APPSTORE_ISSUER_ID="$APPSTORE_ISSUER_ID" \
APPSTORE_KEY_PATH="$appstore_key_path" \
  "$ROOT_DIR/scripts/configure-testflight-env.sh" --force >/dev/null

if security find-identity -v -p codesigning "$keychain_path" | grep -q '"Apple Distribution:'; then
  echo "Apple Distribution identity installed in temporary keychain."
else
  echo "ERROR: imported keychain does not expose an Apple Distribution identity." >&2
  exit 1
fi

printf 'Installed provisioning profiles: %d\n' "$profile_count"
printf 'Wrote App Store Connect env: %s\n' "$ROOT_DIR/VKTurnProxy/AppStoreConnect.env"
