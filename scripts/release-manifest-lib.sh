#!/usr/bin/env bash

release_manifest_path() {
  local root_dir="$1"
  local artifact="$2"
  local normalized_root="${root_dir%/}"
  local root_prefix="$normalized_root/"

  if [[ "$artifact" == "$root_prefix"* ]]; then
    printf '%s\n' "${artifact#$root_prefix}"
  else
    printf '%s\n' "$artifact"
  fi
}

release_manifest_write_entry() {
  local root_dir="$1"
  local artifact="$2"
  local checksum
  checksum="$(shasum -a 256 "$artifact" | awk '{print $1}')"
  printf '%s  %s\n' "$checksum" "$(release_manifest_path "$root_dir" "$artifact")"
}
