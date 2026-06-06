#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
MODE="${MODE:-dry-run}"
SSH_TARGET="$SSH_USER@$HOST"
REMOTE_TMP="/tmp/vk-turn-proxy-server.next"
REMOTE_BACKUP_DIR="/var/backups/vk-turn-proxy-ios"
SERVICE_NAME="vk-turn-proxy-ios.service"
PROD_BINARY="/usr/local/bin/vk-turn-proxy-server"
STAGED_BINARY="/usr/local/bin/vk-turn-proxy-server.next"
UNIT_PATH="/etc/systemd/system/$SERVICE_NAME"
ENV_PATH="/etc/vk-turn-proxy-ios.env"
LOGROTATE_PATH="/etc/logrotate.d/vk-turn-proxy-ios"
DRY_LISTEN="${DRY_LISTEN:-127.0.0.1:56014}"
DRY_HEALTH="${DRY_HEALTH:-127.0.0.1:56085}"
DRY_CONNECT="${DRY_CONNECT:-127.0.0.1:51820}"
CONFIRM_PRODUCTION_PROMOTE="${CONFIRM_PRODUCTION_PROMOTE:-}"

usage() {
  cat >&2 <<EOF
Usage:
  MODE=dry-run        $0
  MODE=install-staged $0
  MODE=promote        $0
  MODE=rollback       $0

Environment:
  HOST=$HOST
  SSH_USER=$SSH_USER
  DRY_LISTEN=$DRY_LISTEN
  DRY_HEALTH=$DRY_HEALTH
  DRY_CONNECT=$DRY_CONNECT
  CONFIRM_PRODUCTION_PROMOTE=$CONFIRM_PRODUCTION_PROMOTE

Modes:
  dry-run        Uploads package and runs the new binary on localhost-only ports.
  install-staged Uploads binary/unit/env/logrotate to staging paths, does not restart production.
  promote        Requires CONFIRM_PRODUCTION_PROMOTE=$HOST:56004, backs up current production files,
                 installs staged binary/unit/logrotate, restarts service, checks health,
                 and automatically rolls back if post-promote health fails.
  rollback       Restores the latest backup made by promote and restarts service.
EOF
}

case "$MODE" in
  dry-run|install-staged|promote|rollback) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 64 ;;
esac

if [[ "$MODE" == "promote" && "$CONFIRM_PRODUCTION_PROMOTE" != "$HOST:56004" ]]; then
  cat >&2 <<EOF
ERROR: refusing production promote without explicit confirmation.

Required:
  CONFIRM_PRODUCTION_PROMOTE=$HOST:56004 MODE=promote SSH_USER=$SSH_USER HOST=$HOST $0

Run a public second-port client smoke before promoting production 56004.
EOF
  exit 64
fi

if [[ "$MODE" == "dry-run" ]]; then
  case "$DRY_LISTEN" in
    *:56004|56004)
      echo "ERROR: refusing dry-run on production port 56004: DRY_LISTEN=$DRY_LISTEN" >&2
      exit 64
      ;;
  esac
fi

ssh_root() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
}

copy_to_server() {
  scp -q "$1" "$SSH_TARGET:$2"
}

build_package() {
  "$ROOT_DIR/scripts/package-server.sh" >/tmp/vkturn-package.out
  awk -F= '/^package=/{print $2}' /tmp/vkturn-package.out
}

remote_unpack_package() {
  local package="$1"
  copy_to_server "$package" "$REMOTE_TMP.tar.gz"
  ssh_root "rm -rf '$REMOTE_TMP' && mkdir -p '$REMOTE_TMP' && tar -xzf '$REMOTE_TMP.tar.gz' -C '$REMOTE_TMP' --strip-components=1"
}

run_remote_dry_run() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" bash -s -- \
    "$REMOTE_TMP/vk-turn-proxy-server" \
    "$DRY_LISTEN" \
    "$DRY_CONNECT" \
    "$DRY_HEALTH" <<'REMOTE'
set -euo pipefail
binary="$1"
listen="$2"
connect="$3"
health="$4"
log=/tmp/vk-turn-proxy-dry-run.log
rm -f "$log"
chmod +x "$binary"
"$binary" \
  -listen "$listen" \
  -connect "$connect" \
  -srtp \
  -health-listen "$health" \
  -session-idle-timeout 2m >"$log" 2>&1 &
pid=$!
trap 'kill "$pid" >/dev/null 2>&1 || true; wait "$pid" >/dev/null 2>&1 || true' EXIT
for _ in $(seq 1 30); do
  if curl -fsS "http://$health/healthz" >/dev/null 2>&1; then
    break
  fi
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    cat "$log" >&2
    exit 1
  fi
  sleep 0.25
done
curl -fsS "http://$health/healthz"
curl -fsS "http://$health/readyz"
curl -fsS "http://$health/metrics" | head -20
cat "$log"
REMOTE
}

install_staged() {
  ssh_root "install -m 0755 '$REMOTE_TMP/vk-turn-proxy-server' '$STAGED_BINARY'"
  ssh_root "install -m 0644 '$REMOTE_TMP/vk-turn-proxy-ios.service' '/tmp/vk-turn-proxy-ios.service.next'"
  ssh_root "install -m 0644 '$REMOTE_TMP/vk-turn-proxy-ios.logrotate' '/tmp/vk-turn-proxy-ios.logrotate.next'"
  ssh_root "test -f '$ENV_PATH' || install -m 0644 '$REMOTE_TMP/vk-turn-proxy-ios.env.example' '$ENV_PATH'"
  ssh_root "sha256sum '$STAGED_BINARY'"
}

write_remote_evidence() {
  local backup_dir="$1"
  local label="$2"
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" bash -s -- \
    "$backup_dir" "$label" "$SERVICE_NAME" "$PROD_BINARY" "$STAGED_BINARY" "$UNIT_PATH" "$ENV_PATH" "$LOGROTATE_PATH" <<'REMOTE'
set -euo pipefail
backup_dir="$1"
label="$2"
service_name="$3"
prod_binary="$4"
staged_binary="$5"
unit_path="$6"
env_path="$7"
logrotate_path="$8"
out="$backup_dir/$label.txt"
{
  echo "timestamp_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "hostname=$(hostname)"
  echo "service=$service_name"
  echo
  echo "== sha256 =="
  for path in "$prod_binary" "$staged_binary" "$unit_path" "$env_path" "$logrotate_path"; do
    if [ -f "$path" ]; then
      sha256sum "$path"
    else
      echo "missing $path"
    fi
  done
  echo
  echo "== systemctl is-active =="
  systemctl is-active "$service_name" || true
  echo
  echo "== systemctl status =="
  systemctl status "$service_name" --no-pager -l || true
  echo
  echo "== listeners =="
  ss -ltnup | grep -E ':(56004|56080|56014|56085) ' || true
} >"$out"
echo "$out"
REMOTE
}

promote() {
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  ssh_root "mkdir -p '$REMOTE_BACKUP_DIR/$stamp'"
  ssh_root "test -f '$PROD_BINARY' && cp -a '$PROD_BINARY' '$REMOTE_BACKUP_DIR/$stamp/vk-turn-proxy-server' || true"
  ssh_root "test -f '$UNIT_PATH' && cp -a '$UNIT_PATH' '$REMOTE_BACKUP_DIR/$stamp/vk-turn-proxy-ios.service' || true"
  ssh_root "test -f '$ENV_PATH' && cp -a '$ENV_PATH' '$REMOTE_BACKUP_DIR/$stamp/vk-turn-proxy-ios.env' || true"
  ssh_root "test -f '$LOGROTATE_PATH' && cp -a '$LOGROTATE_PATH' '$REMOTE_BACKUP_DIR/$stamp/vk-turn-proxy-ios.logrotate' || true"
  write_remote_evidence "$REMOTE_BACKUP_DIR/$stamp" "before-promote"
  ssh_root "install -m 0755 '$STAGED_BINARY' '$PROD_BINARY'"
  ssh_root "install -m 0644 '/tmp/vk-turn-proxy-ios.service.next' '$UNIT_PATH'"
  ssh_root "install -m 0644 '/tmp/vk-turn-proxy-ios.logrotate.next' '$LOGROTATE_PATH'"
  ssh_root "systemctl daemon-reload && systemctl restart '$SERVICE_NAME'"
  sleep 3
  if ! ssh_root "systemctl is-active --quiet '$SERVICE_NAME' && curl -fsS http://127.0.0.1:56080/healthz && curl -fsS http://127.0.0.1:56080/readyz"; then
    echo "ERROR: post-promote health failed; rolling back from $REMOTE_BACKUP_DIR/$stamp" >&2
    write_remote_evidence "$REMOTE_BACKUP_DIR/$stamp" "failed-promote"
    restore_backup "$REMOTE_BACKUP_DIR/$stamp"
    write_remote_evidence "$REMOTE_BACKUP_DIR/$stamp" "after-auto-rollback"
    echo "auto_rolled_back_from=$REMOTE_BACKUP_DIR/$stamp" >&2
    exit 1
  fi
  write_remote_evidence "$REMOTE_BACKUP_DIR/$stamp" "after-promote"
  echo "promoted_backup=$REMOTE_BACKUP_DIR/$stamp"
}

restore_backup() {
  local backup_dir="$1"
  ssh_root "test -f '$backup_dir/vk-turn-proxy-server' && install -m 0755 '$backup_dir/vk-turn-proxy-server' '$PROD_BINARY'"
  ssh_root "test -f '$backup_dir/vk-turn-proxy-ios.service' && install -m 0644 '$backup_dir/vk-turn-proxy-ios.service' '$UNIT_PATH'"
  ssh_root "test -f '$backup_dir/vk-turn-proxy-ios.env' && install -m 0644 '$backup_dir/vk-turn-proxy-ios.env' '$ENV_PATH' || true"
  ssh_root "test -f '$backup_dir/vk-turn-proxy-ios.logrotate' && install -m 0644 '$backup_dir/vk-turn-proxy-ios.logrotate' '$LOGROTATE_PATH' || true"
  ssh_root "systemctl daemon-reload && systemctl restart '$SERVICE_NAME' && systemctl is-active --quiet '$SERVICE_NAME'"
}

rollback() {
  local latest
  latest="$(ssh_root "ls -1dt '$REMOTE_BACKUP_DIR'/* 2>/dev/null | head -1")"
  if [[ -z "$latest" ]]; then
    echo "No backup found under $REMOTE_BACKUP_DIR" >&2
    exit 1
  fi
  restore_backup "$latest"
  echo "rolled_back_from=$latest"
}

if [[ "$MODE" == "rollback" ]]; then
  rollback
  exit 0
fi

PACKAGE="$(build_package)"
remote_unpack_package "$PACKAGE"

case "$MODE" in
  dry-run)
    run_remote_dry_run
    ;;
  install-staged)
    install_staged
    ;;
  promote)
    install_staged
    promote
    ;;
esac
