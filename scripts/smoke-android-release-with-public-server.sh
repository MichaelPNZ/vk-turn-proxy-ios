#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
PUBLIC_LISTEN="${PUBLIC_LISTEN:-0.0.0.0:56014}"
PUBLIC_HEALTH="${PUBLIC_HEALTH:-127.0.0.1:56085}"
CONNECT="${CONNECT:-127.0.0.1:51820}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-20m}"
ANDROID_SMOKE_TIMEOUT_SECONDS="${ANDROID_SMOKE_TIMEOUT_SECONDS:-300}"
BUILD_RELEASE="${BUILD_RELEASE:-1}"
REQUIRE_PHYSICAL_DEVICE="${REQUIRE_PHYSICAL_DEVICE:-0}"
SERIAL="${SERIAL:-}"
ADB="${ADB:-}"
PREF="${PREF:-}"
PROFILE_FILE="${PROFILE_FILE:-}"
IMPORT_LINK="${IMPORT_LINK:-}"
ALLOWED_IPS="${ALLOWED_IPS:-}"
NUM_CONNECTIONS="${NUM_CONNECTIONS:-}"
PEER_ADDRESS="${PEER_ADDRESS:-}"
EVIDENCE_DIR="${1:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/smoke-android-release-with-public-server.sh <evidence-dir>

Environment:
  HOST=142.252.220.91
  SSH_USER=root
  PUBLIC_LISTEN=0.0.0.0:56014
  PUBLIC_HEALTH=127.0.0.1:56085
  CONNECT=127.0.0.1:51820
  SMOKE_TIMEOUT=20m
  ANDROID_SMOKE_TIMEOUT_SECONDS=300
  SERIAL=<adb serial>
  BUILD_RELEASE=1
  REQUIRE_PHYSICAL_DEVICE=0
  PROFILE_FILE=<connection json or vkturnproxy import link>
  IMPORT_LINK=<vkturnproxy import link>

Starts a temporary public second-port server, runs the Android release smoke
against it, captures both server and client evidence, then stops the temporary
server. It refuses production port 56004.
EOF
}

if [[ -z "$EVIDENCE_DIR" || "$EVIDENCE_DIR" == "-h" || "$EVIDENCE_DIR" == "--help" || "$EVIDENCE_DIR" == "help" ]]; then
  usage
  exit 64
fi

case "$PUBLIC_LISTEN" in
  *:56004)
    echo "Refusing to use production port 56004 for Android public smoke." >&2
    exit 64
    ;;
esac

if ! [[ "$ANDROID_SMOKE_TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$ANDROID_SMOKE_TIMEOUT_SECONDS" -lt 1 ]]; then
  echo "ANDROID_SMOKE_TIMEOUT_SECONDS must be a positive integer." >&2
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"
ANDROID_EVIDENCE_DIR="$EVIDENCE_DIR/android"
mkdir -p "$ANDROID_EVIDENCE_DIR"

public_port="${PUBLIC_LISTEN##*:}"
client_peer_address="${PEER_ADDRESS:-$HOST:$public_port}"
started=0
cleanup_done=0

write_summary() {
  local result="$1"
  local reason="${2:-}"
  local attachment_count
  attachment_count="$(
    find "$EVIDENCE_DIR" -maxdepth 1 -type f ! -name summary.txt | wc -l | tr -d ' '
  )"
  {
    printf 'result=%s\n' "$result"
    printf 'evidence_type=android_release_smoke_with_public_server\n'
    printf 'completed_at=%s\n' "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf 'host=%s\n' "$(hostname)"
    printf 'attachment_count=%s\n' "$attachment_count"
    printf 'reason=%s\n' "$reason"
    printf 'server_host=%s\n' "$HOST"
    printf 'ssh_user=%s\n' "$SSH_USER"
    printf 'public_listen=%s\n' "$PUBLIC_LISTEN"
    printf 'public_health=%s\n' "$PUBLIC_HEALTH"
    printf 'connect=%s\n' "$CONNECT"
    printf 'client_peer_address=%s\n' "$client_peer_address"
    printf 'android_evidence_dir=%s\n' "$ANDROID_EVIDENCE_DIR"
    printf 'build_release=%s\n' "$BUILD_RELEASE"
    printf 'require_physical_device=%s\n' "$REQUIRE_PHYSICAL_DEVICE"
    printf 'serial=%s\n' "${SERIAL:-default}"
    printf 'cleanup_done=%s\n' "$cleanup_done"
  } > "$EVIDENCE_DIR/summary.txt"
}

run_server_action() {
  local action="$1"
  local outfile="$2"
  ACTION="$action" \
    HOST="$HOST" \
    SSH_USER="$SSH_USER" \
    PUBLIC_LISTEN="$PUBLIC_LISTEN" \
    PUBLIC_HEALTH="$PUBLIC_HEALTH" \
    CONNECT="$CONNECT" \
    SMOKE_TIMEOUT="$SMOKE_TIMEOUT" \
    "$ROOT_DIR/scripts/server-public-smoke-vps.sh" \
    > "$EVIDENCE_DIR/$outfile" 2>&1
}

cleanup() {
  if [[ "$started" == "1" ]]; then
    run_server_action logs server-logs-before-stop.txt || true
    run_server_action stop server-stop.txt || true
    started=0
    cleanup_done=1
    run_server_action status server-status-after-stop.txt || true
  fi
}
trap cleanup EXIT

run_android_smoke() {
  local android_out="$EVIDENCE_DIR/android-smoke-output.txt"
  local timeout_marker="$EVIDENCE_DIR/android-smoke-timeout.txt"
  rm -f "$timeout_marker"

  (
    env \
      ANDROID_HOME="$ANDROID_HOME" \
      ADB="$ADB" \
      SERIAL="$SERIAL" \
      PREF="$PREF" \
      PROFILE_FILE="$PROFILE_FILE" \
      IMPORT_LINK="$IMPORT_LINK" \
      PEER_ADDRESS="$client_peer_address" \
      ALLOWED_IPS="$ALLOWED_IPS" \
      NUM_CONNECTIONS="$NUM_CONNECTIONS" \
      BUILD_RELEASE="$BUILD_RELEASE" \
      REQUIRE_PHYSICAL_DEVICE="$REQUIRE_PHYSICAL_DEVICE" \
      EVIDENCE_DIR="$ANDROID_EVIDENCE_DIR" \
      "$ROOT_DIR/scripts/smoke-android-release-imported-profile.sh"
  ) > "$android_out" 2>&1 &

  local child_pid="$!"
  (
    sleep "$ANDROID_SMOKE_TIMEOUT_SECONDS"
    if kill -0 "$child_pid" >/dev/null 2>&1; then
      printf 'Android smoke timed out after %s seconds.\n' "$ANDROID_SMOKE_TIMEOUT_SECONDS" > "$timeout_marker"
      kill "$child_pid" >/dev/null 2>&1 || true
      sleep 5
      kill -9 "$child_pid" >/dev/null 2>&1 || true
    fi
  ) &
  local watchdog_pid="$!"

  local status=0
  if wait "$child_pid"; then
    status=0
  else
    status="$?"
  fi

  kill "$watchdog_pid" >/dev/null 2>&1 || true
  wait "$watchdog_pid" >/dev/null 2>&1 || true

  if [[ -f "$timeout_marker" ]]; then
    status=124
  fi
  return "$status"
}

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$HOST"
  echo "ssh_user=$SSH_USER"
  echo "public_listen=$PUBLIC_LISTEN"
  echo "public_health=$PUBLIC_HEALTH"
  echo "connect=$CONNECT"
  echo "smoke_timeout=$SMOKE_TIMEOUT"
  echo "android_smoke_timeout_seconds=$ANDROID_SMOKE_TIMEOUT_SECONDS"
  echo "client_peer_address=$client_peer_address"
} > "$EVIDENCE_DIR/collector.txt"

run_server_action start server-start.txt
started=1
run_server_action status server-status-before-client.txt
run_server_action logs server-logs-before-client.txt

android_status=0
if run_android_smoke; then
  android_status=0
else
  android_status="$?"
fi

run_server_action status server-status-after-client.txt || true
run_server_action logs server-logs-after-client.txt || true
cleanup
trap - EXIT

cleanup_failed=0
if grep -q ":$public_port" "$EVIDENCE_DIR/server-status-after-stop.txt" 2>/dev/null; then
  cleanup_failed=1
fi

if [[ "$cleanup_failed" == "1" ]]; then
  write_summary "failed" "temporary public server listener still appears after stop"
  echo "Temporary public server listener still appears after stop: :$public_port" >&2
  echo "evidence_dir=$EVIDENCE_DIR" >&2
  exit 1
fi

if [[ "$android_status" != "0" ]]; then
  write_summary "failed" "Android smoke failed with exit status $android_status"
  echo "Android public-server release smoke failed with exit status $android_status." >&2
  echo "evidence_dir=$EVIDENCE_DIR" >&2
  exit "$android_status"
fi

if ! grep -q '^result=passed$' "$ANDROID_EVIDENCE_DIR/summary.txt" 2>/dev/null; then
  write_summary "failed" "Android smoke did not write a passed summary"
  echo "Android smoke did not write a passed summary." >&2
  echo "evidence_dir=$EVIDENCE_DIR" >&2
  exit 1
fi

write_summary "passed" "Android release smoke passed against temporary public server"
echo "Android public-server release smoke passed."
printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"
printf 'android_evidence_dir=%s\n' "$ANDROID_EVIDENCE_DIR"
if [[ "$REQUIRE_PHYSICAL_DEVICE" == "1" ]]; then
  printf 'ANDROID_PHYSICAL_SMOKE_EVIDENCE=%s\n' "$ANDROID_EVIDENCE_DIR"
else
  printf 'ANDROID_RELEASE_SMOKE_EVIDENCE=%s\n' "$ANDROID_EVIDENCE_DIR"
fi
