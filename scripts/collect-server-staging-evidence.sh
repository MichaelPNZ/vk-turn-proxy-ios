#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
SSH_TARGET="$SSH_USER@$HOST"
EVIDENCE_DIR="${1:-}"
EXPECTED_STAGED_BINARY_SHA256="${EXPECTED_STAGED_BINARY_SHA256:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/collect-server-staging-evidence.sh <evidence-dir>

Environment:
  HOST=142.252.220.91
  SSH_USER=root
  EXPECTED_STAGED_BINARY_SHA256=<sha256>  optional exact staged binary check

Read-only collector. It does not promote, rollback, restart, or edit production.
It verifies that install-staged placed the next binary/unit/logrotate files that
will be used by MODE=promote.
EOF
}

if [[ -z "$EVIDENCE_DIR" || "$EVIDENCE_DIR" == "-h" || "$EVIDENCE_DIR" == "--help" || "$EVIDENCE_DIR" == "help" ]]; then
  usage
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"
: > "$EVIDENCE_DIR/blockers.txt"

blocker() {
  printf '%s\n' "$*" >> "$EVIDENCE_DIR/blockers.txt"
}

ssh_readonly() {
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "$SSH_TARGET" "$@"
}

summary_value() {
  local file="$1"
  local key="$2"
  awk -F= -v key="$key" '$1 == key {value=$2} END {print value}' "$file" 2>/dev/null || true
}

{
  printf 'timestamp_utc=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'host=%s\n' "$HOST"
  printf 'ssh_user=%s\n' "$SSH_USER"
  printf 'expected_staged_binary_sha256=%s\n' "$EXPECTED_STAGED_BINARY_SHA256"
} > "$EVIDENCE_DIR/collector.txt"

ssh_readonly "test -x /usr/local/bin/vk-turn-proxy-server.next && echo present || echo missing" \
  > "$EVIDENCE_DIR/staged-binary-present.txt" 2>&1 || true
ssh_readonly "sha256sum /usr/local/bin/vk-turn-proxy-server.next 2>/dev/null || true" \
  > "$EVIDENCE_DIR/staged-binary-sha256.txt" 2>&1 || true
ssh_readonly "test -f /tmp/vk-turn-proxy-ios.service.next && echo present || echo missing" \
  > "$EVIDENCE_DIR/staged-unit-present.txt" 2>&1 || true
ssh_readonly "test -f /tmp/vk-turn-proxy-ios.logrotate.next && echo present || echo missing" \
  > "$EVIDENCE_DIR/staged-logrotate-present.txt" 2>&1 || true
ssh_readonly "test -f /etc/vk-turn-proxy-ios.env && echo present || echo missing" \
  > "$EVIDENCE_DIR/production-env-present.txt" 2>&1 || true
ssh_readonly "sed -n '1,120p' /tmp/vk-turn-proxy-ios.service.next 2>/dev/null || true" \
  > "$EVIDENCE_DIR/staged-unit.txt" 2>&1 || true
ssh_readonly "systemctl is-active vk-turn-proxy-ios.service" \
  > "$EVIDENCE_DIR/systemctl-is-active.txt" 2>&1 || true
ssh_readonly "ss -ltnup | grep -E ':(56004|56080) ' || true" \
  > "$EVIDENCE_DIR/listeners.txt" 2>&1 || true

binary_present="$(tr -d '\r' < "$EVIDENCE_DIR/staged-binary-present.txt" | head -1)"
unit_present="$(tr -d '\r' < "$EVIDENCE_DIR/staged-unit-present.txt" | head -1)"
logrotate_present="$(tr -d '\r' < "$EVIDENCE_DIR/staged-logrotate-present.txt" | head -1)"
env_present="$(tr -d '\r' < "$EVIDENCE_DIR/production-env-present.txt" | head -1)"
service_status="$(tr -d '\r' < "$EVIDENCE_DIR/systemctl-is-active.txt" | head -1)"
staged_sha="$(awk '{print $1; exit}' "$EVIDENCE_DIR/staged-binary-sha256.txt")"

if [[ "$binary_present" != "present" ]]; then
  blocker "Staged binary is missing or not executable: /usr/local/bin/vk-turn-proxy-server.next"
fi
if [[ -z "$staged_sha" || ! "$staged_sha" =~ ^[a-fA-F0-9]{64}$ ]]; then
  blocker "Staged binary sha256 is missing or invalid"
fi
if [[ -n "$EXPECTED_STAGED_BINARY_SHA256" && "$staged_sha" != "$EXPECTED_STAGED_BINARY_SHA256" ]]; then
  blocker "Staged binary sha256 does not match EXPECTED_STAGED_BINARY_SHA256"
fi
if [[ "$unit_present" != "present" ]]; then
  blocker "Staged systemd unit is missing: /tmp/vk-turn-proxy-ios.service.next"
fi
if [[ "$logrotate_present" != "present" ]]; then
  blocker "Staged logrotate file is missing: /tmp/vk-turn-proxy-ios.logrotate.next"
fi
if [[ "$env_present" != "present" ]]; then
  blocker "Production env file is missing: /etc/vk-turn-proxy-ios.env"
fi
if ! grep -q '^Environment=VKTURN_MAX_SESSIONS=1024$' "$EVIDENCE_DIR/staged-unit.txt"; then
  blocker "Staged systemd unit is missing VKTURN_MAX_SESSIONS fallback"
fi
if ! grep -q -- '-max-sessions ${VKTURN_MAX_SESSIONS}' "$EVIDENCE_DIR/staged-unit.txt"; then
  blocker "Staged systemd unit does not pass VKTURN_MAX_SESSIONS"
fi
if [[ "$service_status" != "active" ]]; then
  blocker "Current production service is not active before promote"
fi
if ! grep -q ':56004' "$EVIDENCE_DIR/listeners.txt"; then
  blocker "Current production listener :56004 is missing before promote"
fi

blocker_count="$(grep -cve '^[[:space:]]*$' "$EVIDENCE_DIR/blockers.txt" || true)"
if [[ "$blocker_count" -eq 0 ]]; then
  result="passed"
else
  result="blocked"
fi

cat > "$EVIDENCE_DIR/summary.txt" <<EOF
result=$result
evidence_type=server_staging_readiness
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
host=$HOST
binary_present=$binary_present
staged_binary_sha256=$staged_sha
unit_present=$unit_present
logrotate_present=$logrotate_present
production_env_present=$env_present
production_service=$service_status
production_listener_56004=$(if grep -q ':56004' "$EVIDENCE_DIR/listeners.txt"; then echo present; else echo missing; fi)
blocker_count=$blocker_count
EOF

printf 'wrote %s\n' "$EVIDENCE_DIR/summary.txt"
printf 'result=%s\n' "$result"
printf 'blocker_count=%s\n' "$blocker_count"
printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"

if [[ "$result" != "passed" ]]; then
  exit 1
fi
