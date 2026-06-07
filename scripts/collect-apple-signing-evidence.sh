#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/VKTurnProxy"
PROJECT_YML="$PROJECT_DIR/project.yml"
ENV_FILE="$PROJECT_DIR/AppStoreConnect.env"
PROFILE_DIR="${TESTFLIGHT_PROFILE_DIR:-"$HOME/Library/MobileDevice/Provisioning Profiles"}"
EVIDENCE_DIR="${1:-"$ROOT_DIR/build/evidence/apple-signing-current"}"
STRICT="${STRICT:-0}"
ENV_FILE="${TESTFLIGHT_ENV_FILE:-"$ENV_FILE"}"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/collect-apple-signing-evidence.sh [evidence-dir]

Environment:
  STRICT=0|1        default: 0. When 1, exit non-zero if TestFlight signing is not ready.

Read-only collector. It does not create certificates, install profiles, call
App Store Connect, or modify the keychain. Secret values are not written.
EOF
}

if [[ "$EVIDENCE_DIR" == "-h" || "$EVIDENCE_DIR" == "--help" || "$EVIDENCE_DIR" == "help" ]]; then
  usage
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"
: > "$EVIDENCE_DIR/blockers.txt"

blocker() {
  printf '%s\n' "$*" >> "$EVIDENCE_DIR/blockers.txt"
}

bundle_ids() {
  awk '/PRODUCT_BUNDLE_IDENTIFIER:/ {print $NF}' "$PROJECT_YML" 2>/dev/null | sort -u
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

file_mode() {
  stat -f%Lp "$1" 2>/dev/null || stat -c%a "$1" 2>/dev/null || true
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

TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $NF; exit}' "$PROJECT_YML" 2>/dev/null || true)"
if [[ -z "$TEAM_ID" ]]; then
  blocker "DEVELOPMENT_TEAM is missing in $PROJECT_YML"
fi

bundle_ids > "$EVIDENCE_DIR/bundle-ids.txt"
bundle_count="$(wc -l < "$EVIDENCE_DIR/bundle-ids.txt" | tr -d ' ')"
if [[ "$bundle_count" -lt 1 ]]; then
  blocker "No PRODUCT_BUNDLE_IDENTIFIER values found in $PROJECT_YML"
fi

{
  printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'root=%s\n' "$ROOT_DIR"
  printf 'team_id=%s\n' "${TEAM_ID:-missing}"
  printf 'project_yml=%s\n' "$PROJECT_YML"
  printf 'env_file=%s\n' "$ENV_FILE"
  printf 'profile_dir=%s\n' "$PROFILE_DIR"
} > "$EVIDENCE_DIR/collector.txt"

{
  if [[ -f "$ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$ENV_FILE"
    printf 'file=present\n'
    printf 'APPSTORE_KEY_ID=%s\n' "${APPSTORE_KEY_ID:+set}"
    printf 'APPSTORE_ISSUER_ID=%s\n' "${APPSTORE_ISSUER_ID:+set}"
    if [[ -n "${APPSTORE_KEY_PATH:-}" ]]; then
      printf 'APPSTORE_KEY_PATH=set\n'
      printf 'APPSTORE_KEY_PATH_BASENAME=%s\n' "$(basename "$APPSTORE_KEY_PATH")"
      if [[ -f "$APPSTORE_KEY_PATH" ]]; then
        printf 'APPSTORE_KEY_PATH_EXISTS=yes\n'
      else
        printf 'APPSTORE_KEY_PATH_EXISTS=no\n'
        blocker "APPSTORE_KEY_PATH does not exist on disk"
      fi
    else
      printf 'APPSTORE_KEY_PATH=unset\n'
      printf 'APPSTORE_KEY_PATH_EXISTS=no\n'
      blocker "APPSTORE_KEY_PATH is missing in $ENV_FILE"
    fi
    if [[ -z "${APPSTORE_KEY_ID:-}" ]]; then
      blocker "APPSTORE_KEY_ID is missing in $ENV_FILE"
    elif [[ ! "$APPSTORE_KEY_ID" =~ ^[A-Z0-9]{10}$ ]]; then
      blocker "APPSTORE_KEY_ID must be a 10-character App Store Connect key id"
    fi
    if [[ -z "${APPSTORE_ISSUER_ID:-}" ]]; then
      blocker "APPSTORE_ISSUER_ID is missing in $ENV_FILE"
    elif [[ ! "$APPSTORE_ISSUER_ID" =~ ^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$ ]]; then
      blocker "APPSTORE_ISSUER_ID must be a UUID"
    fi
    if [[ -n "${APPSTORE_KEY_PATH:-}" && "$APPSTORE_KEY_PATH" != /* ]]; then
      blocker "APPSTORE_KEY_PATH must be absolute"
    fi
    if [[ -n "${APPSTORE_KEY_PATH:-}" && -f "$APPSTORE_KEY_PATH" ]]; then
      if ! grep -q -- '-----BEGIN PRIVATE KEY-----' "$APPSTORE_KEY_PATH"; then
        blocker "APPSTORE_KEY_PATH does not look like an App Store Connect .p8 private key"
      fi
    fi
    env_mode="$(file_mode "$ENV_FILE")"
    printf 'FILE_MODE=%s\n' "${env_mode:-unknown}"
    if [[ -n "$env_mode" && "$env_mode" != "600" ]]; then
      blocker "$ENV_FILE must have file mode 600"
    fi
  else
    printf 'file=missing\n'
    blocker "$ENV_FILE is missing"
  fi
} > "$EVIDENCE_DIR/appstore-connect-env.txt"

identity_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
printf '%s\n' "$identity_output" > "$EVIDENCE_DIR/code-signing-identities.txt"
if grep -q '"Apple Distribution:' <<<"$identity_output"; then
  distribution_identity="present"
else
  distribution_identity="missing"
  blocker "Apple Distribution signing identity is missing"
fi
if grep -q 'CSSMERR_TP_CERT_REVOKED' <<<"$identity_output"; then
  revoked_identity="present"
else
  revoked_identity="none"
fi

profiles_count=0
profiles_list="$TMP_DIR/profiles.txt"
: > "$profiles_list"
if [[ -d "$PROFILE_DIR" ]]; then
  find "$PROFILE_DIR" -maxdepth 1 -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) | sort > "$profiles_list"
  profiles_count="$(wc -l < "$profiles_list" | tr -d ' ')"
else
  blocker "Provisioning profile directory is missing: $PROFILE_DIR"
fi

{
  printf 'bundle_id\tmatched\tdistribution_match\tprofile_name\tuuid\texpires\tapp_id\tget_task_allow\tprofile_file\n'
  while IFS= read -r bundle_id; do
    matched=0
    distribution_match=0
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
      get_task_allow="$(profile_get_task_allow "$decoded")"
      if [[ "$get_task_allow" == "false" ]]; then
        distribution_match=1
      fi
      printf '%s\t1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$bundle_id" "$distribution_match" "${name:-unknown}" "${uuid:-unknown}" \
        "${expires:-unknown}" "${app_id:-unknown}" "${get_task_allow:-unknown}" \
        "$(basename "$profile")"
    done < "$profiles_list"
    if [[ "$matched" != 1 ]]; then
      printf '%s\t0\t0\t\t\t\t\t\t\n' "$bundle_id"
      blocker "No provisioning profile matches bundle id $bundle_id"
    elif [[ "$distribution_match" != 1 ]]; then
      blocker "No App Store distribution provisioning profile found for $bundle_id"
    fi
  done < "$EVIDENCE_DIR/bundle-ids.txt"
} > "$EVIDENCE_DIR/provisioning-profiles.tsv"

blocker_count="$(grep -cve '^[[:space:]]*$' "$EVIDENCE_DIR/blockers.txt" || true)"
if [[ "$blocker_count" -eq 0 ]]; then
  result="passed"
  testflight_ready="true"
else
  result="blocked"
  testflight_ready="false"
fi

cat > "$EVIDENCE_DIR/next-commands.txt" <<'EOF'
1. Create App Store Connect API key and keep AuthKey_XXXXXXXXXX.p8 outside the repo.
2. Write ignored env file:
   scripts/configure-testflight-env.sh --key-id <APPSTORE_KEY_ID> --issuer-id <APPSTORE_ISSUER_ID> --key-path /absolute/path/to/AuthKey_<APPSTORE_KEY_ID>.p8
3. Install valid Apple Distribution certificate/private key in login keychain.
4. Install App Store/TestFlight distribution provisioning profiles for every bundle id in bundle-ids.txt.
5. Remove revoked code-signing identities from keychain.
6. Re-run:
   scripts/collect-apple-signing-evidence.sh build/evidence/apple-signing-current
   scripts/preflight-testflight.sh v1.0-build168
EOF

cat > "$EVIDENCE_DIR/summary.txt" <<EOF
result=$result
evidence_type=apple_signing_readiness
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
host=$(hostname)
team_id=${TEAM_ID:-missing}
bundle_count=$bundle_count
profiles_count=$profiles_count
apple_distribution_identity=$distribution_identity
revoked_identity=$revoked_identity
blocker_count=$blocker_count
testflight_ready=$testflight_ready
EOF

printf 'wrote %s\n' "$EVIDENCE_DIR/summary.txt"
printf 'result=%s\n' "$result"
printf 'blocker_count=%s\n' "$blocker_count"
printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"

if [[ "$STRICT" == "1" && "$result" != "passed" ]]; then
  exit 1
fi
