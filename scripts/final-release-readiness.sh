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

summary_txt_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key {value=$2} END {print value}' "$file" 2>/dev/null || true
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
  local marker
  for marker in validateOk serviceInstalled wireguardAttachedObserved programDataStatusCaptured stopVerified; do
    if ! grep -q "\"$marker\"[[:space:]]*:[[:space:]]*true" "$summary"; then
      external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE summary.json does not contain $marker=true: $summary"
      return
    fi
  done
  if ! grep -q '"keepRunning"[[:space:]]*:[[:space:]]*false' "$summary"; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE summary.json must contain keepRunning=false to prove cleanup: $summary"
    return
  fi
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "transcript.txt" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "validate.txt" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "install-service.txt" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "start-tunnel.txt" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "status-running.json" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "programdata-status-running.json" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "stop-tunnel.txt" || return
  require_file_in_dir WINDOWS_RUNTIME_SMOKE_EVIDENCE "$value" "status-stopped.json" || return
  if ! grep -q '"state"[[:space:]]*:[[:space:]]*"wireguard_attached"' "$value/status-running.json"; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE status-running.json does not contain state=wireguard_attached: $value/status-running.json"
    return
  fi
  if ! grep -q '"state"[[:space:]]*:[[:space:]]*"wireguard_attached"' "$value/programdata-status-running.json"; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE programdata-status-running.json does not contain state=wireguard_attached: $value/programdata-status-running.json"
    return
  fi
  if ! grep -q '"state"[[:space:]]*:[[:space:]]*"stopped"' "$value/status-stopped.json"; then
    external_blocker "WINDOWS_RUNTIME_SMOKE_EVIDENCE status-stopped.json does not contain state=stopped: $value/status-stopped.json"
    return
  fi
  pass "WINDOWS_RUNTIME_SMOKE_EVIDENCE passed summary.json evidence contract: $value"
}

require_windows_installer_evidence() {
  local value="${WINDOWS_INSTALLER_SMOKE_EVIDENCE:-}"
  if [[ -z "$value" ]]; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE is not set (Windows EXE build/sign/install smoke)"
    return
  fi
  if [[ ! -d "$value" ]]; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE must be an evidence directory: $value"
    return
  fi
  local summary="$value/summary.txt"
  if [[ ! -f "$summary" ]]; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE missing summary.txt: $summary"
    return
  fi
  if ! grep -q '^result=passed$' "$summary"; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE summary does not contain result=passed: $summary"
    return
  fi
  if ! grep -q '^evidence_type=windows_installer_smoke$' "$summary"; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE summary does not contain evidence_type=windows_installer_smoke: $summary"
    return
  fi
  local attachment_count
  attachment_count="$(summary_txt_value "$summary" attachment_count)"
  if [[ ! "$attachment_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE summary must contain attachment_count > 0: $summary"
    return
  fi
  local key
  for key in installer_built signature_verified installed_cleanly launched_cleanly uninstalled_cleanly; do
    if [[ "$(summary_txt_value "$summary" "$key")" != "1" ]]; then
      external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE summary must contain $key=1: $summary"
      return
    fi
  done
  local installer_sha256
  installer_sha256="$(summary_txt_value "$summary" installer_sha256)"
  if [[ ! "$installer_sha256" =~ ^[a-fA-F0-9]{64}$ ]]; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE summary must contain a 64-hex installer_sha256: $summary"
    return
  fi
  require_file_in_dir WINDOWS_INSTALLER_SMOKE_EVIDENCE "$value" "installer-build-transcript.txt" || return
  require_file_in_dir WINDOWS_INSTALLER_SMOKE_EVIDENCE "$value" "authenticode-signature.txt" || return
  require_file_in_dir WINDOWS_INSTALLER_SMOKE_EVIDENCE "$value" "installer-sha256.txt" || return
  require_file_in_dir WINDOWS_INSTALLER_SMOKE_EVIDENCE "$value" "install-transcript.txt" || return
  require_file_in_dir WINDOWS_INSTALLER_SMOKE_EVIDENCE "$value" "launch-or-service-smoke.txt" || return
  require_file_in_dir WINDOWS_INSTALLER_SMOKE_EVIDENCE "$value" "uninstall-transcript.txt" || return
  if ! grep -Eqi 'Status[[:space:]]*:[[:space:]]*Valid([[:space:]]|$)' "$value/authenticode-signature.txt"; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE authenticode-signature.txt must contain a valid signature status"
    return
  fi
  if ! grep -qi "$installer_sha256" "$value/installer-sha256.txt"; then
    external_blocker "WINDOWS_INSTALLER_SMOKE_EVIDENCE installer-sha256.txt must contain installer_sha256 from summary"
    return
  fi
  pass "WINDOWS_INSTALLER_SMOKE_EVIDENCE passed installer evidence contract: $value"
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
  if ! grep -q '^evidence_type=android_physical_smoke$' "$summary"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE summary does not contain evidence_type=android_physical_smoke: $summary"
    return
  fi
  if ! grep -q '^require_physical_device=1$' "$summary"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE was not produced with REQUIRE_PHYSICAL_DEVICE=1: $summary"
    return
  fi
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "device-qemu.txt" || return
  local device_qemu
  device_qemu="$(tr -d '\r' < "$value/device-qemu.txt" | head -1)"
  if [[ "$device_qemu" != "0" ]]; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE device-qemu.txt must contain 0 for a physical device: $value/device-qemu.txt"
    return
  fi
  if ! grep -q '^device_qemu=0$' "$summary"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE summary does not contain device_qemu=0: $summary"
    return
  fi
  local attachment_count
  attachment_count="$(awk -F= '$1 == "attachment_count" {print $2}' "$summary" | tail -1)"
  if [[ ! "$attachment_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE summary must contain attachment_count > 0: $summary"
    return
  fi
  local marker
  for marker in wireguard_attached_observed vpn_network_observed vpn_stop_cleaned; do
    if ! grep -q "^$marker=1$" "$summary"; then
      external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE summary does not contain $marker=1: $summary"
      return
    fi
  done
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "running-connectivity.txt" || return
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "stopped-connectivity.txt" || return
  require_file_in_dir ANDROID_PHYSICAL_SMOKE_EVIDENCE "$value" "final-logcat-filtered.txt" || return
  if ! grep -q 'VPN:com.vkturnproxy.android' "$value/running-connectivity.txt"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE running-connectivity.txt does not show VPN:com.vkturnproxy.android: $value/running-connectivity.txt"
    return
  fi
  if grep -q 'VPN:com.vkturnproxy.android' "$value/stopped-connectivity.txt"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE stopped-connectivity.txt still shows VPN:com.vkturnproxy.android: $value/stopped-connectivity.txt"
    return
  fi
  if ! grep -q 'mobilebridge: WireGuard attached' "$value/final-logcat-filtered.txt"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE final-logcat-filtered.txt does not show mobilebridge WireGuard attach: $value/final-logcat-filtered.txt"
    return
  fi
  if grep -Eqi 'FATAL EXCEPTION|WireGuard attach failed|CreateTUNFromFile failed|IpcSet failed' "$value/final-logcat-filtered.txt"; then
    external_blocker "ANDROID_PHYSICAL_SMOKE_EVIDENCE final-logcat-filtered.txt contains fatal/error marker: $value/final-logcat-filtered.txt"
    return
  fi
  pass "ANDROID_PHYSICAL_SMOKE_EVIDENCE passed physical-device summary: $value"
}

require_apple_smoke_evidence() {
  local env_name="$1"
  local evidence_type="$2"
  local mode="$3"
  local description="$4"
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
  if [[ "$(summary_txt_value "$summary" apple_smoke_mode)" != "$mode" ]]; then
    external_blocker "$env_name summary must contain apple_smoke_mode=$mode: $summary"
    return
  fi
  if [[ "$(summary_txt_value "$summary" connected_cleanly)" != "1" ]]; then
    external_blocker "$env_name summary must contain connected_cleanly=1: $summary"
    return
  fi
  if [[ "$(summary_txt_value "$summary" disconnected_cleanly)" != "1" ]]; then
    external_blocker "$env_name summary must contain disconnected_cleanly=1: $summary"
    return
  fi
  local attachment_count supporting_count provided_count
  attachment_count="$(summary_txt_value "$summary" attachment_count)"
  supporting_count="$(summary_txt_value "$summary" supporting_evidence_file_count)"
  provided_count="$(summary_txt_value "$summary" provided_file_count)"
  if [[ ! "$attachment_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "$env_name summary must contain attachment_count > 0: $summary"
    return
  fi
  if [[ ! "$supporting_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "$env_name summary must contain supporting_evidence_file_count > 0: $summary"
    return
  fi
  if [[ "$mode" == "iphone" && ! "$provided_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "$env_name iPhone evidence requires provided_file_count > 0: $summary"
    return
  fi
  local actual_supporting_count
  actual_supporting_count="$(find "$value" -maxdepth 1 -type f ! -name summary.txt ! -name notes.txt | wc -l | tr -d ' ')"
  if [[ "$actual_supporting_count" -lt 1 ]]; then
    external_blocker "$env_name must include at least one supporting evidence file besides summary.txt/notes.txt: $value"
    return
  fi
  pass "$env_name passed Apple smoke evidence contract: $value"
}

require_server_production_evidence() {
  local value="${SERVER_PRODUCTION_SMOKE_EVIDENCE:-}"
  if [[ -z "$value" ]]; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE is not set (production-port server/client smoke after promote)"
    return
  fi
  if [[ ! -d "$value" ]]; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE must be an evidence directory: $value"
    return
  fi
  local summary="$value/summary.txt"
  if [[ ! -f "$summary" ]]; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE missing summary.txt: $summary"
    return
  fi
  if ! grep -q '^result=passed$' "$summary"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE summary does not contain result=passed: $summary"
    return
  fi
  if ! grep -q '^evidence_type=server_production_smoke$' "$summary"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE summary does not contain evidence_type=server_production_smoke: $summary"
    return
  fi
  local attachment_count
  attachment_count="$(summary_txt_value "$summary" attachment_count)"
  if [[ ! "$attachment_count" =~ ^[1-9][0-9]*$ ]]; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE summary must contain attachment_count > 0: $summary"
    return
  fi
  local key expected actual
  for key in service listener_56004 listener_56080 healthz readyz metrics production_client_smoke_log; do
    case "$key" in
      service) expected="active" ;;
      listener_56004|listener_56080|metrics|production_client_smoke_log) expected="present" ;;
      healthz) expected="ok" ;;
      readyz) expected="ready" ;;
    esac
    actual="$(summary_txt_value "$summary" "$key")"
    if [[ "$actual" != "$expected" ]]; then
      external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE summary must contain $key=$expected: $summary"
      return
    fi
  done
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "systemctl-is-active.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "listeners.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "healthz.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "readyz.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "metrics-head.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "production-sha256.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "server-status.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "server-log-tail.txt" || return
  require_file_in_dir SERVER_PRODUCTION_SMOKE_EVIDENCE "$value" "client-smoke.log" || return
  if ! grep -q '^active$' "$value/systemctl-is-active.txt"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE systemctl-is-active.txt does not contain active"
    return
  fi
  if ! grep -q ':56004' "$value/listeners.txt"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE listeners.txt does not contain :56004"
    return
  fi
  if ! grep -q ':56080' "$value/listeners.txt"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE listeners.txt does not contain :56080 admin listener"
    return
  fi
  if ! grep -q '^ok$' "$value/healthz.txt"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE healthz.txt does not contain ok"
    return
  fi
  if ! grep -q '^ready$' "$value/readyz.txt"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE readyz.txt does not contain ready"
    return
  fi
  if ! grep -q '^vk_turn_proxy_' "$value/metrics-head.txt"; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE metrics-head.txt does not contain vk_turn_proxy metrics"
    return
  fi
  if [[ ! -s "$value/client-smoke.log" ]]; then
    external_blocker "SERVER_PRODUCTION_SMOKE_EVIDENCE client-smoke.log must be non-empty"
    return
  fi
  pass "SERVER_PRODUCTION_SMOKE_EVIDENCE passed production smoke contract: $value"
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
  scripts/configure-github-testflight-secrets.sh \
  scripts/collect-server-production-evidence.sh \
  scripts/collect-server-public-smoke-evidence.sh \
  scripts/diagnose-apple-signing.sh \
  scripts/install-apple-signing-assets.sh \
  scripts/build-windows-service.sh \
  scripts/deploy-server-vps.sh \
  scripts/final-release-readiness.sh \
  scripts/local-readiness-gate.sh \
  scripts/package-release-artifacts.sh \
  scripts/prepare-external-smoke-kit.sh \
  scripts/release-blockers-status.sh \
  scripts/package-server.sh \
  scripts/package-windows-runtime.sh \
  scripts/test-server-deploy-safety.sh \
  scripts/test-server-public-smoke-evidence-contract.sh \
  scripts/test-android-physical-evidence-contract.sh \
  scripts/test-windows-runtime-evidence-contract.sh \
  scripts/test-windows-installer-evidence-contract.sh \
  scripts/test-apple-signing-evidence-contract.sh \
  scripts/test-github-testflight-secrets-config-contract.sh \
  scripts/test-apple-smoke-evidence-contract.sh \
  scripts/test-server-production-evidence-contract.sh \
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
run_required "server public smoke evidence contract test" scripts/test-server-public-smoke-evidence-contract.sh
run_required "android physical evidence contract test" scripts/test-android-physical-evidence-contract.sh
run_required "windows runtime evidence contract test" scripts/test-windows-runtime-evidence-contract.sh
run_required "windows installer evidence contract test" scripts/test-windows-installer-evidence-contract.sh
run_required "apple signing evidence contract test" scripts/test-apple-signing-evidence-contract.sh
run_required "github testflight secrets config contract test" scripts/test-github-testflight-secrets-config-contract.sh
run_required "apple smoke evidence contract test" scripts/test-apple-smoke-evidence-contract.sh
run_required "server production evidence contract test" scripts/test-server-production-evidence-contract.sh
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
require_apple_smoke_evidence IPHONE_TESTFLIGHT_SMOKE_EVIDENCE iphone_testflight_network_extension iphone "iPhone TestFlight Network Extension smoke"
require_apple_smoke_evidence MACOS_TESTFLIGHT_SMOKE_EVIDENCE macos_testflight_packet_tunnel macos "signed macOS Packet Tunnel smoke"
require_windows_runtime_evidence
require_windows_installer_evidence
require_server_production_evidence

printf '\nFinal readiness summary: %d failure(s), %d warning(s)\n' "$failures" "$warnings"
if (( failures > 0 )); then
  exit 1
fi
