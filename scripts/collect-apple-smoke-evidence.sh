#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-}"
EVIDENCE_DIR="${2:-}"
shift $(( $# >= 2 ? 2 : $# ))

LAST="${LAST:-30m}"
FILES=()
NOTES=()
CONNECTED_CLEANLY=0
DISCONNECTED_CLEANLY=0
MACOS_SYSTEM_LOG_COLLECTED=0
MACOS_APPGROUP_LOG_COUNT=0

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/collect-apple-smoke-evidence.sh iphone <evidence-dir> --file <path> --connected-cleanly --disconnected-cleanly [--note <text>]
  scripts/collect-apple-smoke-evidence.sh macos <evidence-dir> --connected-cleanly --disconnected-cleanly [--file <path>] [--note <text>] [--last <duration>]

Modes:
  iphone  Collect supporting files exported from a real iPhone TestFlight /
          Network Extension smoke. At least one --file is required.
  macos   Collect local macOS system logs for VK Turn Proxy and App Group
          vpn.log/vpn.log.1 when present; --file can add screenshots or
          exported app logs.

The script writes a final-readiness summary with the required evidence_type.
EOF
}

safe_name() {
  local path="$1"
  basename "$path" | tr -c 'A-Za-z0-9._-' '_'
}

copy_supporting_file() {
  local source="$1"
  local label="${2:-}"
  if [[ ! -f "$source" ]]; then
    echo "Supporting file does not exist: $source" >&2
    exit 1
  fi
  local name
  name="$(safe_name "$source")"
  if [[ -n "$label" ]]; then
    name="$(safe_name "$label")-$name"
  fi
  cp "$source" "$EVIDENCE_DIR/$name"
}

write_notes() {
  if (( ${#NOTES[@]} == 0 )); then
    return
  fi
  {
    for note in "${NOTES[@]}"; do
      printf '%s\n' "$note"
    done
  } > "$EVIDENCE_DIR/notes.txt"
}

collect_macos_logs() {
  local system_log="$EVIDENCE_DIR/macos-system-log.txt"
  if command -v log >/dev/null 2>&1; then
    log show \
      --style syslog \
      --last "$LAST" \
      --predicate 'subsystem == "com.vkturnproxy.tunnel" OR subsystem == "com.vkturnproxy.app"' \
      > "$system_log" 2>"$EVIDENCE_DIR/macos-system-log.stderr" || true
    if [[ ! -s "$system_log" ]]; then
      rm -f "$system_log"
    else
      MACOS_SYSTEM_LOG_COLLECTED=1
    fi
    if [[ ! -s "$EVIDENCE_DIR/macos-system-log.stderr" ]]; then
      rm -f "$EVIDENCE_DIR/macos-system-log.stderr"
    fi
  fi

  local group_dir="$HOME/Library/Group Containers/group.com.vkturnproxy.app"
  for log_file in "$group_dir/vpn.log" "$group_dir/vpn.log.1"; do
    if [[ -f "$log_file" ]]; then
      copy_supporting_file "$log_file" "appgroup"
      MACOS_APPGROUP_LOG_COUNT=$((MACOS_APPGROUP_LOG_COUNT + 1))
    fi
  done
}

supporting_evidence_file_count() {
  find "$EVIDENCE_DIR" -maxdepth 1 -type f ! -name summary.txt ! -name notes.txt | wc -l | tr -d ' '
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --file)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      FILES+=("$2")
      shift 2
      ;;
    --note)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      NOTES+=("$2")
      shift 2
      ;;
    --last)
      [[ $# -ge 2 ]] || { usage; exit 64; }
      LAST="$2"
      shift 2
      ;;
    --connected-cleanly)
      CONNECTED_CLEANLY=1
      shift
      ;;
    --disconnected-cleanly)
      DISCONNECTED_CLEANLY=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 64
      ;;
  esac
done

case "$MODE" in
  iphone|macos) ;;
  -h|--help|help|"") usage; exit 64 ;;
  *) echo "Unsupported Apple smoke evidence mode: $MODE" >&2; usage; exit 64 ;;
esac

if [[ -z "$EVIDENCE_DIR" ]]; then
  usage
  exit 64
fi

mkdir -p "$EVIDENCE_DIR"

if [[ "$CONNECTED_CLEANLY" != "1" || "$DISCONNECTED_CLEANLY" != "1" ]]; then
  echo "Apple smoke evidence requires --connected-cleanly and --disconnected-cleanly." >&2
  exit 64
fi

if [[ "$MODE" == "iphone" && "${#FILES[@]}" -eq 0 ]]; then
  echo "iPhone TestFlight evidence requires at least one --file exported from the real device smoke." >&2
  exit 64
fi

if (( ${#FILES[@]} > 0 )); then
  for file in "${FILES[@]}"; do
    copy_supporting_file "$file"
  done
fi
write_notes

case "$MODE" in
  iphone)
    evidence_type="iphone_testflight_network_extension"
    ;;
  macos)
    evidence_type="macos_testflight_packet_tunnel"
    collect_macos_logs
    ;;
esac

"$ROOT_DIR/scripts/write-smoke-evidence-summary.sh" "$evidence_type" "$EVIDENCE_DIR"
cat >> "$EVIDENCE_DIR/summary.txt" <<EOF
apple_smoke_mode=$MODE
connected_cleanly=$CONNECTED_CLEANLY
disconnected_cleanly=$DISCONNECTED_CLEANLY
provided_file_count=${#FILES[@]}
notes_count=${#NOTES[@]}
supporting_evidence_file_count=$(supporting_evidence_file_count)
macos_system_log_collected=$MACOS_SYSTEM_LOG_COLLECTED
macos_appgroup_log_count=$MACOS_APPGROUP_LOG_COUNT
EOF
printf 'evidence_dir=%s\n' "$EVIDENCE_DIR"
