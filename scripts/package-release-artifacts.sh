#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
source "$ROOT_DIR/scripts/release-manifest-lib.sh"

if [[ -z "$TAG" ]]; then
  cat >&2 <<'EOF'
Usage: scripts/package-release-artifacts.sh <tag>

Builds non-Apple release artifacts that can be verified without TestFlight:
- Android release APK
- Android release AAB
- Windows runtime zip
- Optional Windows EXE installer if build/windows-installer/vk-turn-proxy-windows-*-setup.exe exists
- Linux amd64 server package
- checksum manifest for the artifacts above
EOF
  exit 64
fi

cd "$ROOT_DIR"

if [[ ! "$TAG" =~ build[0-9]+$ ]]; then
  echo "ERROR: tag must end with build<N>, got: $TAG" >&2
  exit 64
fi
BUILD_NUM="${TAG##*build}"

ARTIFACTS=()

add_artifact() {
  local artifact="$1"
  if [[ -z "$artifact" || ! -f "$artifact" ]]; then
    echo "ERROR: expected artifact does not exist: ${artifact:-unset}" >&2
    exit 1
  fi
  ARTIFACTS+=("$artifact")
  printf 'artifact=%s\n' "$artifact"
  printf 'sha256=%s\n' "$(shasum -a 256 "$artifact" | awk '{print $1}')"
}

add_optional_windows_installer() {
  local installer
  installer="$(find "$ROOT_DIR/build/windows-installer" -maxdepth 1 -type f -name 'vk-turn-proxy-windows-*-setup.exe' 2>/dev/null | sort | tail -1 || true)"
  if [[ -n "$installer" ]]; then
    echo "==> Adding prebuilt Windows installer artifact"
    add_artifact "$installer"
  else
    echo "==> No prebuilt Windows installer artifact found; skipping optional EXE installer"
  fi
}

echo "==> Building Android release artifacts"
ANDROID_HOME="$ANDROID_HOME" ./gradlew \
  :androidApp:assembleRelease \
  :androidApp:bundleRelease >/dev/null
EXPECTED_ANDROID_VERSION_CODE="$BUILD_NUM" ANDROID_HOME="$ANDROID_HOME" scripts/preflight-android-release.sh
add_artifact "$ROOT_DIR/androidApp/build/outputs/apk/release/androidApp-release.apk"
add_artifact "$ROOT_DIR/androidApp/build/outputs/bundle/release/androidApp-release.aab"

echo "==> Building Windows runtime artifact"
windows_output="$(ANDROID_HOME="$ANDROID_HOME" scripts/package-windows-runtime.sh)"
printf '%s\n' "$windows_output"
windows_package="$(awk -F= '/^package=/{print $2}' <<<"$windows_output" | tail -1)"
add_artifact "$windows_package"
add_optional_windows_installer

echo "==> Building Linux server artifact"
server_output="$(VERSION="$TAG" scripts/package-server.sh)"
printf '%s\n' "$server_output"
server_package="$(awk -F= '/^package=/{print $2}' <<<"$server_output" | tail -1)"
add_artifact "$server_package"

echo "==> Writing checksum manifest"
manifest="$ROOT_DIR/build/release/$TAG-cross-platform-sha256.txt"
mkdir -p "$(dirname "$manifest")"
: > "$manifest"
for artifact in "${ARTIFACTS[@]}"; do
  release_manifest_write_entry "$ROOT_DIR" "$artifact" >> "$manifest"
done
add_artifact "$manifest"

echo "==> Cross-platform release artifacts ready"
