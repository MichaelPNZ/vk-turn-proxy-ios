#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-server-public-smoke-evidence.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

evidence="$TMP_DIR/evidence"
mkdir -p "$evidence"
printf 'fixture public smoke log\n' > "$evidence/start.txt"
"$ROOT_DIR/scripts/write-smoke-evidence-summary.sh" server_public_smoke "$evidence" > "$TMP_DIR/write.out"

grep -q '^result=passed$' "$evidence/summary.txt"
grep -q '^evidence_type=server_public_smoke$' "$evidence/summary.txt"
grep -q '^attachment_count=1$' "$evidence/summary.txt"

if PUBLIC_LISTEN=0.0.0.0:56004 "$ROOT_DIR/scripts/collect-server-public-smoke-evidence.sh" "$TMP_DIR/refuse" > "$TMP_DIR/refuse.out" 2>&1; then
  echo "Public smoke collector must refuse production port 56004." >&2
  exit 1
fi
grep -q 'Refusing to use production port 56004' "$TMP_DIR/refuse.out"

printf 'server public smoke evidence contract ok\n'
