#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release-manifest-lib.sh"

TEST_DIR="$ROOT_DIR/build/tmp/release-manifest-format"
TEST_FILE="$TEST_DIR/inside.txt"
rm -rf "$TEST_DIR"
mkdir -p "$TEST_DIR"
printf 'vk-turn-proxy release manifest test\n' > "$TEST_FILE"

line="$(release_manifest_write_entry "$ROOT_DIR" "$TEST_FILE")"
expected_path="${TEST_FILE#$ROOT_DIR/}"

if [[ "$line" != *"  $expected_path" ]]; then
  printf 'ERROR: expected manifest path %s, got: %s\n' "$expected_path" "$line" >&2
  exit 1
fi

if [[ "$line" == *"$ROOT_DIR"* ]]; then
  printf 'ERROR: manifest entry leaks absolute repo path: %s\n' "$line" >&2
  exit 1
fi

shasum -a 256 "$TEST_FILE" | awk '{print $1}' | grep -q "^${line%%  *}$"

rm -rf "$TEST_DIR"
printf 'release manifest format ok\n'
