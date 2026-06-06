#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
ALLOW_EXTERNAL_BLOCKERS="${ALLOW_EXTERNAL_BLOCKERS:-0}"
BUILD_NUM=""

failures=0
warnings=0

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/final-release-readiness.sh <tag>

Required evidence environment variables for strict final readiness:
  ANDROID_PHYSICAL_SMOKE_EVIDENCE     directory from signed APK physical-device smoke
  IPHONE_TESTFLIGHT_SMOKE_EVIDENCE    directory with summary.txt evidence_type=iphone_testflight_network_extension
  MACOS_TESTFLIGHT_SMOKE_EVIDENCE     directory with summary.txt evidence_type=macos_testflight_packet_tunnel
  WINDOWS_RUNTIME_SMOKE_EVIDENCE      directory from smoke-windows-runtime.ps1 with summary.json ok=true
  WINDOWS_INSTALLER_SMOKE_EVIDENCE    directory with summary.txt evidence_type=windows_installer_smoke
  SERVER_PRODUCTION_SMOKE_EVIDENCE    directory with summary.txt evidence_type=server_production_smoke

Set ALLOW_EXTERNAL_BLOCKERS=1 to print missing external evidence as warnings
while keeping local automation green.
EOF
}

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

run_required() {
  local label="$1"
  shift
  printf '\n==> %s\n' "$label"
  if "$@"; then
    pass "$label"
  else
    fail "$label"
  fi
}

check_shell_syntax() {
  local script
  for script in "$@"; do
    printf '\n==> shell syntax: %s\n' "$script"
    if bash -n "$script"; then
      pass "shell syntax: $script"
    else
      fail "shell syntax: $script"
    fi
  done
}

require_existing_path() {
  local env_name="$1"
  local description="$2"
  local value="${!env_name:-}"
  if [[ -z "$value" ]]; then
    external_blocker "$env_name is not set ($description)"
    return
  fi
  if [[ -e "$value" ]]; then
    pass "$env_name exists: $value"
  else
    external_blocker "$env_name does not exist: $value ($description)"
  fi
}

require_file_in_dir() {
  local env_name="$1"
  local dir="$2"
  local file_name="$3"
  if [[ ! -f "$dir/$file_name" ]]; then
    external_blocker "$env_name missing required evidence file: $dir/$file_name"
    return 1
  fi
  return 0
}

require_summary_txt_evidence() {
  local env_name="$1"
  local evidence_type="$2"
  local description="$3"
  local value="${!env_name:-}"
  if [[ -z "$value" ]]; then
    external_blocker "$env_name is not set ($description)"
    return
  fi
  if [[ ! -d "$value" ]]; then
    external_blocker "$env_name must be an evidence directory: $value"
    return
  fi
  local summary="$value/summary.txt"
  if [[ ! -f "$summary" ]]; then
    external_blocker "$env_name missing summary.txt: $summary"
    return
  fi
  if ! grep -q '^result=passed$' "$summary"; then
    external_blocker "$env_name summary does not contain result=passed: $summary"
    return
  fi
  if ! grep -q "^evidence_type=$evidence_type$" "$summary"; then
    external_blocker "$env_name summary does not contain evidence_type=$evidence_type: $summary"
    return
  fi
  local attachment_count
  attachment_count="$(awk -F= '$1 == "attachment_count" {print $2}' "$summary" | tail -1)"
  if [[ ! "$attachment_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "$env_name summary must contain attachment_count > 0: $summary"
    return
  fi
  local actual_count
  actual_count="$(find "$value" -maxdepth 1 -type f ! -name summary.txt | wc -l | tr -d ' ')"
  if [[ "$actual_count" -lt 1 ]]; then
    external_blocker "$env_name must include at least one supporting evidence file besides summary.txt: $value"
    return
  fi
  pass "$env_name passed summary.txt evidence contract: $value"
}

require_windows_runtime_evidence() {
  local value="${WINDOWS_RUNTIME_SMOKE_EVIDENCE:-}"
  if [[ -z "$value" ]]; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE is not set (Windows host smoke-windows-runtime.ps1 evidence)"
    return
  fi
  if [[ ! -d "$value" ]]; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE must be an evidence directory: $value"
    return
  fi
  local summary="$value/summary.json"
  if [[ ! -f "$summary" ]]; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE missing summary.json: $summary"
    return
  fi
  if ! grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$summary"; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE summary.json does not contain ok=true: $summary"
    return
  fi
  if ! grep -q '"evidenceType"[[:space:]]*:[[:space:]]*"windows_runtime_smoke"' "$summary"; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE summary.json does not contain evidenceType=windows_runtime_smoke: $summary"
    return
  fi
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "transcript.txt" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "status-running.json" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "programdata-status-running.json" || return
  pass "WINDOWS_RUNTIME_SMOKE_EVIDENCE passed summary.json evidence contract: $value"
}

require_android_physical_evidence() {
  local value="${ANDROID_PHYSICAL_SMOKE_EVIDENCE:-}"
  if [[ -z "$value" ]]; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE is not set (signed APK physical Android smoke)"
    return
  fi
  if [[ ! -d "$value" ]]; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE must be an evidence directory: $value"
    return
  fi
  local summary="$value/summary.txt"
  if [[ ! -f "$summary" ]]; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE missing summary.txt: $summary"
    return
  fi
  if ! grep -q '^result=passed$' "$summary"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE summary does not contain result=passed: $summary"
    return
  fi
  if ! grep -q '^require_physical_device=1$' "$summary"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE was not produced with REQUIRE_PHYSICAL_DEVICE=1: $summary"
    return
  fi
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "device-qemu.txt" || return
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "running-connectivity.txt" || return
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "stopped-connectivity.txt" || return
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "final-logcat-filtered.txt" || return
  pass "ANDROID_PHYSICAL_SMOKE_EVIDENCE passed physical-device summary: $value"
}

require_manifest() {
  local manifest="$ROOT_DIR/build/release/$TAG-cross-platform-sha256.txt"
  if [[ ! -f "$manifest" ]]; then
    fail "cross-platform checksum manifest missing: $manifest"
    return
  fi
  run_required "cross-platform checksum manifest verifies" shasum -a 256 -c "$manifest"
}

if [[ -z "$TAG" || "$TAG" == "-h" || "$TAG" == "--help" || "$TAG" == "help" ]]; then
  usage
  exit 64
fi
if [[ ! "$TAG" =~ build[0-9]+$ ]]; then
  echo "ERROR: tag must end with build<N>, got: $TAG" >&2
  exit 64
fi
BUILD_NUM="${TAG##*build}"

if [[ ! "$TAG" =~ build[0-9]+$ ]]; then
  echo "ERROR: tag must end with build<N>, got: $TAG" >&2
  exit 64
fi

cd "$ROOT_DIR"

printf 'Final release readiness for %s\n' "$ROOT_DIR"
printf 'tag=%s\n' "$TAG"
printf 'ALLOW_EXTERNAL_BLOCKERS=%s\n' "$ALLOW_EXTERNAL_BLOCKERS"

check_shell_syntax \
  release.sh \
  scripts/build-android-bridge.sh \
  scripts/build-apple-release-local.sh \
  scripts/configure-testflight-env.sh \
  scripts/collect-apple-signing-evidence.sh \
  scripts/collect-apple-smoke-evidence.sh \
  scripts/collect-server-production-evidence.sh \
  scripts/diagnose-apple-signing.sh \
  scripts/build-windows-service.sh \
  scripts/deploy-server-vps.sh \
  scripts/final-release-readiness.sh \
  scripts/local-readiness-gate.sh \
  scripts/package-release-artifacts.sh \
  scripts/prepare-external-smoke-kit.sh \
  scripts/package-server.sh \
  scripts/package-windows-runtime.sh \
  scripts/test-server-deploy-safety.sh \
  scripts/test-external-smoke-kit.sh \
  scripts/test-windows-installer-packaging.sh \
  scripts/preflight-android-release.sh \
  scripts/preflight-testflight.sh \
  scripts/preflight-windows-desktop.sh \
  scripts/smoke-android-release-imported-profile.sh \
  scripts/server-public-smoke-vps.sh \
  scripts/smoke-android-imported-profile.sh \
  scripts/write-smoke-evidence-summary.sh

run_required "git diff hygiene" git diff --check
run_required "release manifest format test" scripts/test-release-manifest-format.sh
run_required "server deploy safety test" scripts/test-server-deploy-safety.sh
run_required "external smoke kit test" scripts/test-external-smoke-kit.sh
run_required "windows installer packaging test" scripts/test-windows-installer-packaging.sh

require_manifest

printf '\n==> Android release preflight\n'
if EXPECTED_ANDROID_VERSION_CODE="$BUILD_NUM" ANDROID_HOME="$ANDROID_HOME" scripts/preflight-android-release.sh; then
  pass "Android release preflight"
else
  fail "Android release preflight"
fi

printf '\n==> TestFlight preflight\n'
if ALLOW_EXTERNAL_BLOCKERS="$ALLOW_EXTERNAL_BLOCKERS" scripts/preflight-testflight.sh "$TAG"; then
  pass "TestFlight preflight"
else
  fail "TestFlight preflight"
fi

printf '\n==> Windows desktop preflight\n'
if ALLOW_EXTERNAL_BLOCKERS="$ALLOW_EXTERNAL_BLOCKERS" ANDROID_HOME="$ANDROID_HOME" scripts/preflight-windows-desktop.sh; then
  pass "Windows desktop preflight"
else
  fail "Windows desktop preflight"
fi

printf '\n==> External runtime evidence\n'
require_android_physical_evidence
require_summary_txt_evidence IPHONE_TESTFLIGHT_SMOKE_EVIDENCE iphone_testflight_network_extension "iPhone TestFlight Network Extension smoke"
require_summary_txt_evidence MACOS_TESTFLIGHT_SMOKE_EVIDENCE macos_testflight_packet_tunnel "signed macOS Packet Tunnel smoke"
require_windows_runtime_evidence
require_summary_txt_evidence WINDOWS_INSTALLER_SMOKE_EVIDENCE windows_installer_smoke "Windows EXE build/sign/install smoke"
require_summary_txt_evidence SERVER_PRODUCTION_SMOKE_EVIDENCE server_production_smoke "production-port server/client smoke after promote"

printf '\nFinal readiness summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi
