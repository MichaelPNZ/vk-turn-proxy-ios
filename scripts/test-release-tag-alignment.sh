#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/scripts/release-tag-lib.sh"

TMP_DIR="$ROOT_DIR/build/tmp/release-tag-alignment"
REPO_DIR="$TMP_DIR/repo"
rm -rf "$TMP_DIR"
mkdir -p "$REPO_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email "ci@example.invalid"
git -C "$REPO_DIR" config user.name "CI"

printf 'first\n' > "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -q -m "first"
git -C "$REPO_DIR" tag -a v1.0-build999 -m "v1.0-build999"

aligned_detail="$(release_tag_alignment_detail "$REPO_DIR" v1.0-build999)"
grep -q '^tag_points_to_head=v1.0-build999 ' <<<"$aligned_detail"

printf 'second\n' > "$REPO_DIR/file.txt"
git -C "$REPO_DIR" add file.txt
git -C "$REPO_DIR" commit -q -m "second"

set +e
mismatch_detail="$(release_tag_alignment_detail "$REPO_DIR" v1.0-build999)"
mismatch_code=$?
missing_detail="$(release_tag_alignment_detail "$REPO_DIR" v1.0-build1000)"
missing_code=$?
set -e

if [[ "$mismatch_code" -ne 1 ]]; then
  printf 'Expected tag mismatch exit 1, got %s: %s\n' "$mismatch_code" "$mismatch_detail" >&2
  exit 1
fi
grep -q '^tag_mismatch=v1.0-build999 ' <<<"$mismatch_detail"

if [[ "$missing_code" -ne 2 ]]; then
  printf 'Expected missing tag exit 2, got %s: %s\n' "$missing_code" "$missing_detail" >&2
  exit 1
fi
grep -q '^tag_missing=v1.0-build1000$' <<<"$missing_detail"

printf 'release tag alignment ok\n'
