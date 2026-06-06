#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_DIR="$ROOT_DIR/VKTurnProxy"
PROJECT_FILE="$PROJECT_DIR/VKTurnProxy.xcodeproj"
PROJECT_YML="$PROJECT_DIR/project.yml"
ENV_FILE="$PROJECT_DIR/AppStoreConnect.env"
TAG="${1:-}"
ALLOW_EXTERNAL_BLOCKERS="${ALLOW_EXTERNAL_BLOCKERS:-0}"
PROFILE_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
TEAM_ID="$(awk '/DEVELOPMENT_TEAM:/ {print $NF; exit}' "$PROJECT_YML" 2>/dev/null || true)"

failures=0
warnings=0

pass() { printf 'PASS %s\n' "$*"; }
warn() { printf 'WARN %s\n' "$*"; warnings=$((warnings + 1)); }
fail() { printf 'FAIL %s\n' "$*"; failures=$((failures + 1)); }
external_blocker() {
  if [[ "$ALLOW_EXTERNAL_BLOCKERS" == "1" ]]; then
    warn "$*"
  else
    fail "$*"
  fi
}

require_command() {
  if command -v "$1" >/dev/null 2>&1; then
    pass "$1 found"
  else
    fail "$1 is missing"
  fi
}

contains() {
  local file="$1"
  local needle="$2"
  [[ -f "$file" ]] && grep -qF "$needle" "$file"
}

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

check_provisioning_profiles() {
  local tmp_dir profiles_list profiles_count bundle_id profile decoded matched distribution_match

  if [[ -z "$TEAM_ID" ]]; then
    fail "DEVELOPMENT_TEAM is missing in project.yml"
    return
  fi
  pass "DEVELOPMENT_TEAM is $TEAM_ID"

  if [[ ! -d "$PROFILE_DIR" ]]; then
    external_blocker "provisioning profile directory missing: $PROFILE_DIR"
    return
  fi

  tmp_dir="$(mktemp -d)"
  profiles_list="$tmp_dir/profiles.txt"
  find "$PROFILE_DIR" -maxdepth 1 -type f \( -name '*.mobileprovision' -o -name '*.provisionprofile' \) | sort >"$profiles_list"
  profiles_count="$(wc -l <"$profiles_list" | tr -d ' ')"
  if [[ "$profiles_count" -gt 0 ]]; then
    pass "installed provisioning profiles: $profiles_count"
  else
    external_blocker "no installed provisioning profiles found in $PROFILE_DIR"
    rm -rf "$tmp_dir"
    return
  fi

  for bundle_id in $(bundle_ids); do
    matched=0
    distribution_match=0
    while IFS= read -r profile; do
      decoded="$tmp_dir/$(basename "$profile").plist"
      if ! decode_profile "$profile" "$decoded"; then
        continue
      fi
      if ! profile_matches_bundle "$decoded" "$bundle_id"; then
        continue
      fi
      matched=1
      if [[ "$(profile_get_task_allow "$decoded")" == "false" ]]; then
        distribution_match=1
      fi
    done <"$profiles_list"

    if [[ "$matched" != 1 ]]; then
      external_blocker "no provisioning profile matches bundle id $bundle_id"
    elif [[ "$distribution_match" != 1 ]]; then
      external_blocker "no distribution/App Store provisioning profile found for $bundle_id (get-task-allow=false required)"
    else
      pass "distribution provisioning profile found for $bundle_id"
    fi
  done

  rm -rf "$tmp_dir"
}

check_entitlement() {
  local file="$1"
  local label="$2"
  local required="$3"
  if contains "$file" "$required"; then
    pass "$label entitlement contains $required"
  else
    fail "$label entitlement missing $required"
  fi
}

printf 'TestFlight preflight for %s\n' "$ROOT_DIR"
printf 'Project: %s\n\n' "$PROJECT_FILE"

require_command xcodebuild
require_command xcodegen
require_command plutil
require_command security

if command -v gh >/dev/null 2>&1; then
  pass "gh found"
  if gh auth status >/dev/null 2>&1; then
    pass "gh authenticated"
  else
    warn "gh is installed but not authenticated; GitHub Release upload will fail"
  fi
else
  warn "gh missing; TestFlight upload can work, GitHub Release upload will fail"
fi

if [[ -f "$PROJECT_YML" ]]; then
  pass "project.yml found"
else
  fail "project.yml missing at $PROJECT_YML"
fi

if [[ -d "$PROJECT_FILE" ]]; then
  pass "Xcode project exists"
else
  fail "Xcode project missing; run xcodegen in VKTurnProxy/"
fi

if [[ -n "$(git -C "$ROOT_DIR" status --porcelain 2>/dev/null || true)" ]]; then
  warn "working tree is dirty; release.sh will refuse to run until changes are committed or stashed"
else
  pass "working tree is clean"
fi

if [[ -n "$TAG" ]]; then
  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    pass "tag exists: $TAG"
  else
    fail "tag does not exist locally: $TAG"
  fi
  build_num="${TAG##*build}"
  if [[ "$build_num" =~ ^[0-9]+$ ]]; then
    mismatches="$(awk -v expected="$build_num" '
      /^[[:space:]]+CURRENT_PROJECT_VERSION:/ {
        value=$NF
        gsub(/"/, "", value)
        if (value != expected) print NR ":" value
      }
    ' "$PROJECT_YML")"
    if [[ -z "$mismatches" ]]; then
      pass "CURRENT_PROJECT_VERSION values match tag build $build_num"
    else
      fail "CURRENT_PROJECT_VERSION mismatch for tag build $build_num: $mismatches"
    fi
  else
    fail "tag must end with build<N>: $TAG"
  fi
else
  versions="$(awk '/^[[:space:]]+CURRENT_PROJECT_VERSION:/ {print $NF}' "$PROJECT_YML" | sort -u | tr '\n' ' ')"
  if [[ -n "$versions" ]]; then
    pass "CURRENT_PROJECT_VERSION values: $versions"
  else
    fail "no CURRENT_PROJECT_VERSION values found in project.yml"
  fi
fi

scheme_list="$(mktemp)"
if xcodebuild -project "$PROJECT_FILE" -list >"$scheme_list" 2>/tmp/vkturn-xcodebuild-list.err; then
  if grep -q 'VKTurnProxy$' "$scheme_list"; then
    pass "iOS scheme VKTurnProxy exists"
  else
    fail "iOS scheme VKTurnProxy missing"
  fi
  if grep -q 'VKTurnProxyMac$' "$scheme_list"; then
    pass "macOS scheme VKTurnProxyMac exists"
  else
    fail "macOS scheme VKTurnProxyMac missing"
  fi
else
  fail "xcodebuild -list failed: $(tail -5 /tmp/vkturn-xcodebuild-list.err)"
fi
rm -f "$scheme_list"

check_entitlement "$PROJECT_DIR/VKTurnProxy/VKTurnProxy.entitlements" "iOS app" "packet-tunnel-provider"
check_entitlement "$PROJECT_DIR/PacketTunnel/PacketTunnel.entitlements" "iOS packet tunnel" "packet-tunnel-provider"
check_entitlement "$PROJECT_DIR/MacApp/MacApp.entitlements" "macOS app" "packet-tunnel-provider"
check_entitlement "$PROJECT_DIR/MacPacketTunnel/MacPacketTunnel.entitlements" "macOS packet tunnel" "packet-tunnel-provider"
check_entitlement "$PROJECT_DIR/VKTurnProxy/VKTurnProxy.entitlements" "iOS app" "group.com.vkturnproxy.app"
check_entitlement "$PROJECT_DIR/PacketTunnel/PacketTunnel.entitlements" "iOS packet tunnel" "group.com.vkturnproxy.app"
check_entitlement "$PROJECT_DIR/MacApp/MacApp.entitlements" "macOS app" "group.com.vkturnproxy.app"
check_entitlement "$PROJECT_DIR/MacPacketTunnel/MacPacketTunnel.entitlements" "macOS packet tunnel" "group.com.vkturnproxy.app"
check_entitlement "$PROJECT_DIR/MacApp/MacApp.entitlements" "macOS app" "com.apple.security.app-sandbox"
check_entitlement "$PROJECT_DIR/MacPacketTunnel/MacPacketTunnel.entitlements" "macOS packet tunnel" "com.apple.security.app-sandbox"

check_provisioning_profiles

wg_info="$ROOT_DIR/WireGuardBridge/build/WireGuardTURN.xcframework/Info.plist"
if [[ -f "$wg_info" ]]; then
  pass "WireGuardTURN.xcframework exists"
  wg_ids="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$wg_info" 2>/dev/null || true)"
  for id in ios-arm64 ios-arm64-simulator macos-arm64_x86_64; do
    if grep -q "$id" <<<"$wg_ids"; then
      pass "WireGuardTURN slice exists: $id"
    else
      fail "WireGuardTURN slice missing: $id"
    fi
  done
else
  fail "WireGuardTURN.xcframework missing; run: cd WireGuardBridge && make xcframework"
fi

shared_info="$ROOT_DIR/shared/build/XCFrameworks/release/VKTurnShared.xcframework/Info.plist"
if [[ -f "$shared_info" ]]; then
  pass "VKTurnShared.xcframework exists"
  shared_ids="$(/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$shared_info" 2>/dev/null || true)"
  for id in ios-arm64 ios-arm64-simulator macos-arm64_x86_64; do
    if grep -q "$id" <<<"$shared_ids"; then
      pass "VKTurnShared slice exists: $id"
    else
      fail "VKTurnShared slice missing: $id"
    fi
  done
else
  fail "VKTurnShared.xcframework missing; run: ANDROID_HOME=\$HOME/Library/Android/sdk ./gradlew :shared:assembleVKTurnSharedReleaseXCFramework"
fi

if [[ -f "$ENV_FILE" ]]; then
  pass "AppStoreConnect.env found"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  for var in APPSTORE_KEY_ID APPSTORE_ISSUER_ID APPSTORE_KEY_PATH; do
    if [[ -n "${!var:-}" ]]; then
      pass "$var is set"
    else
      external_blocker "$ENV_FILE missing $var"
    fi
  done
  if [[ -n "${APPSTORE_KEY_PATH:-}" && -f "$APPSTORE_KEY_PATH" ]]; then
    pass "APPSTORE_KEY_PATH exists"
  else
    external_blocker "APPSTORE_KEY_PATH does not exist: ${APPSTORE_KEY_PATH:-unset}"
  fi
else
  external_blocker "$ENV_FILE missing; TestFlight upload cannot run"
fi

identity_output="$(security find-identity -v -p codesigning 2>/dev/null || true)"
if grep -q '"Apple Distribution:' <<<"$identity_output"; then
  pass "Apple Distribution signing identity found"
else
  external_blocker "Apple Distribution signing identity missing; App Store archive signing is likely blocked"
fi
if grep -q '"Apple Development:' <<<"$identity_output"; then
  pass "Apple Development signing identity found"
else
  warn "Apple Development signing identity missing"
fi
if grep -q 'CSSMERR_TP_CERT_REVOKED' <<<"$identity_output"; then
  warn "revoked code-signing identity is present in keychain; remove it to avoid Xcode picking the wrong certificate"
fi

printf '\nPreflight summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi
