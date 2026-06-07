#!/usr/bin/env bash
set -euo pipefail

REPO="${REPO:-MichaelPNZ/vk-turn-proxy-ios}"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_YML="$ROOT_DIR/VKTurnProxy/project.yml"
CERT_P12=""
CERT_PASSWORD=""
PROFILES=()
APPSTORE_ENV=""
PROFILE_SCAN_DIR=""
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

  scripts/configure-github-testflight-secrets.sh \
    --cert-p12 /absolute/path/AppleDistribution.p12 \
    --cert-password '<p12 password>' \
    --profiles-from-installed \
    --appstore-env VKTurnProxy/AppStoreConnect.env

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
    --profiles-from-dir)
      PROFILE_SCAN_DIR="${2:-}"; shift 2 ;;
    --profiles-from-installed)
      PROFILE_SCAN_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"; shift ;;
    --appstore-env)
      APPSTORE_ENV="${2:-}"; shift 2 ;;
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

bundle_ids() {
  awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $NF}' "$PROJECT_YML" 2>/dev/null | sort -u
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

profile_app_id() {
  plist_value "$1" "Entitlements:application-identifier"
}

profile_get_task_allow() {
  plist_value "$1" "Entitlements:get-task-allow"
}

profile_matches_bundle() {
  local plist="$1"
  local bundle_id="$2"
  local app_id
  app_id="$(profile_app_id "$plist")"
  [[ "$app_id" == "$TEAM_ID.$bundle_id" || "$app_id" == "$TEAM_ID.*" || "$app_id" == *".$bundle_id" ]]
}

load_appstore_env() {
  [[ -n "$APPSTORE_ENV" ]] || return 0
  require_file "$APPSTORE_ENV" "App Store Connect env"

  local explicit_key_id="$APPSTORE_KEY_ID"
  local explicit_issuer_id="$APPSTORE_ISSUER_ID"
  local explicit_key_p8="$APPSTORE_KEY_P8"

  # shellcheck disable=SC1090
  source "$APPSTORE_ENV"

  if [[ -n "$explicit_key_id" ]]; then
    APPSTORE_KEY_ID="$explicit_key_id"
  fi
  if [[ -n "$explicit_issuer_id" ]]; then
    APPSTORE_ISSUER_ID="$explicit_issuer_id"
  fi
  if [[ -n "$explicit_key_p8" ]]; then
    APPSTORE_KEY_P8="$explicit_key_p8"
  elif [[ -n "${APPSTORE_KEY_PATH:-}" ]]; then
    APPSTORE_KEY_P8="$APPSTORE_KEY_PATH"
  fi
}

select_profiles_from_dir() {
  [[ -n "$PROFILE_SCAN_DIR" ]] || return 0
  [[ "${#PROFILES[@]}" -eq 0 ]] || return 0
  [[ -d "$PROFILE_SCAN_DIR" ]] || fail "provisioning profile scan directory does not exist: $PROFILE_SCAN_DIR"
  [[ -f "$PROJECT_YML" ]] || fail "project.yml is missing: $PROJECT_YML"

  TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $NF; exit}' "$PROJECT_YML" 2>/dev/null || true)"
  [[ -n "$TEAM_ID" ]] || fail "DEVELOPMENT_TEAM is missing in $PROJECT_YML"

  local profile_list="$tmp_dir/profile-scan-list.txt"
  find "$PROFILE_SCAN_DIR" -maxdepth 1 -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) | sort > "$profile_list"
  [[ -s "$profile_list" ]] || fail "no provisioning profiles found in: $PROFILE_SCAN_DIR"

  local selected="$tmp_dir/selected-profiles.txt"
  : > "$selected"
  local bundle_id matched profile decoded get_task_allow
  while IFS= read -r bundle_id; do
    [[ -n "$bundle_id" ]] || continue
    matched=0
    while IFS= read -r profile; do
      [[ -f "$profile" ]] || continue
      decoded="$tmp_dir/profile-scan-$(basename "$profile").plist"
      if ! security cms -D -i "$profile" > "$decoded" 2>/dev/null; then
        continue
      fi
      if ! profile_matches_bundle "$decoded" "$bundle_id"; then
        continue
      fi
      get_task_allow="$(profile_get_task_allow "$decoded")"
      if [[ "$get_task_allow" != "false" ]]; then
        continue
      fi
      matched=1
      printf '%s\n' "$profile" >> "$selected"
    done < "$profile_list"
    if [[ "$matched" != 1 ]]; then
      fail "no App Store distribution provisioning profile found for $bundle_id in $PROFILE_SCAN_DIR"
    fi
  done < <(bundle_ids)

  PROFILES=()
  while IFS= read -r profile; do
    PROFILES+=("$profile")
  done < <(sort -u "$selected")
  printf 'auto_selected_profiles=%s from %s\n' "${#PROFILES[@]}" "$PROFILE_SCAN_DIR" >&2
}

validate_appstore_key() {
  if ! grep -q -- '-----BEGIN PRIVATE KEY-----' "$APPSTORE_KEY_P8"; then
    fail "App Store Connect .p8 does not look like a private key: $APPSTORE_KEY_P8"
  fi
  if [[ "$(basename "$APPSTORE_KEY_P8")" != "AuthKey_$APPSTORE_KEY_ID.p8" ]]; then
    echo "WARN: .p8 basename does not match APPSTORE_KEY_ID: expected AuthKey_$APPSTORE_KEY_ID.p8" >&2
  fi
}

validate_p12() {
  command -v openssl >/dev/null 2>&1 || fail "openssl is required to validate the Apple Distribution .p12"
  local pass_file="$tmp_dir/cert-password.txt"
  local cert_info="$tmp_dir/cert-info.txt"
  local cert_err="$tmp_dir/cert-error.txt"
  printf '%s' "$CERT_PASSWORD" > "$pass_file"
  chmod 600 "$pass_file"
  if ! openssl pkcs12 -in "$CERT_P12" -passin "file:$pass_file" -nokeys -clcerts -nodes > "$cert_info" 2> "$cert_err"; then
    fail "Apple Distribution .p12 could not be opened with the supplied password"
  fi
  if ! grep -q 'Apple Distribution' "$cert_info"; then
    fail "Apple Distribution .p12 does not contain an Apple Distribution certificate"
  fi
}

validate_profiles() {
  command -v security >/dev/null 2>&1 || fail "security is required to validate provisioning profiles"
  [[ -x /usr/libexec/PlistBuddy ]] || fail "PlistBuddy is required to validate provisioning profiles"
  [[ -f "$PROJECT_YML" ]] || fail "project.yml is missing: $PROJECT_YML"

  TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $NF; exit}' "$PROJECT_YML" 2>/dev/null || true)"
  [[ -n "$TEAM_ID" ]] || fail "DEVELOPMENT_TEAM is missing in $PROJECT_YML"

  local basenames="$tmp_dir/profile-basenames.txt"
  : > "$basenames"
  local profile
  for profile in "${PROFILES[@]}"; do
    basename "$profile" >> "$basenames"
  done
  if [[ "$(sort "$basenames" | uniq -d | wc -l | tr -d ' ')" != "0" ]]; then
    fail "provisioning profile basenames must be unique because profiles are zipped with -j"
  fi

  local decoded_dir="$tmp_dir/decoded-profiles"
  mkdir -p "$decoded_dir"
  for profile in "${PROFILES[@]}"; do
    local decoded="$decoded_dir/$(basename "$profile").plist"
    if ! security cms -D -i "$profile" > "$decoded" 2>/dev/null; then
      fail "provisioning profile could not be decoded: $profile"
    fi
  done

  local bundle_id matched distribution_match decoded get_task_allow
  while IFS= read -r bundle_id; do
    [[ -n "$bundle_id" ]] || continue
    matched=0
    distribution_match=0
    for decoded in "$decoded_dir"/*.plist; do
      [[ -f "$decoded" ]] || continue
      if ! profile_matches_bundle "$decoded" "$bundle_id"; then
        continue
      fi
      matched=1
      get_task_allow="$(profile_get_task_allow "$decoded")"
      if [[ "$get_task_allow" == "false" ]]; then
        distribution_match=1
      fi
    done
    if [[ "$matched" != 1 ]]; then
      fail "no provisioning profile matches bundle id $bundle_id"
    fi
    if [[ "$distribution_match" != 1 ]]; then
      fail "no App Store distribution provisioning profile found for $bundle_id"
    fi
  done < <(bundle_ids)
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

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

load_appstore_env
select_profiles_from_dir

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

validate_appstore_key
validate_p12
validate_profiles

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
printf '  scripts/release-blockers-status.sh v1.0-build159\n'
