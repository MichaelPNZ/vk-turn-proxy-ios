#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SET="${1:-all}"
PROJECT="$ROOT_DIR/VKTurnProxy/VKTurnProxy.xcodeproj"
DERIVED_DATA="$ROOT_DIR/VKTurnProxy/build_output/DerivedData-local-release"

usage() {
  cat >&2 <<EOF
Usage:
  $0 [all|ios|macos]

Builds local unsigned Release configurations. This is a compile/link gate only:
it does not archive, sign, export, upload to TestFlight, or touch App Store Connect.
EOF
}

case "$TARGET_SET" in
  all) TARGETS=(ios macos) ;;
  ios) TARGETS=(ios) ;;
  macos) TARGETS=(macos) ;;
  -h|--help|help) usage; exit 0 ;;
  *) usage; exit 64 ;;
esac

banner() {
  printf '\n==> %s\n' "$*"
}

build_target() {
  local platform="$1"
  local scheme="$2"
  banner "Building $scheme Release for $platform without signing"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$scheme" \
    -configuration Release \
    -destination "generic/platform=$platform" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY="" \
    build
}

cd "$ROOT_DIR"

banner "Building WireGuardTURN.xcframework"
( cd WireGuardBridge && make xcframework )

banner "Building VKTurnShared.xcframework"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}" \
  ./gradlew :shared:assembleVKTurnSharedReleaseXCFramework

for target in "${TARGETS[@]}"; do
  case "$target" in
    ios) build_target "iOS" "VKTurnProxy" ;;
    macos) build_target "macOS" "VKTurnProxyMac" ;;
  esac
done

banner "Local Apple Release build gate passed for: ${TARGETS[*]}"
