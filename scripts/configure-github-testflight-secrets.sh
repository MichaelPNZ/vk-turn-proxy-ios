#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-MichaelPNZ/vk-turn-proxy-ios}"
CERT_P12=""
CERT_PASSWORD=""
PROFILES=()
APPSTORE_KEY_ID=""
APPSTORE_ISSUER_ID=""
APPSTORE_KEY_P8=""
DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/configure-github-testflight-secrets.sh \
    --cert-p12 /absolute/path/AppleDistribution.p12 \
    --cert-password '<p12 password>' \
    --profile /absolute/path/com.vkturnproxy.app.mobileprovision \
    --profile /absolute/path/com.vkturnproxy.app.tunnel.mobileprovision \
    --profile /absolute/path/com.vkturnproxy.mac.provisionprofile \
    --profile /absolute/path/com.vkturnproxy.mac.tunnel.provisionprofile \
    --appstore-key-id ABCDE12345 \
    --appstore-issuer-id 00000000-0000-0000-0000-000000000000 \
    --appstore-key-p8 /absolute/path/AuthKey_ABCDE12345.p8

Environment:
  REPO=owner/name       default: MichaelPNZ/vk-turn-proxy-ios
  DRY_RUN=1            validate inputs and print secret names without writing

This script does not print secret values. It creates temporary base64 payload
files, writes GitHub Actions secrets with gh, then removes the temporary files.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --cert-p12)
      CERT_P12="${2:-}"; shift 2 ;;
    --cert-password)
      CERT_PASSWORD="${2:-}"; shift 2 ;;
    --profile)
      PROFILES+=("${2:-}"); shift 2 ;;
    --appstore-key-id)
      APPSTORE_KEY_ID="${2:-}"; shift 2 ;;
    --appstore-issuer-id)
      APPSTORE_ISSUER_ID="${2:-}"; shift 2 ;;
    --appstore-key-p8)
      APPSTORE_KEY_P8="${2:-}"; shift 2 ;;
    -h|--help|help)
      usage; exit 64 ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 64 ;;
  esac
done

fail() {
  echo "ERROR: $*" >&2
  exit 64
}

require_file() {
  local path="$1"
  local label="$2"
  [[ -n "$path" ]] || fail "$label path is required"
  [[ -f "$path" ]] || fail "$label file does not exist: $path"
}

encode_file() {
  local input="$1"
  local output="$2"
  if base64 -i "$input" > "$output" 2>/dev/null; then
    return 0
  fi
  base64 "$input" > "$output"
}

set_secret_file() {
  local name="$1"
  local file="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN secret_file=%s bytes=%s\n' "$name" "$(wc -c < "$file" | tr -d ' ')"
    return
  fi
  gh secret set "$name" --repo "$REPO" < "$file" >/dev/null
  printf 'wrote secret: %s\n' "$name"
}

set_secret_value() {
  local name="$1"
  local value="$2"
  if [[ "$DRY_RUN" == "1" ]]; then
    printf 'DRY_RUN secret_value=%s chars=%s\n' "$name" "${#value}"
    return
  fi
  printf '%s' "$value" | gh secret set "$name" --repo "$REPO" >/dev/null
  printf 'wrote secret: %s\n' "$name"
}

command -v gh >/dev/null 2>&1 || fail "gh is required"
if [[ "$DRY_RUN" != "1" ]]; then
  gh auth status >/dev/null 2>&1 || fail "gh is not authenticated"
fi

require_file "$CERT_P12" "Apple Distribution .p12"
require_file "$APPSTORE_KEY_P8" "App Store Connect .p8"
[[ -n "$CERT_PASSWORD" ]] || fail "--cert-password is required"
[[ "$APPSTORE_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "--appstore-key-id must be a 10-character key id"
[[ "$APPSTORE_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]] || fail "--appstore-issuer-id must be a UUID"
[[ "${#PROFILES[@]}" -ge 4 ]] || fail "at least four --profile files are required"

for profile in "${PROFILES[@]}"; do
  require_file "$profile" "provisioning profile"
  case "$profile" in
    *.mobileprovision|*.provisionprofile) ;;
    *) fail "profile must end with .mobileprovision or .provisionprofile: $profile" ;;
  esac
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cert_b64="$tmp_dir/apple-distribution.p12.base64"
profiles_zip="$tmp_dir/provisioning-profiles.zip"
profiles_b64="$tmp_dir/provisioning-profiles.zip.base64"
appstore_key_b64="$tmp_dir/appstore-key.p8.base64"

encode_file "$CERT_P12" "$cert_b64"
zip -q -j "$profiles_zip" "${PROFILES[@]}"
encode_file "$profiles_zip" "$profiles_b64"
encode_file "$APPSTORE_KEY_P8" "$appstore_key_b64"
chmod 600 "$cert_b64" "$profiles_zip" "$profiles_b64" "$appstore_key_b64"

set_secret_file APPLE_DISTRIBUTION_CERT_P12_BASE64 "$cert_b64"
set_secret_value APPLE_DISTRIBUTION_CERT_PASSWORD "$CERT_PASSWORD"
set_secret_file APPLE_PROVISIONING_PROFILES_BASE64 "$profiles_b64"
set_secret_value APPSTORE_KEY_ID "$APPSTORE_KEY_ID"
set_secret_value APPSTORE_ISSUER_ID "$APPSTORE_ISSUER_ID"
set_secret_file APPSTORE_CONNECT_API_KEY_P8_BASE64 "$appstore_key_b64"

if [[ "$DRY_RUN" == "1" ]]; then
  printf 'DRY_RUN complete. GitHub TestFlight secrets were not written for repo: %s\n' "$REPO"
else
  printf 'GitHub TestFlight secrets configured for repo: %s\n' "$REPO"
fi
printf 'Next check:\n'
printf '  scripts/release-blockers-status.sh v1.0-build156\n'
