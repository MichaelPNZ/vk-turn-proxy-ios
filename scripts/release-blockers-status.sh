#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-v1.0-build156}"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
RUN_APPLE_SIGNING="${RUN_APPLE_SIGNING:-1}"
RUN_SERVER_BASELINE="${RUN_SERVER_BASELINE:-1}"
RUN_GITHUB="${RUN_GITHUB:-1}"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/build/release-status/$TAG"}"

mkdir -p "$OUT_DIR"

status_file="$OUT_DIR/status.tsv"
: > "$status_file"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/release-blockers-status.sh [tag]

Environment:
  OUT_DIR=build/release-status/<tag>
  RUN_GITHUB=1|0          default: 1, reads GitHub Actions state via gh
  RUN_APPLE_SIGNING=1|0   default: 1, runs read-only Apple signing collector
  RUN_SERVER_BASELINE=1|0 default: 1, runs read-only production baseline collector
  HOST=142.252.220.91
  SSH_USER=root

Read-only status collector. It does not promote production, upload TestFlight
builds, install profiles, modify keychains, install APKs, or start VPNs.
EOF
}

if [[ "$TAG" == "-h" || "$TAG" == "--help" || "$TAG" == "help" ]]; then
  usage
  exit 64
fi

write_status() {
  local area="$1"
  local state="$2"
  local detail="$3"
  printf '%s\t%s\t%s\n' "$area" "$state" "$detail" | tee -a "$status_file" >/dev/null
}

summary_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key {value=$2} END {print value}' "$file" 2>/dev/null || true
}

has_summary_type_passed() {
  local dir="$1"
  local evidence_type="$2"
  [[ -f "$dir/summary.txt" ]] &&
    grep -q '^result=passed$' "$dir/summary.txt" &&
    grep -q "^evidence_type=$evidence_type$" "$dir/summary.txt"
}

has_apple_smoke_passed() {
  local dir="$1"
  local evidence_type="$2"
  local mode="$3"
  local summary="$dir/summary.txt"
  [[ -f "$summary" ]] || return 1
  grep -q '^result=passed$' "$summary" || return 1
  grep -q "^evidence_type=$evidence_type$" "$summary" || return 1
  [[ "$(summary_value "$summary" apple_smoke_mode)" == "$mode" ]] || return 1
  [[ "$(summary_value "$summary" connected_cleanly)" == "1" ]] || return 1
  [[ "$(summary_value "$summary" disconnected_cleanly)" == "1" ]] || return 1
  [[ "$(summary_value "$summary" attachment_count)" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$(summary_value "$summary" supporting_evidence_file_count)" =~ ^[1-9][0-9]*$ ]] || return 1
  if [[ "$mode" == "iphone" ]]; then
    [[ "$(summary_value "$summary" provided_file_count)" =~ ^[1-9][0-9]*$ ]] || return 1
  fi
  local actual_supporting_count
  actual_supporting_count="$(find "$dir" -maxdepth 1 -type f ! -name summary.txt ! -name notes.txt | wc -l | tr -d ' ')"
  [[ "$actual_supporting_count" -gt 0 ]] || return 1
}

has_android_physical_smoke_passed() {
  local dir="$1"
  local summary="$dir/summary.txt"
  [[ -f "$summary" ]] || return 1
  grep -q '^result=passed$' "$summary" || return 1
  grep -q '^evidence_type=android_physical_smoke$' "$summary" || return 1
  [[ "$(summary_value "$summary" attachment_count)" =~ ^[1-9][0-9]*$ ]] || return 1
  grep -q '^require_physical_device=1$' "$summary" || return 1
  grep -q '^device_qemu=0$' "$summary" || return 1
  grep -q '^wireguard_attached_observed=1$' "$summary" || return 1
  grep -q '^vpn_network_observed=1$' "$summary" || return 1
  grep -q '^vpn_stop_cleaned=1$' "$summary" || return 1
  [[ -f "$dir/device-qemu.txt" ]] || return 1
  [[ "$(tr -d '\r' < "$dir/device-qemu.txt" | head -1)" == "0" ]] || return 1
  [[ -f "$dir/running-connectivity.txt" ]] || return 1
  [[ -f "$dir/stopped-connectivity.txt" ]] || return 1
  [[ -f "$dir/final-logcat-filtered.txt" ]] || return 1
  grep -q 'VPN:com.vkturnproxy.android' "$dir/running-connectivity.txt" || return 1
  if grep -q 'VPN:com.vkturnproxy.android' "$dir/stopped-connectivity.txt"; then
    return 1
  fi
  grep -q 'mobilebridge: WireGuard attached' "$dir/final-logcat-filtered.txt" || return 1
  if grep -Eqi 'FATAL EXCEPTION|WireGuard attach failed|CreateTUNFromFile failed|IpcSet failed' "$dir/final-logcat-filtered.txt"; then
    return 1
  fi
}

has_windows_runtime_smoke_passed() {
  local dir="$1"
  local summary="$dir/summary.json"
  [[ -f "$summary" ]] || return 1
  grep -q '"ok"[[:space:]]*:[[:space:]]*true' "$summary" || return 1
  grep -q '"evidenceType"[[:space:]]*:[[:space:]]*"windows_runtime_smoke"' "$summary" || return 1
  grep -q '"keepRunning"[[:space:]]*:[[:space:]]*false' "$summary" || return 1
  local marker
  for marker in validateOk serviceInstalled wireguardAttachedObserved programDataStatusCaptured stopVerified; do
    grep -q "\"$marker\"[[:space:]]*:[[:space:]]*true" "$summary" || return 1
  done
  [[ -f "$dir/transcript.txt" ]] || return 1
  [[ -f "$dir/validate.txt" ]] || return 1
  [[ -f "$dir/install-service.txt" ]] || return 1
  [[ -f "$dir/start-tunnel.txt" ]] || return 1
  [[ -f "$dir/status-running.json" ]] || return 1
  [[ -f "$dir/programdata-status-running.json" ]] || return 1
  [[ -f "$dir/stop-tunnel.txt" ]] || return 1
  [[ -f "$dir/status-stopped.json" ]] || return 1
  grep -q '"state"[[:space:]]*:[[:space:]]*"wireguard_attached"' "$dir/status-running.json" || return 1
  grep -q '"state"[[:space:]]*:[[:space:]]*"wireguard_attached"' "$dir/programdata-status-running.json" || return 1
  grep -q '"state"[[:space:]]*:[[:space:]]*"stopped"' "$dir/status-stopped.json" || return 1
}

has_windows_installer_smoke_passed() {
  local dir="$1"
  local summary="$dir/summary.txt"
  [[ -f "$summary" ]] || return 1
  grep -q '^result=passed$' "$summary" || return 1
  grep -q '^evidence_type=windows_installer_smoke$' "$summary" || return 1
  [[ "$(summary_value "$summary" attachment_count)" =~ ^[1-9][0-9]*$ ]] || return 1
  local key
  for key in installer_built signature_verified installed_cleanly launched_cleanly uninstalled_cleanly; do
    [[ "$(summary_value "$summary" "$key")" == "1" ]] || return 1
  done
  local installer_sha256
  installer_sha256="$(summary_value "$summary" installer_sha256)"
  [[ "$installer_sha256" =~ ^[a-fA-F0-9]{64}$ ]] || return 1
  [[ -f "$dir/installer-build-transcript.txt" ]] || return 1
  [[ -f "$dir/authenticode-signature.txt" ]] || return 1
  [[ -f "$dir/installer-sha256.txt" ]] || return 1
  [[ -f "$dir/install-transcript.txt" ]] || return 1
  [[ -f "$dir/launch-or-service-smoke.txt" ]] || return 1
  [[ -f "$dir/uninstall-transcript.txt" ]] || return 1
  grep -Eqi 'Status[[:space:]]*:[[:space:]]*Valid([[:space:]]|$)' "$dir/authenticode-signature.txt" || return 1
  grep -qi "$installer_sha256" "$dir/installer-sha256.txt" || return 1
}

has_server_production_smoke_passed() {
  local dir="$1"
  local summary="$dir/summary.txt"
  [[ -f "$summary" ]] || return 1
  grep -q '^result=passed$' "$summary" || return 1
  grep -q '^evidence_type=server_production_smoke$' "$summary" || return 1
  [[ "$(summary_value "$summary" attachment_count)" =~ ^[1-9][0-9]*$ ]] || return 1
  [[ "$(summary_value "$summary" service)" == "active" ]] || return 1
  [[ "$(summary_value "$summary" listener_56004)" == "present" ]] || return 1
  [[ "$(summary_value "$summary" listener_56080)" == "present" ]] || return 1
  [[ "$(summary_value "$summary" healthz)" == "ok" ]] || return 1
  [[ "$(summary_value "$summary" readyz)" == "ready" ]] || return 1
  [[ "$(summary_value "$summary" metrics)" == "present" ]] || return 1
  [[ "$(summary_value "$summary" production_client_smoke_log)" == "present" ]] || return 1
  [[ -f "$dir/systemctl-is-active.txt" ]] || return 1
  [[ -f "$dir/listeners.txt" ]] || return 1
  [[ -f "$dir/healthz.txt" ]] || return 1
  [[ -f "$dir/readyz.txt" ]] || return 1
  [[ -f "$dir/metrics-head.txt" ]] || return 1
  [[ -f "$dir/production-sha256.txt" ]] || return 1
  [[ -f "$dir/server-status.txt" ]] || return 1
  [[ -f "$dir/server-log-tail.txt" ]] || return 1
  [[ -s "$dir/client-smoke.log" ]] || return 1
  grep -q '^active$' "$dir/systemctl-is-active.txt" || return 1
  grep -q ':56004' "$dir/listeners.txt" || return 1
  grep -q ':56080' "$dir/listeners.txt" || return 1
  grep -q '^ok$' "$dir/healthz.txt" || return 1
  grep -q '^ready$' "$dir/readyz.txt" || return 1
  grep -q '^vk_turn_proxy_' "$dir/metrics-head.txt" || return 1
}

check_git() {
  local head
  head="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
  write_status git info "head=$head"
  if [[ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]]; then
    write_status git blocked "working_tree=dirty"
  else
    write_status git ready "working_tree=clean"
  fi
  if git -C "$ROOT_DIR" rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
    write_status git ready "tag_exists=$TAG"
  else
    write_status git blocked "tag_missing=$TAG"
  fi
}

check_github() {
  if [[ "$RUN_GITHUB" != "1" ]]; then
    write_status github skipped "RUN_GITHUB=0"
    return
  fi
  if ! command -v gh >/dev/null 2>&1; then
    write_status github blocked "gh_missing"
    return
  fi
  if ! gh auth status >/dev/null 2>&1; then
    write_status github blocked "gh_not_authenticated"
    return
  fi

  local head run
  head="$(git -C "$ROOT_DIR" rev-parse HEAD)"
  run="$(gh run list \
    --repo MichaelPNZ/vk-turn-proxy-ios \
    --branch main \
    --limit 20 \
    --json databaseId,workflowName,status,conclusion,headSha,url \
    --jq ".[] | select(.workflowName == \"Release Gates\" and .headSha == \"$head\") | [.databaseId, .status, (if .conclusion == null or .conclusion == \"\" then \"none\" else .conclusion end), .url] | @tsv" \
    | head -1 || true)"
  if [[ -z "$run" ]]; then
    write_status github blocked "release_gates_run_missing_for_head=$head"
    return
  fi
  IFS=$'\t' read -r run_id run_status run_conclusion run_url <<<"$run"
  if [[ "$run_status" == "completed" && "$run_conclusion" == "success" ]]; then
    write_status github ready "release_gates_success run=$run_id url=$run_url"
  else
    write_status github blocked "release_gates_not_success run=$run_id status=$run_status conclusion=$run_conclusion url=$run_url"
  fi

  local artifact
  artifact="$(gh api "repos/MichaelPNZ/vk-turn-proxy-ios/actions/runs/$run_id/artifacts" \
    --jq ".artifacts[] | select(.name == \"vk-turn-proxy-$TAG-ci-artifacts\") | [.size_in_bytes, .expired] | @tsv" \
    | head -1 || true)"
  if [[ -z "$artifact" ]]; then
    write_status github blocked "ci_artifact_missing run=$run_id"
  else
    IFS=$'\t' read -r artifact_size artifact_expired <<<"$artifact"
    if [[ "$artifact_expired" == "false" ]]; then
      write_status github ready "ci_artifact_present size=$artifact_size expired=$artifact_expired"
    else
      write_status github blocked "ci_artifact_expired size=$artifact_size"
    fi
  fi

  if gh workflow view "TestFlight Release" --repo MichaelPNZ/vk-turn-proxy-ios >/dev/null 2>&1; then
    write_status github ready "testflight_workflow_registered"
  else
    write_status github blocked "testflight_workflow_missing"
  fi

  local secrets missing_secret missing_count
  secrets="$(gh secret list --repo MichaelPNZ/vk-turn-proxy-ios --json name --jq '.[].name' 2>/dev/null || true)"
  missing_count=0
  for required_secret in \
    APPLE_DISTRIBUTION_CERT_P12_BASE64 \
    APPLE_DISTRIBUTION_CERT_PASSWORD \
    APPLE_PROVISIONING_PROFILES_BASE64 \
    APPSTORE_KEY_ID \
    APPSTORE_ISSUER_ID \
    APPSTORE_CONNECT_API_KEY_P8_BASE64; do
    if grep -q "^$required_secret$" <<<"$secrets"; then
      :
    else
      missing_count=$((missing_count + 1))
      missing_secret="${missing_secret:-}${missing_secret:+,}$required_secret"
    fi
  done
  if [[ "$missing_count" -eq 0 ]]; then
    write_status github ready "testflight_secrets_present"
  else
    write_status github blocked "testflight_secrets_missing count=$missing_count names=$missing_secret"
  fi
}

check_android_physical() {
  local adb="$ANDROID_HOME/platform-tools/adb"
  if [[ ! -x "$adb" ]]; then
    write_status android blocked "adb_missing=$adb"
    return
  fi
  "$adb" devices -l > "$OUT_DIR/adb-devices.txt" 2>&1 || true
  local physical_count
  physical_count="$(awk 'NR > 1 && $2 == "device" && $0 !~ /emulator/ {count++} END {print count + 0}' "$OUT_DIR/adb-devices.txt")"
  if [[ "$physical_count" -gt 0 ]]; then
    write_status android ready "physical_device_connected=$physical_count"
  else
    write_status android blocked "physical_device_missing"
  fi
  if [[ -n "${ANDROID_PHYSICAL_SMOKE_EVIDENCE:-}" ]] &&
    has_android_physical_smoke_passed "$ANDROID_PHYSICAL_SMOKE_EVIDENCE"; then
    write_status android ready "physical_smoke_evidence=$ANDROID_PHYSICAL_SMOKE_EVIDENCE"
  else
    write_status android blocked "ANDROID_PHYSICAL_SMOKE_EVIDENCE_missing_or_contract_failed"
  fi
}

check_apple() {
  if [[ "$RUN_APPLE_SIGNING" != "1" ]]; then
    write_status apple skipped "RUN_APPLE_SIGNING=0"
  else
    local evidence="$OUT_DIR/apple-signing"
    if scripts/collect-apple-signing-evidence.sh "$evidence" > "$OUT_DIR/apple-signing-command.txt" 2>&1; then
      :
    else
      write_status apple blocked "apple_signing_collector_failed output=$OUT_DIR/apple-signing-command.txt"
      return
    fi
    local result blockers ready
    result="$(summary_value "$evidence/summary.txt" result)"
    blockers="$(summary_value "$evidence/summary.txt" blocker_count)"
    ready="$(summary_value "$evidence/summary.txt" testflight_ready)"
    if [[ "$result" == "passed" && "$ready" == "true" ]]; then
      write_status apple ready "testflight_signing_ready blockers=$blockers"
    else
      write_status apple blocked "testflight_signing_not_ready blockers=${blockers:-unknown} evidence=$evidence"
    fi
  fi

  if [[ -n "${IPHONE_TESTFLIGHT_SMOKE_EVIDENCE:-}" ]] &&
    has_apple_smoke_passed "$IPHONE_TESTFLIGHT_SMOKE_EVIDENCE" iphone_testflight_network_extension iphone; then
    write_status apple ready "iphone_testflight_smoke=$IPHONE_TESTFLIGHT_SMOKE_EVIDENCE"
  else
    write_status apple blocked "IPHONE_TESTFLIGHT_SMOKE_EVIDENCE_missing_or_contract_failed"
  fi

  if [[ -n "${MACOS_TESTFLIGHT_SMOKE_EVIDENCE:-}" ]] &&
    has_apple_smoke_passed "$MACOS_TESTFLIGHT_SMOKE_EVIDENCE" macos_testflight_packet_tunnel macos; then
    write_status apple ready "macos_testflight_smoke=$MACOS_TESTFLIGHT_SMOKE_EVIDENCE"
  else
    write_status apple blocked "MACOS_TESTFLIGHT_SMOKE_EVIDENCE_missing_or_contract_failed"
  fi
}

check_windows() {
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      write_status windows ready "windows_host=true"
      ;;
    *)
      write_status windows blocked "windows_host_required current_os=$(uname -s)"
      ;;
  esac

  if [[ -n "${WINDOWS_RUNTIME_SMOKE_EVIDENCE:-}" ]] &&
    has_windows_runtime_smoke_passed "$WINDOWS_RUNTIME_SMOKE_EVIDENCE"; then
    write_status windows ready "runtime_smoke=$WINDOWS_RUNTIME_SMOKE_EVIDENCE"
  else
    write_status windows blocked "WINDOWS_RUNTIME_SMOKE_EVIDENCE_missing_or_contract_failed"
  fi

  if [[ -n "${WINDOWS_INSTALLER_SMOKE_EVIDENCE:-}" ]] &&
    has_windows_installer_smoke_passed "$WINDOWS_INSTALLER_SMOKE_EVIDENCE"; then
    write_status windows ready "installer_smoke=$WINDOWS_INSTALLER_SMOKE_EVIDENCE"
  else
    write_status windows blocked "WINDOWS_INSTALLER_SMOKE_EVIDENCE_missing_or_contract_failed"
  fi
}

check_server() {
  if [[ -n "${SERVER_PRODUCTION_SMOKE_EVIDENCE:-}" ]] &&
    has_server_production_smoke_passed "$SERVER_PRODUCTION_SMOKE_EVIDENCE"; then
    write_status server ready "production_smoke=$SERVER_PRODUCTION_SMOKE_EVIDENCE"
    return
  fi

  write_status server blocked "SERVER_PRODUCTION_SMOKE_EVIDENCE_missing_or_contract_failed"
  if [[ "$RUN_SERVER_BASELINE" != "1" ]]; then
    write_status server skipped "RUN_SERVER_BASELINE=0"
    return
  fi
  local evidence="$OUT_DIR/server-production-baseline"
  if MODE=baseline HOST="$HOST" SSH_USER="$SSH_USER" scripts/collect-server-production-evidence.sh "$evidence" > "$OUT_DIR/server-baseline-command.txt" 2>&1; then
    local service listener health readyz
    service="$(summary_value "$evidence/summary.txt" service)"
    listener="$(summary_value "$evidence/summary.txt" listener_56004)"
    health="$(summary_value "$evidence/summary.txt" healthz)"
    readyz="$(summary_value "$evidence/summary.txt" readyz)"
    write_status server info "baseline service=$service listener_56004=$listener healthz=$health readyz=$readyz evidence=$evidence"
  else
    write_status server blocked "server_baseline_collector_failed output=$OUT_DIR/server-baseline-command.txt"
  fi
}

write_summary() {
  local ready blocked skipped info
  ready="$(awk -F'\t' '$2 == "ready" {count++} END {print count + 0}' "$status_file")"
  blocked="$(awk -F'\t' '$2 == "blocked" {count++} END {print count + 0}' "$status_file")"
  skipped="$(awk -F'\t' '$2 == "skipped" {count++} END {print count + 0}' "$status_file")"
  info="$(awk -F'\t' '$2 == "info" {count++} END {print count + 0}' "$status_file")"
  {
    printf 'result=%s\n' "$(if [[ "$blocked" -eq 0 ]]; then echo ready; else echo blocked; fi)"
    printf 'tag=%s\n' "$TAG"
    printf 'completed_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'ready_count=%s\n' "$ready"
    printf 'blocked_count=%s\n' "$blocked"
    printf 'skipped_count=%s\n' "$skipped"
    printf 'info_count=%s\n' "$info"
    printf 'status_file=%s\n' "$status_file"
  } > "$OUT_DIR/summary.txt"
}

cd "$ROOT_DIR"

check_git
check_github
check_android_physical
check_apple
check_windows
check_server
write_summary

cat "$OUT_DIR/summary.txt"
printf '\nStatus details:\n'
column -ts $'\t' "$status_file" 2>/dev/null || cat "$status_file"
