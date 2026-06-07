#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${TAG:-v1.0-build159}"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-android-physical-evidence.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

make_fake_adb() {
  local android_home="$TMP_DIR/android-home"
  mkdir -p "$android_home/platform-tools"
  cat > "$android_home/platform-tools/adb" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == "devices" ]]; then
  printf 'List of devices attached\n'
  printf 'SER123\tdevice usb:1-1 product:pixel model:Pixel_8 device:shiba transport_id:1\n'
  exit 0
fi
exit 0
EOF
  chmod +x "$android_home/platform-tools/adb"
  printf '%s\n' "$android_home"
}

make_evidence() {
  local dir="$1"
  local evidence_type="$2"
  local require_physical="$3"
  local qemu="$4"
  mkdir -p "$dir"
  {
    printf 'result=passed\n'
    printf 'evidence_type=%s\n' "$evidence_type"
    printf 'attachment_count=4\n'
    printf 'require_physical_device=%s\n' "$require_physical"
    printf 'device_qemu=%s\n' "$qemu"
    printf 'wireguard_attached_observed=1\n'
    printf 'vpn_network_observed=1\n'
    printf 'vpn_stop_cleaned=1\n'
  } > "$dir/summary.txt"
  printf '%s\n' "$qemu" > "$dir/device-qemu.txt"
  printf 'VPN:com.vkturnproxy.android running\n' > "$dir/running-connectivity.txt"
  printf 'stopped\n' > "$dir/stopped-connectivity.txt"
  printf 'mobilebridge: WireGuard attached\n' > "$dir/final-logcat-filtered.txt"
}

run_status() {
  local evidence="$1"
  local out_dir="$2"
  env \
    ANDROID_HOME="$ANDROID_HOME_FIXTURE" \
    ANDROID_PHYSICAL_SMOKE_EVIDENCE="$evidence" \
    OUT_DIR="$out_dir" \
    RUN_GITHUB=0 \
    RUN_APPLE_SIGNING=0 \
    RUN_SERVER_BASELINE=0 \
    "$ROOT_DIR/scripts/release-blockers-status.sh" "$TAG" > "$out_dir.log"
}

ANDROID_HOME_FIXTURE="$(make_fake_adb)"

valid="$TMP_DIR/valid"
make_evidence "$valid" android_physical_smoke 1 0
run_status "$valid" "$TMP_DIR/status-valid"
grep -q $'^android\tready\tphysical_smoke_evidence=' "$TMP_DIR/status-valid/status.tsv"

emulator="$TMP_DIR/emulator"
make_evidence "$emulator" android_release_smoke 1 1
run_status "$emulator" "$TMP_DIR/status-emulator"
grep -q $'^android\tblocked\tANDROID_PHYSICAL_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-emulator/status.tsv"
if grep -q $'^android\tready\tphysical_smoke_evidence=' "$TMP_DIR/status-emulator/status.tsv"; then
  echo "Emulator evidence must not pass Android physical smoke contract." >&2
  exit 1
fi

weak="$TMP_DIR/weak"
make_evidence "$weak" android_physical_smoke 1 0
printf 'running without vpn marker\n' > "$weak/running-connectivity.txt"
run_status "$weak" "$TMP_DIR/status-weak"
grep -q $'^android\tblocked\tANDROID_PHYSICAL_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-weak/status.tsv"
if grep -q $'^android\tready\tphysical_smoke_evidence=' "$TMP_DIR/status-weak/status.tsv"; then
  echo "Android physical smoke evidence without VPN connectivity marker must not pass." >&2
  exit 1
fi

dirty_stop="$TMP_DIR/dirty-stop"
make_evidence "$dirty_stop" android_physical_smoke 1 0
printf 'VPN:com.vkturnproxy.android still present\n' > "$dirty_stop/stopped-connectivity.txt"
run_status "$dirty_stop" "$TMP_DIR/status-dirty-stop"
grep -q $'^android\tblocked\tANDROID_PHYSICAL_SMOKE_EVIDENCE_missing_or_contract_failed$' "$TMP_DIR/status-dirty-stop/status.tsv"
if grep -q $'^android\tready\tphysical_smoke_evidence=' "$TMP_DIR/status-dirty-stop/status.tsv"; then
  echo "Android physical smoke evidence with VPN still present after stop must not pass." >&2
  exit 1
fi

printf 'android physical evidence contract ok\n'
