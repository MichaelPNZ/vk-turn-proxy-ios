#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-server-production-evidence.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

make_valid_evidence() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/summary.txt" <<'EOF'
result=passed
evidence_type=server_production_smoke
completed_at=2026-06-06T00:00:00Z
host=ci-fixture
attachment_count=9
service=active
listener_56004=present
listener_56080=present
healthz=ok
readyz=ready
metrics=present
production_client_smoke_log=present
EOF
  printf 'active\n' > "$dir/systemctl-is-active.txt"
  cat > "$dir/listeners.txt" <<'EOF'
UNCONN 0 0 *:56004 *:* users:(("vk-turn-proxy-s",pid=1,fd=7))
LISTEN 0 128 127.0.0.1:56080 0.0.0.0:* users:(("vk-turn-proxy-s",pid=1,fd=8))
EOF
  printf 'ok\n' > "$dir/healthz.txt"
  printf 'ready\n' > "$dir/readyz.txt"
  printf 'vk_turn_proxy_active_sessions 0\n' > "$dir/metrics-head.txt"
  printf 'sha fixture /usr/local/bin/vk-turn-proxy-server\n' > "$dir/production-sha256.txt"
  cat > "$dir/server-status.txt" <<'EOF'
service=active
listener_56004=present
listener_56080=present
healthz=ok
readyz=ready
metrics=present
EOF
  printf 'server listening fixture\n' > "$dir/server-log-tail.txt"
  printf 'production client connected and disconnected cleanly\n' > "$dir/client-smoke.log"
}

make_weak_evidence() {
  local dir="$1"
  mkdir -p "$dir"
  cat > "$dir/summary.txt" <<'EOF'
result=passed
evidence_type=server_production_smoke
completed_at=2026-06-06T00:00:00Z
host=ci-fixture
attachment_count=1
EOF
  printf 'some log\n' > "$dir/client-smoke.log"
}

valid="$TMP_DIR/valid"
weak="$TMP_DIR/weak"
make_valid_evidence "$valid"
make_weak_evidence "$weak"

OUT_DIR="$TMP_DIR/status-valid" \
RUN_GITHUB=0 \
RUN_APPLE_SIGNING=0 \
RUN_SERVER_BASELINE=0 \
    RUN_SERVER_STAGING=0 \
SERVER_PRODUCTION_SMOKE_EVIDENCE="$valid" \
"$ROOT_DIR/scripts/release-blockers-status.sh" v1.0-build163 > "$TMP_DIR/valid.out"

grep -q $'^server\tready\tproduction_smoke=' "$TMP_DIR/status-valid/status.tsv"

OUT_DIR="$TMP_DIR/status-weak" \
RUN_GITHUB=0 \
RUN_APPLE_SIGNING=0 \
RUN_SERVER_BASELINE=0 \
    RUN_SERVER_STAGING=0 \
SERVER_PRODUCTION_SMOKE_EVIDENCE="$weak" \
"$ROOT_DIR/scripts/release-blockers-status.sh" v1.0-build163 > "$TMP_DIR/weak.out"

grep -q $'^server\tblocked\tSERVER_PRODUCTION_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-weak/status.tsv"
if grep -q $'^server\tready\tproduction_smoke=' "$TMP_DIR/status-weak/status.tsv"; then
  echo "Weak server production evidence must not pass release status." >&2
  exit 1
fi

printf 'server production evidence contract ok\n'
