#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/VKTurnProxy"
PROJECT_YML="$PROJECT_DIR/project.yml"
ENV_FILE="$PROJECT_DIR/AppStoreConnect.env"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"

TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $NF; exit}' "$PROJECT_YML" 2>/dev/null || true)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

bundle_ids() {
  awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $NF}' "$PROJECT_YML" | sort -u
}

decode_profile() {
  local profile="$1"
  local output="$2"
  security cms -D -i "$profile" >"$output" 2>/dev/null
}

plist_value() {
  local plist="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist" 2>/dev/null || true
}

profile_app_id() {
  plist_value "$1" "Entitlements:application-identifier"
}

profile_matches_bundle() {
  local plist="$1"
  local bundle_id="$2"
  local app_id
  app_id="$(profile_app_id "$plist")"
  [[ "$app_id" == "$TEAM_ID.$bundle_id" || "$app_id" == "$TEAM_ID.*" || "$app_id" == *".$bundle_id" ]]
}

printf 'Apple signing diagnostics for %s\n' "$ROOT_DIR"
printf 'Team ID: %s\n' "${TEAM_ID:-missing}"
printf '\nBundle identifiers from project.yml:\n'
bundle_ids | sed 's/^/  - /'

printf '\nApp Store Connect env:\n'
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  printf '  file: present (%s)\n' "$ENV_FILE"
  printf '  APPSTORE_KEY_ID: %s\n' "${APPSTORE_KEY_ID:+set}"
  printf '  APPSTORE_ISSUER_ID: %s\n' "${APPSTORE_ISSUER_ID:+set}"
  if [[ -n "${APPSTORE_KEY_PATH:-}" ]]; then
    if [[ -f "$APPSTORE_KEY_PATH" ]]; then
      printf '  APPSTORE_KEY_PATH: exists\n'
    else
      printf '  APPSTORE_KEY_PATH: missing file (%s)\n' "$APPSTORE_KEY_PATH"
    fi
  else
    printf '  APPSTORE_KEY_PATH: unset\n'
  fi
else
  printf '  file: missing (%s)\n' "$ENV_FILE"
fi

printf '\nCode signing identities:\n'
identity_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if [[ -n "$identity_output" ]]; then
  grep -E '"Apple (Distribution|Development):' <<<"$identity_output" | sed 's/^/  /' || true
else
  printf '  none\n'
fi
if grep -q '"Apple Distribution:' <<<"$identity_output"; then
  printf '  Apple Distribution: present\n'
else
  printf '  Apple Distribution: missing\n'
fi
if grep -q 'CSSMERR_TP_CERT_REVOKED' <<<"$identity_output"; then
  printf '  Revoked identity: present\n'
else
  printf '  Revoked identity: none detected\n'
fi

printf '\nProvisioning profiles:\n'
if [[ ! -d "$PROFILE_DIR" ]]; then
  printf '  directory missing: %s\n' "$PROFILE_DIR"
  exit 0
fi

profiles_list="$TMP_DIR/profiles.txt"
find "$PROFILE_DIR" -maxdepth 1 -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) | sort >"$profiles_list"
profiles_count="$(wc -l <"$profiles_list" | tr -d ' ')"
printf '  total profiles: %d\n' "$profiles_count"
if [[ "$profiles_count" -eq 0 ]]; then
  exit 0
fi

for bundle_id in $(bundle_ids); do
  printf '\nProfiles matching %s:\n' "$bundle_id"
  matched=0
  while IFS= read -r profile; do
    decoded="$TMP_DIR/$(basename "$profile").plist"
    if ! decode_profile "$profile" "$decoded"; then
      continue
    fi
    if ! profile_matches_bundle "$decoded" "$bundle_id"; then
      continue
    fi
    matched=1
    name="$(plist_value "$decoded" "Name")"
    uuid="$(plist_value "$decoded" "UUID")"
    expires="$(plist_value "$decoded" "ExpirationDate")"
    app_id="$(profile_app_id "$decoded")"
    get_task_allow="$(plist_value "$decoded" "Entitlements:get-task-allow")"
    printf '  - %s\n' "${name:-unnamed}"
    printf '    uuid: %s\n' "${uuid:-unknown}"
    printf '    app_id: %s\n' "${app_id:-unknown}"
    printf '    expires: %s\n' "${expires:-unknown}"
    printf '    get-task-allow: %s\n' "${get_task_allow:-unknown}"
  done <"$profiles_list"
  if [[ "$matched" != 1 ]]; then
    printf '  none\n'
  fi
done
