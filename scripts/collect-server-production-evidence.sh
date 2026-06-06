#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
SSH_TARGET="$SSH_USER@$HOST"
EVIDENCE_DIR="${1:-}"
BACKUP_DIR="${BACKUP_DIR:-}"
CLIENT_SMOKE_LOG="${CLIENT_SMOKE_LOG:-}"
MODE="${MODE:-final}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/collect-server-production-evidence.sh <evidence-dir>

Environment:
  MODE=final|baseline                                      default: final
  HOST=142.252.220.91
  SSH_USER=root
  BACKUP_DIR=/var/backups/vk-turn-proxy-ios/<timestamp>   optional promote backup
  CLIENT_SMOKE_LOG=/path/to/production-client-smoke.log    required in MODE=final

Read-only collector. It does not promote, rollback, restart, or edit production.
It gathers systemd/listener/health evidence.

MODE=baseline writes server_production_baseline for current production state.
This does not satisfy final-release readiness.

MODE=final requires healthz=ok, readyz=ready, :56004 listener, active systemd
service, and a production client smoke log. It writes server_production_smoke
summary.txt for final readiness.
EOF
}

case "$MODE" in
  baseline|final) ;;
  *) echo "Unsupported MODE: $MODE" >&2; usage; exit 64 ;;
esac

if [[ -z "$EVIDENCE_DIR" || "$EVIDENCE_DIR" == "-h" || "$EVIDENCE_DIR" == "--help" || "$EVIDENCE_DIR" == "help" ]]; then
  usage
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"

ssh_readonly() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
}

copy_remote_file_if_exists() {
  local remote="$1"
  local local_name="$2"
  if ssh_readonly "test -f '$remote'"; then
    scp -q "$SSH_TARGET:$remote" "$EVIDENCE_DIR/$local_name"
  fi
}

{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "host=$HOST"
  echo "ssh_user=$SSH_USER"
  echo "mode=$MODE"
  echo "backup_dir=$BACKUP_DIR"
  echo "client_smoke_log=$CLIENT_SMOKE_LOG"
} > "$EVIDENCE_DIR/collector.txt"

ssh_readonly "systemctl is-active vk-turn-proxy-ios.service" > "$EVIDENCE_DIR/systemctl-is-active.txt" 2>&1 || true
ssh_readonly "systemctl status vk-turn-proxy-ios.service --no-pager -l" > "$EVIDENCE_DIR/systemctl-status.txt" 2>&1 || true
ssh_readonly "curl -fsS http://127.0.0.1:56080/healthz" > "$EVIDENCE_DIR/healthz.txt" 2>&1 || true
ssh_readonly "curl -fsS http://127.0.0.1:56080/readyz" > "$EVIDENCE_DIR/readyz.txt" 2>&1 || true
ssh_readonly "curl -fsS http://127.0.0.1:56080/metrics | head -100" > "$EVIDENCE_DIR/metrics-head.txt" 2>&1 || true
ssh_readonly "ss -ltnup | grep -E ':(56004|56080) ' || true" > "$EVIDENCE_DIR/listeners.txt" 2>&1 || true
ssh_readonly "sha256sum /usr/local/bin/vk-turn-proxy-server /etc/systemd/system/vk-turn-proxy-ios.service /etc/logrotate.d/vk-turn-proxy-ios 2>/dev/null || true" > "$EVIDENCE_DIR/production-sha256.txt" 2>&1 || true
ssh_readonly "tail -200 /var/log/vk-turn-proxy-ios.log 2>/dev/null || journalctl -u vk-turn-proxy-ios.service -n 200 --no-pager" > "$EVIDENCE_DIR/server-log-tail.txt" 2>&1 || true

if [[ -n "$BACKUP_DIR" ]]; then
  copy_remote_file_if_exists "$BACKUP_DIR/before-promote.txt" "before-promote.txt"
  copy_remote_file_if_exists "$BACKUP_DIR/after-promote.txt" "after-promote.txt"
fi

if [[ "$MODE" == "final" && -z "$CLIENT_SMOKE_LOG" ]]; then
  echo "CLIENT_SMOKE_LOG is required in MODE=final" >&2
  exit 1
fi

if [[ -n "$CLIENT_SMOKE_LOG" ]]; then
  if [[ ! -f "$CLIENT_SMOKE_LOG" ]]; then
    echo "CLIENT_SMOKE_LOG does not exist: $CLIENT_SMOKE_LOG" >&2
    exit 1
  fi
  cp "$CLIENT_SMOKE_LOG" "$EVIDENCE_DIR/client-smoke.log"
fi

required=(
  systemctl-is-active.txt
  listeners.txt
  production-sha256.txt
)
if [[ "$MODE" == "final" ]]; then
  required+=(healthz.txt readyz.txt client-smoke.log)
fi
for file in "${required[@]}"; do
  if [[ ! -s "$EVIDENCE_DIR/$file" ]]; then
    echo "Missing or empty required server evidence file: $EVIDENCE_DIR/$file" >&2
    exit 1
  fi
done

if ! grep -q '^active$' "$EVIDENCE_DIR/systemctl-is-active.txt"; then
  echo "Production service is not active according to systemctl-is-active.txt" >&2
  exit 1
fi
if ! grep -q ':56004' "$EVIDENCE_DIR/listeners.txt"; then
  echo "Production listener evidence does not show :56004" >&2
  exit 1
fi

if [[ "$MODE" == "final" ]]; then
  if ! grep -q '^ok$' "$EVIDENCE_DIR/healthz.txt"; then
    echo "Production healthz did not return ok" >&2
    exit 1
  fi
  if ! grep -q '^ready$' "$EVIDENCE_DIR/readyz.txt"; then
    echo "Production readyz did not return ready" >&2
    exit 1
  fi
  "$ROOT_DIR/scripts/write-smoke-evidence-summary.sh" server_production_smoke "$EVIDENCE_DIR"
else
  "$ROOT_DIR/scripts/write-smoke-evidence-summary.sh" server_production_baseline "$EVIDENCE_DIR"
fi
printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"
