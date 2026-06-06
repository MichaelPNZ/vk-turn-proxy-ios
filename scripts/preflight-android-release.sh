#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
ALLOW_EXTERNAL_BLOCKERS="${ALLOW_EXTERNAL_BLOCKERS:-0}"
BUILD_FILE="$ROOT_DIR/androidApp/build.gradle.kts"
SIGNING_FILE="$ROOT_DIR/androidApp/signing.properties"
BRIDGE_AAR="$ROOT_DIR/androidApp/libs/vkturnbridge.aar"
EXPECTED_VERSION_CODE="${EXPECTED_ANDROID_VERSION_CODE:-156}"

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

printf 'Android release preflight for %s\n\n' "$ROOT_DIR"

if [[ -x "$ANDROID_HOME/platform-tools/adb" ]]; then
  pass "ANDROID_HOME is usable: $ANDROID_HOME"
else
  fail "ANDROID_HOME does not contain platform-tools/adb: $ANDROID_HOME"
fi

if [[ -f "$BRIDGE_AAR" ]]; then
  pass "Go mobile bridge AAR exists"
else
  fail "Go mobile bridge AAR missing: $BRIDGE_AAR"
fi

if grep -q "versionCode = $EXPECTED_VERSION_CODE" "$BUILD_FILE"; then
  pass "Android versionCode is $EXPECTED_VERSION_CODE"
else
  fail "Android versionCode is not $EXPECTED_VERSION_CODE"
fi

if grep -q 'versionName = "1.0"' "$BUILD_FILE"; then
  pass "Android versionName is 1.0"
else
  fail "Android versionName is not 1.0"
fi

if [[ -f "$SIGNING_FILE" ]]; then
  pass "androidApp/signing.properties found"
  store_file="$(awk -F= '/^storeFile=/{print $2}' "$SIGNING_FILE" | tail -1)"
  for key in storeFile storePassword keyAlias keyPassword; do
    if awk -F= -v key="$key" '$1 == key && length($2) > 0 {found=1} END {exit found ? 0 : 1}' "$SIGNING_FILE"; then
      pass "signing.properties contains $key"
    else
      external_blocker "signing.properties missing $key"
    fi
  done
  if [[ -n "$store_file" && -f "$store_file" ]]; then
    pass "Android release keystore exists"
  else
    external_blocker "Android release keystore missing: ${store_file:-unset}"
  fi
else
  external_blocker "androidApp/signing.properties missing; release APK/AAB will be unsigned"
fi

if [[ -f "$ROOT_DIR/androidApp/build/outputs/apk/release/androidApp-release-unsigned.apk" || -f "$ROOT_DIR/androidApp/build/outputs/apk/release/androidApp-release.apk" ]]; then
  pass "release APK artifact exists"
else
  warn "release APK artifact not found yet; run ./gradlew :androidApp:assembleRelease"
fi

if [[ -f "$ROOT_DIR/androidApp/build/outputs/bundle/release/androidApp-release.aab" ]]; then
  pass "release AAB artifact exists"
else
  warn "release AAB artifact not found yet; run ./gradlew :androidApp:bundleRelease"
fi

printf '\nAndroid preflight summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi
