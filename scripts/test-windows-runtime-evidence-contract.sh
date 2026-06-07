#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${TAG:-v1.0-build158}"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-windows-runtime-evidence.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make_runtime_evidence() {
  local dir="$1"
  local strong="$2"
  mkdir -p "$dir"
  if [[ "$strong" == "1" ]]; then
    cat > "$dir/summary.json" <<'JSON'
{
  "ok": true,
  "result": "passed",
  "evidenceType": "windows_runtime_smoke",
  "keepRunning": false,
  "validateOk": true,
  "serviceInstalled": true,
  "wireguardAttachedObserved": true,
  "programDataStatusCaptured": true,
  "stopVerified": true
}
JSON
  else
    cat > "$dir/summary.json" <<'JSON'
{
  "ok": true,
  "result": "passed",
  "evidenceType": "windows_runtime_smoke"
}
JSON
  fi
  printf 'transcript\n' > "$dir/transcript.txt"
  printf 'validated\n' > "$dir/validate.txt"
  printf 'installed\n' > "$dir/install-service.txt"
  printf 'started\n' > "$dir/start-tunnel.txt"
  printf '{"ok":true,"status":{"state":"wireguard_attached"}}\n' > "$dir/status-running.json"
  printf '{"state":"wireguard_attached"}\n' > "$dir/programdata-status-running.json"
  printf 'stopped\n' > "$dir/stop-tunnel.txt"
  printf '{"ok":true,"status":{"state":"stopped"}}\n' > "$dir/status-stopped.json"
}

run_status() {
  local evidence="$1"
  local out_dir="$2"
  env \
    WINDOWS_RUNTIME_SMOKE_EVIDENCE="$evidence" \
    OUT_DIR="$out_dir" \
    RUN_GITHUB=0 \
    RUN_APPLE_SIGNING=0 \
    RUN_SERVER_BASELINE=0 \
    "$ROOT_DIR/scripts/release-blockers-status.sh" "$TAG" > "$out_dir.log"
}

valid="$TMP_DIR/valid"
make_runtime_evidence "$valid" 1
run_status "$valid" "$TMP_DIR/status-valid"
grep -q $'^windows\tready\truntime_smoke=' "$TMP_DIR/status-valid/status.tsv"

weak="$TMP_DIR/weak"
make_runtime_evidence "$weak" 0
run_status "$weak" "$TMP_DIR/status-weak"
grep -q $'^windows\tblocked\tWINDOWS_RUNTIME_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-weak/status.tsv"
if grep -q $'^windows\tready\truntime_smoke=' "$TMP_DIR/status-weak/status.tsv"; then
  echo "Weak Windows runtime evidence must not pass final contract." >&2
  exit 1
fi

printf 'windows runtime evidence contract ok\n'
