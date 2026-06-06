#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
SERVICE_EXE="${SERVICE_EXE:-}"
ALLOW_EXTERNAL_BLOCKERS="${ALLOW_EXTERNAL_BLOCKERS:-0}"
BUILD_SERVICE="${BUILD_SERVICE:-1}"

printf 'Windows desktop preflight for %s\n\n' "$ROOT_DIR"

cd "$ROOT_DIR"

ANDROID_HOME="$ANDROID_HOME" ./gradlew :desktopApp:test :desktopApp:installDist

if [[ "$BUILD_SERVICE" == "1" ]]; then
  scripts/build-windows-service.sh
  SERVICE_EXE="${SERVICE_EXE:-"$ROOT_DIR/build/windows/vk-turn-proxy-windows-service.exe"}"
fi

args=(windows-preflight)
if [[ -n "$SERVICE_EXE" ]]; then
  args+=(--service-exe "$SERVICE_EXE")
fi

set +e
output="$(desktopApp/build/install/desktopApp/bin/desktopApp "${args[@]}" 2>&1)"
status=$?
set -e

printf '%s\n' "$output"

if [[ "$status" -eq 0 ]]; then
  printf '\nWindows desktop preflight passed.\n'
  exit 0
fi

if [[ "$ALLOW_EXTERNAL_BLOCKERS" == "1" ]]; then
  printf '\nWindows desktop preflight has external blockers; continuing because ALLOW_EXTERNAL_BLOCKERS=1.\n'
  exit 0
fi

printf '\nWindows desktop preflight failed.\n'
exit "$status"
