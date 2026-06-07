#!/usr/bin/env bash
set -euo pipefail

EVIDENCE_TYPE="${1:-}"
EVIDENCE_DIR="${2:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/write-smoke-evidence-summary.sh <evidence-type> <evidence-dir>

Evidence types:
  iphone_testflight_network_extension
  macos_testflight_packet_tunnel
  windows_installer_smoke
  server_public_smoke
  server_production_baseline
  server_production_smoke

Put supporting logs, screenshots, status files, or command transcripts into the
evidence directory first. This script writes summary.txt for final readiness.
The directory must contain at least one supporting file besides summary.txt.
EOF
}

case "$EVIDENCE_TYPE" in
  iphone_testflight_network_extension|macos_testflight_packet_tunnel|windows_installer_smoke|server_public_smoke|server_production_baseline|server_production_smoke) ;;
  -h|--help|help|"") usage; exit 64 ;;
  *) echo "Unsupported evidence type: $EVIDENCE_TYPE" >&2; usage; exit 64 ;;
esac

if [[ -z "$EVIDENCE_DIR" ]]; then
  usage
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"

attachment_count="$(
  find "$EVIDENCE_DIR" -maxdepth 1 -type f ! -name summary.txt | wc -l | tr -d ' '
)"
if [[ "$attachment_count" -lt 1 ]]; then
  echo "Evidence directory must contain at least one supporting file besides summary.txt: $EVIDENCE_DIR" >&2
  exit 1
fi

cat > "$EVIDENCE_DIR/summary.txt" <<EOF
result=passed
evidence_type=$EVIDENCE_TYPE
completed_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
host=$(hostname)
attachment_count=$attachment_count
EOF

printf 'wrote %s\n' "$EVIDENCE_DIR/summary.txt"
printf 'attachment_count=%s\n' "$attachment_count"
