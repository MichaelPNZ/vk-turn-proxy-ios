#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
ADB="${ADB:-"$ANDROID_HOME/platform-tools/adb"}"
PREF="${PREF:-"$HOME/Library/Containers/com.vkturnproxy.app/Data/Library/Preferences/com.vkturnproxy.app.plist"}"
PACKAGE="com.vkturnproxy.android"
IMPORT_EXTRA="com.vkturnproxy.android.debug.IMPORT_TEXT"
PEER_ADDRESS="${PEER_ADDRESS:-}"
ALLOWED_IPS="${ALLOWED_IPS:-0.0.0.0/0}"
NUM_CONNECTIONS="${NUM_CONNECTIONS:-10}"

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

require_tool jq
test -x "$ADB" || {
  echo "adb not found at $ADB" >&2
  exit 1
}
test -f "$PREF" || {
  echo "iOS preferences plist not found at $PREF" >&2
  exit 1
}
if [[ -z "$PEER_ADDRESS" ]]; then
  PEER_ADDRESS="$(read_key peerAddress)"
fi

"$ADB" wait-for-device >/dev/null

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
payload="$(printf '%s' "$json" | base64 | tr '+/' '-_' | tr -d '=\n')"
link="vkturnproxy://import?data=$payload"

"$ADB" install -r "$ROOT_DIR/androidApp/build/outputs/apk/debug/androidApp-debug.apk" >/dev/null
"$ADB" logcat -c
"$ADB" shell am start -n "$PACKAGE/.MainActivity" >/dev/null
"$ADB" shell am start -n "$PACKAGE/.SmokeStartActivity" --es "$IMPORT_EXTRA" "$link" >/dev/null

deadline=$((SECONDS + 90))
attached=0
while (( SECONDS < deadline )); do
  if "$ADB" logcat -d | grep -q "mobilebridge: WireGuard attached"; then
    attached=1
    break
  fi
  sleep 2
done

if [[ "$attached" != 1 ]]; then
  "$ADB" logcat -d | grep -Ei "mobilebridge|SRTP\\+TURN|IpcSet|CreateTUN|FATAL EXCEPTION|permission denied" | tail -80 >&2 || true
  echo "Android imported-profile smoke failed: WireGuard attach not observed." >&2
  exit 1
fi

if "$ADB" logcat -d | grep -Eqi "FATAL EXCEPTION|WireGuard attach failed|CreateTUNFromFile failed|IpcSet failed"; then
  "$ADB" logcat -d | grep -Ei "FATAL EXCEPTION|WireGuard attach failed|CreateTUNFromFile failed|IpcSet failed" | tail -80 >&2
  echo "Android imported-profile smoke failed: error marker found in logcat." >&2
  exit 1
fi

if ! "$ADB" shell dumpsys connectivity | grep -q "VPN:com.vkturnproxy.android"; then
  echo "Android imported-profile smoke failed: VPN network not found in connectivity dump." >&2
  exit 1
fi

"$ADB" shell am start -n "$PACKAGE/.SmokeStartActivity" -a "$PACKAGE.debug.STOP" >/dev/null
sleep 2

if "$ADB" shell dumpsys connectivity | grep -q "VPN:com.vkturnproxy.android"; then
  echo "Android imported-profile smoke warning: VPN network still present after stop." >&2
  exit 1
fi

echo "Android imported-profile smoke passed."
