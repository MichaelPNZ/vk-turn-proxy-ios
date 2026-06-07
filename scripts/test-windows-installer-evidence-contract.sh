#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${TAG:-v1.0-build164}"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-windows-installer-evidence.XXXXXX")"
INSTALLER_SHA256="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make_installer_evidence() {
  local dir="$1"
  local strong="$2"
  mkdir -p "$dir"
  {
    printf 'result=passed\n'
    printf 'evidence_type=windows_installer_smoke\n'
    printf 'completed_at=2026-06-07T00:00:00Z\n'
    printf 'host=windows-ci-smoke\n'
    printf 'attachment_count=6\n'
    if [[ "$strong" == "1" ]]; then
      printf 'installer_built=1\n'
      printf 'signature_verified=1\n'
      printf 'installed_cleanly=1\n'
      printf 'launched_cleanly=1\n'
      printf 'uninstalled_cleanly=1\n'
      printf 'installer_sha256=%s\n' "$INSTALLER_SHA256"
    fi
  } > "$dir/summary.txt"
  printf 'package-windows-installer.ps1 completed\n' > "$dir/installer-build-transcript.txt"
  printf 'Status: Valid\n' > "$dir/authenticode-signature.txt"
  printf '%s  vk-turn-proxy-windows-1.0.156-setup.exe\n' "$INSTALLER_SHA256" > "$dir/installer-sha256.txt"
  printf 'installer completed with exit code 0\n' > "$dir/install-transcript.txt"
  printf 'shortcut launched and service status checked\n' > "$dir/launch-or-service-smoke.txt"
  printf 'uninstaller completed with exit code 0\n' > "$dir/uninstall-transcript.txt"
}

run_status() {
  local evidence="$1"
  local out_dir="$2"
  env \
    WINDOWS_INSTALLER_SMOKE_EVIDENCE="$evidence" \
    OUT_DIR="$out_dir" \
    RUN_GITHUB=0 \
    RUN_APPLE_SIGNING=0 \
    RUN_SERVER_BASELINE=0 \
    RUN_SERVER_STAGING=0 \
    "$ROOT_DIR/scripts/release-blockers-status.sh" "$TAG" > "$out_dir.log"
}

valid="$TMP_DIR/valid"
make_installer_evidence "$valid" 1
run_status "$valid" "$TMP_DIR/status-valid"
grep -q $'^windows\tready\tinstaller_smoke=' "$TMP_DIR/status-valid/status.tsv"

weak="$TMP_DIR/weak"
make_installer_evidence "$weak" 0
run_status "$weak" "$TMP_DIR/status-weak"
grep -q $'^windows\tblocked\tWINDOWS_INSTALLER_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-weak/status.tsv"
if grep -q $'^windows\tready\tinstaller_smoke=' "$TMP_DIR/status-weak/status.tsv"; then
  echo "Weak Windows installer evidence must not pass final contract." >&2
  exit 1
fi

printf 'windows installer evidence contract ok\n'
