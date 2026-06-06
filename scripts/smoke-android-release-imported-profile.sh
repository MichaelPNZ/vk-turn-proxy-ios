#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
ADB="${ADB:-"$ANDROID_HOME/platform-tools/adb"}"
SERIAL="${SERIAL:-}"
PREF="${PREF:-"$HOME/Library/Containers/com.vkturnproxy.app/Data/Library/Preferences/com.vkturnproxy.app.plist"}"
PROFILE_FILE="${PROFILE_FILE:-}"
IMPORT_LINK="${IMPORT_LINK:-}"
PACKAGE="com.vkturnproxy.android"
APK="$ROOT_DIR/androidApp/build/outputs/apk/release/androidApp-release.apk"
PEER_ADDRESS="${PEER_ADDRESS:-}"
ALLOWED_IPS="${ALLOWED_IPS:-0.0.0.0/0}"
NUM_CONNECTIONS="${NUM_CONNECTIONS:-10}"
BUILD_RELEASE="${BUILD_RELEASE:-1}"
PREPARE_IMPORT_ONLY="${PREPARE_IMPORT_ONLY:-0}"
EVIDENCE_DIR="${EVIDENCE_DIR:-}"
REQUIRE_PHYSICAL_DEVICE="${REQUIRE_PHYSICAL_DEVICE:-0}"
source_label=""

timestamp() {
  date -u +"%Y-%m-%dT%H-%M-%SZ"
}

ensure_evidence_dir() {
  if [[ -z "$EVIDENCE_DIR" ]]; then
    EVIDENCE_DIR="$ROOT_DIR/build/android-release-smoke/$(timestamp)"
  fi
  mkdir -p "$EVIDENCE_DIR"
}

write_summary() {
  local result="$1"
  local reason="${2:-}"
  ensure_evidence_dir
  {
    printf 'result=%s\n' "$result"
    printf 'reason=%s\n' "$reason"
    printf 'timestamp=%s\n' "$(timestamp)"
    printf 'package=%s\n' "$PACKAGE"
    printf 'serial=%s\n' "${SERIAL:-default}"
    printf 'source=%s\n' "$source_label"
    printf 'profile_file_set=%s\n' "$([[ -n "$PROFILE_FILE" ]] && echo true || echo false)"
    printf 'import_link_set=%s\n' "$([[ -n "$IMPORT_LINK" ]] && echo true || echo false)"
    printf 'require_physical_device=%s\n' "$REQUIRE_PHYSICAL_DEVICE"
    printf 'link_bytes=%d\n' "${#link}"
    if [[ -f "$APK" ]]; then
      printf 'apk=%s\n' "$APK"
      printf 'apk_sha256=%s\n' "$(shasum -a 256 "$APK" | awk '{print $1}')"
    fi
  } > "$EVIDENCE_DIR/summary.txt"
}

save_ui_dump() {
  local name="$1"
  ensure_evidence_dir
  dump_ui > "$EVIDENCE_DIR/$name" 2>/dev/null || true
}

save_connectivity() {
  local name="$1"
  ensure_evidence_dir
  adb_cmd shell dumpsys connectivity > "$EVIDENCE_DIR/$name" 2>/dev/null || true
}

save_filtered_logcat() {
  local name="$1"
  ensure_evidence_dir
  adb_cmd logcat -d 2>/dev/null \
    | grep -Ei "AndroidVpn|mobilebridge|SRTP\\+TURN|IpcSet|CreateTUN|FATAL EXCEPTION|permission denied|VpnService|Go bridge|WireGuard|VKTurnProxy|NetworkAgent|ConnectivityService" \
    > "$EVIDENCE_DIR/$name" || true
}

save_package_info() {
  ensure_evidence_dir
  adb_cmd shell dumpsys package "$PACKAGE" > "$EVIDENCE_DIR/package.txt" 2>/dev/null || true
}

fail_smoke() {
  local message="$1"
  save_ui_dump "failure-ui.xml"
  save_connectivity "failure-connectivity.txt"
  save_filtered_logcat "failure-logcat-filtered.txt"
  save_package_info
  write_summary "failed" "$message"
  printf '%s\n' "$message" >&2
  printf 'evidence_dir=%s\n' "$EVIDENCE_DIR" >&2
  exit 1
}

read_key() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PREF"
}

bool_key() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PREF" | awk '{print tolower($0)}'
}

require_tool() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing tool: $1" >&2
    exit 1
  fi
}

adb_cmd() {
  if [[ -n "$SERIAL" ]]; then
    "$ADB" -s "$SERIAL" "$@"
  else
    "$ADB" "$@"
  fi
}

dump_ui() {
  adb_cmd exec-out uiautomator dump /dev/tty
}

tap_text() {
  local text="$1"
  local xml
  xml="$(dump_ui)"
  UI_XML="$xml" python3 -c '
import re
import sys
import xml.etree.ElementTree as ET
import os

target = sys.argv[1]
raw = os.environ["UI_XML"]
start = raw.find("<hierarchy")
end = raw.rfind("</hierarchy>")
if start < 0 or end < 0:
    sys.exit(1)
end += len("</hierarchy>")
root = ET.fromstring(raw[start:end])
for node in root.iter("node"):
    text = node.attrib.get("text", "")
    desc = node.attrib.get("content-desc", "")
    if target not in (text, desc):
        continue
    bounds = node.attrib.get("bounds", "")
    match = re.match(r"\[(\d+),(\d+)\]\[(\d+),(\d+)\]", bounds)
    if not match:
        continue
    x1, y1, x2, y2 = map(int, match.groups())
    print((x1 + x2) // 2, (y1 + y2) // 2)
    sys.exit(0)
sys.exit(1)
' "$text"
}

tap_first_available() {
  local target coords
  for target in "$@"; do
    if coords="$(tap_text "$target" 2>/dev/null)"; then
      adb_cmd shell input tap $coords
      return 0
    fi
  done
  return 1
}

base64url() {
  base64 | tr '+/' '-_' | tr -d '=\n'
}

build_link_from_raw_payload() {
  local raw="$1"
  local payload
  payload="$(printf '%s' "$raw" | base64url)"
  printf 'vkturnproxy://import?data=%s\n' "$payload"
}

build_link_from_profile_file() {
  test -f "$PROFILE_FILE" || {
    echo "PROFILE_FILE does not exist: $PROFILE_FILE" >&2
    exit 1
  }
  local raw
  raw="$(cat "$PROFILE_FILE")"
  if [[ "$raw" == vkturnproxy://import* ]]; then
    printf '%s\n' "$raw"
  else
    build_link_from_raw_payload "$raw"
  fi
}

build_link_from_ios_preferences() {
  require_tool jq
  test -f "$PREF" || {
    echo "iOS preferences plist not found at $PREF" >&2
    echo "Set PROFILE_FILE to a full backup/connection JSON file or IMPORT_LINK to a vkturnproxy://import link." >&2
    exit 1
  }

  if [[ -z "$PEER_ADDRESS" ]]; then
    PEER_ADDRESS="$(read_key peerAddress)"
  fi

  local json
  json="$(jq -nc \
    --arg privateKey "$(read_key privateKey)" \
    --arg peerPublicKey "$(read_key peerPublicKey)" \
    --arg presharedKey "$(read_key presharedKey)" \
    --arg tunnelAddress "$(read_key tunnelAddress)" \
    --arg dnsServers "$(read_key dnsServers)" \
    --arg vkLink "$(read_key vkLink)" \
    --arg peerAddress "$PEER_ADDRESS" \
    --arg allowedIPs "$ALLOWED_IPS" \
    --arg wrapAPassword "$(read_key wrapAPassword)" \
    --argjson numConnections "$NUM_CONNECTIONS" \
    --argjson useSrtp "$(bool_key useSrtp)" \
    --argjson useUDP "$(bool_key useUDP)" \
    --argjson useWrapA "$(bool_key useWrapA)" \
    '{
      version: 1,
      type: "connection",
      settings: {
        privateKey: $privateKey,
        peerPublicKey: $peerPublicKey,
        presharedKey: $presharedKey,
        tunnelAddress: $tunnelAddress,
        dnsServers: $dnsServers,
        allowedIPs: $allowedIPs,
        vkLink: $vkLink,
        peerAddress: $peerAddress,
        useDTLS: true,
        useSrtp: $useSrtp,
        useUDP: $useUDP,
        useWrapA: $useWrapA,
        wrapAPassword: $wrapAPassword,
        numConnections: $numConnections
      }
    }')"
  build_link_from_raw_payload "$json"
}

build_import_link() {
  if [[ -n "$IMPORT_LINK" ]]; then
    if [[ "$IMPORT_LINK" != vkturnproxy://import* ]]; then
      echo "IMPORT_LINK must start with vkturnproxy://import" >&2
      exit 64
    fi
    printf '%s\n' "$IMPORT_LINK"
  elif [[ -n "$PROFILE_FILE" ]]; then
    build_link_from_profile_file
  else
    build_link_from_ios_preferences
  fi
}

test -x "$ADB" || {
  echo "adb not found at $ADB" >&2
  exit 1
}
link="$(build_import_link)"
if [[ -n "$IMPORT_LINK" ]]; then
  source_label="IMPORT_LINK"
elif [[ -n "$PROFILE_FILE" ]]; then
  source_label="PROFILE_FILE"
else
  source_label="PREF"
fi

if [[ "$PREPARE_IMPORT_ONLY" == "1" ]]; then
  write_summary "prepared" "import link prepared without device install/start"
  printf 'Android release imported-profile smoke prepared import link.\n'
  printf 'source=%s\n' "$source_label"
  printf 'link_bytes=%d\n' "${#link}"
  printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"
  exit 0
fi

if [[ "$BUILD_RELEASE" == "1" ]]; then
  ANDROID_HOME="$ANDROID_HOME" "$ROOT_DIR/gradlew" -p "$ROOT_DIR" :androidApp:assembleRelease >/dev/null
fi
test -f "$APK" || {
  echo "release APK not found: $APK" >&2
  exit 1
}

adb_cmd wait-for-device >/dev/null
ensure_evidence_dir
adb_cmd get-state > "$EVIDENCE_DIR/adb-state.txt" 2>/dev/null || true
adb_cmd shell getprop ro.product.model > "$EVIDENCE_DIR/device-model.txt" 2>/dev/null || true
adb_cmd shell getprop ro.build.version.release > "$EVIDENCE_DIR/device-android-version.txt" 2>/dev/null || true
adb_cmd shell getprop ro.kernel.qemu > "$EVIDENCE_DIR/device-qemu.txt" 2>/dev/null || true
if [[ "$REQUIRE_PHYSICAL_DEVICE" == "1" ]] && grep -q '^1' "$EVIDENCE_DIR/device-qemu.txt"; then
  fail_smoke "Android release imported-profile smoke failed: physical device required, but connected device is an emulator."
fi

adb_cmd uninstall "$PACKAGE" >/dev/null 2>&1 || true
adb_cmd install "$APK" >/dev/null
save_package_info
adb_cmd logcat -c
adb_cmd shell am start -a android.intent.action.VIEW -d "$link" -p "$PACKAGE" >/dev/null

deadline=$((SECONDS + 30))
valid=0
while (( SECONDS < deadline )); do
  if dump_ui | grep -q "Profile payload is valid"; then
    valid=1
    break
  fi
  sleep 1
done
if [[ "$valid" != 1 ]]; then
  fail_smoke "Android release imported-profile smoke failed: import validation did not appear."
fi
save_ui_dump "import-valid-ui.xml"

tap_first_available "Start VPN" || {
  fail_smoke "Android release imported-profile smoke failed: Start VPN button not found."
}
sleep 1
tap_first_available "OK" "ОК" "Allow" "Разрешить" "ALLOW" >/dev/null 2>&1 || true

deadline=$((SECONDS + 120))
attached=0
while (( SECONDS < deadline )); do
  if adb_cmd logcat -d | grep -q "mobilebridge: WireGuard attached"; then
    attached=1
    break
  fi
  sleep 2
done

if [[ "$attached" != 1 ]]; then
  save_filtered_logcat "failure-logcat-filtered.txt"
  tail -120 "$EVIDENCE_DIR/failure-logcat-filtered.txt" >&2 || true
  fail_smoke "Android release imported-profile smoke failed: WireGuard attach not observed."
fi

if adb_cmd logcat -d | grep -Eqi "FATAL EXCEPTION|WireGuard attach failed|CreateTUNFromFile failed|IpcSet failed"; then
  adb_cmd logcat -d | grep -Ei "FATAL EXCEPTION|WireGuard attach failed|CreateTUNFromFile failed|IpcSet failed" > "$EVIDENCE_DIR/error-markers.txt" || true
  tail -80 "$EVIDENCE_DIR/error-markers.txt" >&2 || true
  fail_smoke "Android release imported-profile smoke failed: error marker found in logcat."
fi

if ! adb_cmd shell dumpsys connectivity | grep -q "VPN:$PACKAGE"; then
  save_connectivity "missing-vpn-connectivity.txt"
  fail_smoke "Android release imported-profile smoke failed: VPN network not found in connectivity dump."
fi
save_connectivity "running-connectivity.txt"
save_filtered_logcat "running-logcat-filtered.txt"
save_ui_dump "running-ui.xml"

tap_first_available "Stop" || true
sleep 2

if adb_cmd shell dumpsys connectivity | grep -q "VPN:$PACKAGE"; then
  save_connectivity "stop-failure-connectivity.txt"
  fail_smoke "Android release imported-profile smoke failed: VPN network still present after stop."
fi
save_connectivity "stopped-connectivity.txt"
save_filtered_logcat "final-logcat-filtered.txt"
save_ui_dump "stopped-ui.xml"
write_summary "passed" "WireGuard attached, VPN network observed, stop cleaned up VPN network"

echo "Android release imported-profile smoke passed."
printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"
