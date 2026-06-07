#!/usr/bin/env bash

release_short_sha() {
  local sha="$1"
  printf '%.7s' "$sha"
}

release_tag_exists() {
  local root_dir="$1"
  local tag="$2"
  git -C "$root_dir" rev-parse -q --verify "refs/tags/$tag" >/dev/null
}

release_head_commit() {
  local root_dir="$1"
  git -C "$root_dir" rev-parse HEAD
}

release_tag_commit() {
  local root_dir="$1"
  local tag="$2"
  git -C "$root_dir" rev-parse "$tag^{commit}"
}

release_tag_alignment_detail() {
  local root_dir="$1"
  local tag="$2"
  if ! release_tag_exists "$root_dir" "$tag"; then
    printf 'tag_missing=%s\n' "$tag"
    return 2
  fi

  local head_commit tag_commit
  head_commit="$(release_head_commit "$root_dir")"
  tag_commit="$(release_tag_commit "$root_dir" "$tag")"
  if [[ "$tag_commit" == "$head_commit" ]]; then
    printf 'tag_points_to_head=%s head=%s\n' "$tag" "$(release_short_sha "$head_commit")"
    return 0
  fi

  printf 'tag_mismatch=%s tag_commit=%s head=%s\n' \
    "$tag" \
    "$(release_short_sha "$tag_commit")" \
    "$(release_short_sha "$head_commit")"
  return 1
}
