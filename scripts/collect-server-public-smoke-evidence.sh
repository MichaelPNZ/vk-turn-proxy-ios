#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EVIDENCE_DIR="${1:-}"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
PUBLIC_LISTEN="${PUBLIC_LISTEN:-0.0.0.0:56014}"
PUBLIC_HEALTH="${PUBLIC_HEALTH:-127.0.0.1:56085}"
CONNECT="${CONNECT:-127.0.0.1:51820}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-20m}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/collect-server-public-smoke-evidence.sh <evidence-dir>

Environment:
  HOST=142.252.220.91
  SSH_USER=root
  PUBLIC_LISTEN=0.0.0.0:56014
  PUBLIC_HEALTH=127.0.0.1:56085
  CONNECT=127.0.0.1:51820
  SMOKE_TIMEOUT=20m

Starts a temporary second-port server on the VPS, checks health/listener/logs,
then stops it and verifies cleanup. It does not promote, restart, rollback, or
edit the production service on 56004.
EOF
}

if [[ -z "$EVIDENCE_DIR" || "$EVIDENCE_DIR" == "-h" || "$EVIDENCE_DIR" == "--help" || "$EVIDENCE_DIR" == "help" ]]; then
  usage
  exit 64
fi

case "$PUBLIC_LISTEN" in
  *:56004)
    echo "Refusing to use production port 56004 for public smoke." >&2
    exit 64
    ;;
esac

mkdir -p "$EVIDENCE_DIR"

started=0
cleanup() {
  if [[ "$started" == "1" ]]; then
    ACTION=stop \
      HOST="$HOST" \
      SSH_USER="$SSH_USER" \
      PUBLIC_LISTEN="$PUBLIC_LISTEN" \
      PUBLIC_HEALTH="$PUBLIC_HEALTH" \
      CONNECT="$CONNECT" \
      SMOKE_TIMEOUT="$SMOKE_TIMEOUT" \
      "$ROOT_DIR/scripts/server-public-smoke-vps.sh" \
      > "$EVIDENCE_DIR/cleanup-stop.txt" 2>&1 || true
  fi
}
trap cleanup EXIT

run_action() {
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

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$HOST"
  echo "ssh_user=$SSH_USER"
  echo "public_listen=$PUBLIC_LISTEN"
  echo "public_health=$PUBLIC_HEALTH"
  echo "connect=$CONNECT"
  echo "smoke_timeout=$SMOKE_TIMEOUT"
} > "$EVIDENCE_DIR/collector.txt"

run_action start start.txt
started=1
run_action status status-running.txt
run_action logs logs-running.txt
run_action stop stop.txt
started=0
run_action status status-after-stop.txt

listen_port="${PUBLIC_LISTEN##*:}"
health_port="${PUBLIC_HEALTH##*:}"

grep -q '^ok$' "$EVIDENCE_DIR/start.txt" || {
  echo "Public smoke healthz did not return ok." >&2
  exit 1
}
grep -q '^ready$' "$EVIDENCE_DIR/start.txt" || {
  echo "Public smoke readyz did not return ready." >&2
  exit 1
}
grep -q "public_smoke_pid=" "$EVIDENCE_DIR/status-running.txt" || {
  echo "Public smoke status did not include pid." >&2
  exit 1
}
grep -q ":$listen_port" "$EVIDENCE_DIR/status-running.txt" || {
  echo "Public smoke status did not show listener :$listen_port." >&2
  exit 1
}
grep -q "listening on .*:$listen_port" "$EVIDENCE_DIR/logs-running.txt" || {
  echo "Public smoke logs did not show SRTP listener :$listen_port." >&2
  exit 1
}
grep -q "admin health server listening on .*:$health_port" "$EVIDENCE_DIR/logs-running.txt" || {
  echo "Public smoke logs did not show admin health listener :$health_port." >&2
  exit 1
}
grep -q '^stopped$' "$EVIDENCE_DIR/stop.txt" || {
  echo "Public smoke stop did not report stopped." >&2
  exit 1
}
if grep -q ":$listen_port" "$EVIDENCE_DIR/status-after-stop.txt"; then
  echo "Public smoke listener still appears after stop: :$listen_port." >&2
  exit 1
fi

"$ROOT_DIR/scripts/write-smoke-evidence-summary.sh" server_public_smoke "$EVIDENCE_DIR" >/dev/null
cat >> "$EVIDENCE_DIR/summary.txt" <<EOF
public_listen=$PUBLIC_LISTEN
public_health=$PUBLIC_HEALTH
connect=$CONNECT
healthz=ok
readyz=ready
listener_$listen_port=present
cleanup=passed
EOF

printf 'server_public_smoke_evidence=%s\n' "$EVIDENCE_DIR"
