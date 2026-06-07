#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-android-profile-peer-override.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

decode_peer() {
  local link_file="$1"
  python3 - "$link_file" <<'PY'
import base64
import json
import sys
import urllib.parse

link = open(sys.argv[1], encoding="utf-8").read().strip()
query = urllib.parse.parse_qs(urllib.parse.urlparse(link).query)
payload = query["data"][0]
payload += "=" * ((4 - len(payload) % 4) % 4)
raw = base64.urlsafe_b64decode(payload.encode()).decode()
data = json.loads(raw)
print(data["settings"]["peerAddress"])
PY
}

profile_json="$TMP_DIR/connection.json"
cat > "$profile_json" <<'JSON'
{
  "version": 1,
  "type": "connection",
  "settings": {
    "privateKey": "private",
    "peerPublicKey": "peer",
    "presharedKey": "psk",
    "tunnelAddress": "10.7.0.2/32",
    "dnsServers": "1.1.1.1",
    "allowedIPs": "0.0.0.0/0",
    "vkLink": "https://vk.com/",
    "peerAddress": "142.252.220.91:56004",
    "useDTLS": true,
    "useSrtp": true,
    "useUDP": false,
    "useWrapA": false,
    "wrapAPassword": "",
    "numConnections": 10
  }
}
JSON

json_evidence="$TMP_DIR/json-evidence"
PEER_ADDRESS=142.252.220.91:56014 \
  PROFILE_FILE="$profile_json" \
  PREPARE_IMPORT_ONLY=1 \
  BUILD_RELEASE=0 \
  UNSAFE_WRITE_IMPORT_LINK=1 \
  EVIDENCE_DIR="$json_evidence" \
  "$ROOT_DIR/scripts/smoke-android-release-imported-profile.sh" >/dev/null
[[ "$(decode_peer "$json_evidence/import-link.txt")" == "142.252.220.91:56014" ]]

import_payload="$(
  python3 - "$profile_json" <<'PY'
import base64
import json
import sys
raw = json.dumps(json.load(open(sys.argv[1], encoding="utf-8")), separators=(",", ":")).encode()
print(base64.urlsafe_b64encode(raw).decode().rstrip("="))
PY
)"
import_link="vkturnproxy://import?data=$import_payload"
import_evidence="$TMP_DIR/import-evidence"
PEER_ADDRESS=142.252.220.91:56015 \
  IMPORT_LINK="$import_link" \
  PREPARE_IMPORT_ONLY=1 \
  BUILD_RELEASE=0 \
  UNSAFE_WRITE_IMPORT_LINK=1 \
  EVIDENCE_DIR="$import_evidence" \
  "$ROOT_DIR/scripts/smoke-android-release-imported-profile.sh" >/dev/null
[[ "$(decode_peer "$import_evidence/import-link.txt")" == "142.252.220.91:56015" ]]

printf 'android profile peer override ok\n'
