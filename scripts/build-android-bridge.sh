#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
GOMOBILE="${GOMOBILE:-gomobile}"

if ! command -v "$GOMOBILE" >/dev/null 2>&1; then
  echo "gomobile not found. Install it with: go install golang.org/x/mobile/cmd/gomobile@latest" >&2
  exit 1
fi

mkdir -p "$ROOT_DIR/androidApp/libs"

ANDROID_HOME="$ANDROID_HOME" "$GOMOBILE" bind \
  -target=android/arm64 \
  -androidapi 26 \
  -ldflags="-checklinkname=0" \
  -o "$ROOT_DIR/androidApp/libs/vkturnbridge.aar" \
  "$ROOT_DIR/mobilebridge"

ls -lh "$ROOT_DIR/androidApp/libs/vkturnbridge.aar" "$ROOT_DIR/androidApp/libs/vkturnbridge-sources.jar"
