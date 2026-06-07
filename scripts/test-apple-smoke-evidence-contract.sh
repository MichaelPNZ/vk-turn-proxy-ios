#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-apple-smoke-evidence.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

make_apple_evidence() {
  local dir="$1"
  local evidence_type="$2"
  local mode="$3"
  local provided_count="$4"
  mkdir -p "$dir"
  cat > "$dir/summary.txt" <<EOF
result=passed
evidence_type=$evidence_type
completed_at=2026-06-06T00:00:00Z
host=ci-fixture
attachment_count=2
apple_smoke_mode=$mode
connected_cleanly=1
disconnected_cleanly=1
provided_file_count=$provided_count
notes_count=1
supporting_evidence_file_count=1
macos_system_log_collected=0
macos_appgroup_log_count=0
EOF
  printf '%s connected and disconnected cleanly\n' "$mode" > "$dir/exported-log.txt"
  printf 'operator note\n' > "$dir/notes.txt"
}

make_weak_evidence() {
  local dir="$1"
  local evidence_type="$2"
  mkdir -p "$dir"
  cat > "$dir/summary.txt" <<EOF
result=passed
evidence_type=$evidence_type
completed_at=2026-06-06T00:00:00Z
host=ci-fixture
attachment_count=1
EOF
  printf 'weak note only\n' > "$dir/notes.txt"
}

valid_iphone="$TMP_DIR/valid-iphone"
valid_macos="$TMP_DIR/valid-macos"
weak_iphone="$TMP_DIR/weak-iphone"
weak_macos="$TMP_DIR/weak-macos"
make_apple_evidence "$valid_iphone" iphone_testflight_network_extension iphone 1
make_apple_evidence "$valid_macos" macos_testflight_packet_tunnel macos 0
make_weak_evidence "$weak_iphone" iphone_testflight_network_extension
make_weak_evidence "$weak_macos" macos_testflight_packet_tunnel

OUT_DIR="$TMP_DIR/status-valid" \
RUN_GITHUB=0 \
RUN_APPLE_SIGNING=0 \
RUN_SERVER_BASELINE=0 \
    RUN_SERVER_STAGING=0 \
IPHONE_TESTFLIGHT_SMOKE_EVIDENCE="$valid_iphone" \
MACOS_TESTFLIGHT_SMOKE_EVIDENCE="$valid_macos" \
"$ROOT_DIR/scripts/release-blockers-status.sh" v1.0-build166 > "$TMP_DIR/valid.out"

grep -q $'^apple\tskipped\tRUN_APPLE_SIGNING=0$' "$TMP_DIR/status-valid/status.tsv"
grep -q $'^apple\tready\tiphone_testflight_smoke=' "$TMP_DIR/status-valid/status.tsv"
grep -q $'^apple\tready\tmacos_testflight_smoke=' "$TMP_DIR/status-valid/status.tsv"

OUT_DIR="$TMP_DIR/status-weak" \
RUN_GITHUB=0 \
RUN_APPLE_SIGNING=0 \
RUN_SERVER_BASELINE=0 \
    RUN_SERVER_STAGING=0 \
IPHONE_TESTFLIGHT_SMOKE_EVIDENCE="$weak_iphone" \
MACOS_TESTFLIGHT_SMOKE_EVIDENCE="$weak_macos" \
"$ROOT_DIR/scripts/release-blockers-status.sh" v1.0-build166 > "$TMP_DIR/weak.out"

grep -q $'^apple\tblocked\tIPHONE_TESTFLIGHT_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-weak/status.tsv"
grep -q $'^apple\tblocked\tMACOS_TESTFLIGHT_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-weak/status.tsv"
if grep -q $'^apple\tready\t.*testflight_smoke=' "$TMP_DIR/status-weak/status.tsv"; then
  echo "Weak Apple smoke evidence must not pass release status." >&2
  exit 1
fi

printf 'apple smoke evidence contract ok\n'
