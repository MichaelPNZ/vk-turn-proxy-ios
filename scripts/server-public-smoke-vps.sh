#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
SSH_TARGET="$SSH_USER@$HOST"
ACTION="${ACTION:-start}"
PUBLIC_LISTEN="${PUBLIC_LISTEN:-0.0.0.0:56014}"
PUBLIC_HEALTH="${PUBLIC_HEALTH:-127.0.0.1:56085}"
CONNECT="${CONNECT:-127.0.0.1:51820}"
SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-20m}"
REMOTE_DIR="${REMOTE_DIR:-/tmp/vk-turn-proxy-public-smoke}"
REMOTE_PACKAGE="/tmp/vk-turn-proxy-public-smoke.tar.gz"
REMOTE_LOG="/tmp/vk-turn-proxy-public-smoke.log"
REMOTE_PID="/tmp/vk-turn-proxy-public-smoke.pid"

usage() {
  cat >&2 <<EOF
Usage:
  ACTION=start  $0
  ACTION=status $0
  ACTION=logs   $0
  ACTION=stop   $0

Environment:
  HOST=$HOST
  SSH_USER=$SSH_USER
  PUBLIC_LISTEN=$PUBLIC_LISTEN
  PUBLIC_HEALTH=$PUBLIC_HEALTH
  CONNECT=$CONNECT
  SMOKE_TIMEOUT=$SMOKE_TIMEOUT

This starts a temporary public second-port server for client smoke testing.
It does not install or restart the production service on 56004.
EOF
}

ssh_root() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
}

remote_script() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" bash -s -- "$@"
}

build_package() {
  "$ROOT_DIR/scripts/package-server.sh" >/tmp/vkturn-public-smoke-package.out
  awk -F= '/^package=/{print $2}' /tmp/vkturn-public-smoke-package.out
}

start() {
  case "$PUBLIC_LISTEN" in
    *:56004)
      echo "Refusing to use production port 56004 for public smoke." >&2
      exit 64
      ;;
  esac

  local package
  package="$(build_package)"
  scp -q "$package" "$SSH_TARGET:$REMOTE_PACKAGE"
  remote_script "$REMOTE_PACKAGE" "$REMOTE_DIR" "$PUBLIC_LISTEN" "$PUBLIC_HEALTH" "$CONNECT" "$SMOKE_TIMEOUT" "$REMOTE_LOG" "$REMOTE_PID" <<'REMOTE'
set -euo pipefail
package="$1"
remote_dir="$2"
listen="$3"
health="$4"
connect="$5"
smoke_timeout="$6"
log="$7"
pidfile="$8"

if [[ -f "$pidfile" ]]; then
  old_pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$old_pid" ]] && kill -0 "$old_pid" >/dev/null 2>&1; then
    echo "Public smoke server already running: pid=$old_pid" >&2
    exit 1
  fi
fi

listen_port="${listen##*:}"
health_port="${health##*:}"
if ss -lunp | grep -q ":$listen_port "; then
  echo "UDP port already in use: $listen" >&2
  exit 1
fi
if ss -ltnp | grep -q ":$health_port "; then
  echo "TCP health port already in use: $health" >&2
  exit 1
fi

rm -rf "$remote_dir"
mkdir -p "$remote_dir"
tar -xzf "$package" -C "$remote_dir" --strip-components=1
chmod +x "$remote_dir/vk-turn-proxy-server"
rm -f "$log" "$pidfile"

nohup timeout "$smoke_timeout" "$remote_dir/vk-turn-proxy-server" \
  -listen "$listen" \
  -connect "$connect" \
  -srtp \
  -health-listen "$health" \
  -session-idle-timeout 30m >"$log" 2>&1 &
pid="$!"
echo "$pid" > "$pidfile"

for _ in $(seq 1 40); do
  if curl -fsS "http://$health/healthz" >/dev/null 2>&1; then
    echo "public_smoke_pid=$pid"
    curl -fsS "http://$health/healthz"
    curl -fsS "http://$health/readyz"
    exit 0
  fi
  if ! kill -0 "$pid" >/dev/null 2>&1; then
    cat "$log" >&2
    exit 1
  fi
  sleep 0.25
done

cat "$log" >&2
exit 1
REMOTE
}

status() {
  remote_script "$REMOTE_PID" "$PUBLIC_HEALTH" "$PUBLIC_LISTEN" <<'REMOTE'
set -euo pipefail
pidfile="$1"
health="$2"
listen="$3"
if [[ -f "$pidfile" ]]; then
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    echo "public_smoke_pid=$pid"
  else
    echo "public_smoke_pid=not-running"
  fi
else
  echo "public_smoke_pid=missing"
fi
curl -fsS "http://$health/healthz" 2>/dev/null || true
curl -fsS "http://$health/readyz" 2>/dev/null || true
ss -lunp | grep "${listen##*:}" || true
REMOTE
}

logs() {
  ssh_root "test -f '$REMOTE_LOG' && tail -120 '$REMOTE_LOG' || true"
}

stop() {
  remote_script "$REMOTE_PID" "$REMOTE_LOG" "$PUBLIC_LISTEN" "$PUBLIC_HEALTH" "$REMOTE_DIR" <<'REMOTE'
set -euo pipefail
pidfile="$1"
log="$2"
listen="$3"
health="$4"
remote_dir="$5"
listen_port="${listen##*:}"
health_port="${health##*:}"
kill_child_servers() {
  mapfile -t child_pids < <(pgrep -f "^$remote_dir/vk-turn-proxy-server " 2>/dev/null || true)
  for child_pid in "${child_pids[@]}"; do
    [[ -n "$child_pid" ]] || continue
    kill "$child_pid" >/dev/null 2>&1 || true
  done
}
if [[ -f "$pidfile" ]]; then
  pid="$(cat "$pidfile" 2>/dev/null || true)"
  if [[ -n "$pid" ]] && kill -0 "$pid" >/dev/null 2>&1; then
    kill "$pid" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
      kill -0 "$pid" >/dev/null 2>&1 || break
      sleep 0.25
    done
    kill -9 "$pid" >/dev/null 2>&1 || true
  fi
fi
kill_child_servers
for _ in $(seq 1 20); do
  if ! ss -lunp | grep -q ":$listen_port "; then
    break
  fi
  sleep 0.25
done
mapfile -t child_pids < <(pgrep -f "^$remote_dir/vk-turn-proxy-server " 2>/dev/null || true)
for child_pid in "${child_pids[@]}"; do
  [[ -n "$child_pid" ]] || continue
  kill -9 "$child_pid" >/dev/null 2>&1 || true
done
rm -f "$pidfile"
echo "stopped"
ss -lunp | grep ":$listen_port " || true
ss -ltnp | grep ":$health_port " || true
test -f "$log" && tail -40 "$log" || true
REMOTE
}

case "$ACTION" in
  start) start ;;
  status) status ;;
  logs) logs ;;
  stop) stop ;;
  -h|--help|help) usage ;;
  *) usage; exit 64 ;;
esac
