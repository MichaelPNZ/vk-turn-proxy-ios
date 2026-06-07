#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
RUN_APPLE_RELEASE="${RUN_APPLE_RELEASE:-1}"
RUN_VPS_DRY_RUN="${RUN_VPS_DRY_RUN:-0}"
RUN_ANDROID_RELEASE_SMOKE="${RUN_ANDROID_RELEASE_SMOKE:-0}"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
TAG="${TAG:-v1.0-build156}"

banner() {
  printf '\n==> %s\n' "$*"
}

run() {
  banner "$*"
  "$@"
}

check_shell_syntax() {
  local script
  for script in "$@"; do
    run bash -n "$script"
  done
}

cd "$ROOT_DIR"

banner "Local readiness gate"
printf 'Root: %s\n' "$ROOT_DIR"
printf 'RUN_APPLE_RELEASE=%s\n' "$RUN_APPLE_RELEASE"
printf 'RUN_VPS_DRY_RUN=%s\n' "$RUN_VPS_DRY_RUN"
printf 'RUN_ANDROID_RELEASE_SMOKE=%s\n' "$RUN_ANDROID_RELEASE_SMOKE"
printf 'TAG=%s\n' "$TAG"

check_shell_syntax \
  release.sh \
  scripts/build-android-bridge.sh \
  scripts/build-apple-release-local.sh \
  scripts/configure-testflight-env.sh \
  scripts/collect-apple-signing-evidence.sh \
  scripts/collect-apple-smoke-evidence.sh \
  scripts/configure-github-testflight-secrets.sh \
  scripts/collect-server-production-evidence.sh \
  scripts/diagnose-apple-signing.sh \
  scripts/build-windows-service.sh \
  scripts/deploy-server-vps.sh \
  scripts/final-release-readiness.sh \
  scripts/local-readiness-gate.sh \
  scripts/package-release-artifacts.sh \
  scripts/prepare-external-smoke-kit.sh \
  scripts/release-blockers-status.sh \
  scripts/release-manifest-lib.sh \
  scripts/package-server.sh \
  scripts/package-windows-runtime.sh \
  scripts/test-server-deploy-safety.sh \
  scripts/test-android-physical-evidence-contract.sh \
  scripts/test-windows-runtime-evidence-contract.sh \
  scripts/test-server-production-evidence-contract.sh \
  scripts/test-external-smoke-kit.sh \
  scripts/test-windows-installer-packaging.sh \
  scripts/preflight-android-release.sh \
  scripts/preflight-testflight.sh \
  scripts/preflight-windows-desktop.sh \
  scripts/smoke-android-release-imported-profile.sh \
  scripts/server-public-smoke-vps.sh \
  scripts/smoke-android-imported-profile.sh \
  scripts/write-smoke-evidence-summary.sh

run git diff --check
run scripts/test-release-manifest-format.sh
run scripts/test-server-deploy-safety.sh
run scripts/test-android-physical-evidence-contract.sh
run scripts/test-windows-runtime-evidence-contract.sh
run scripts/test-server-production-evidence-contract.sh
run env TAG="$TAG" scripts/test-external-smoke-kit.sh
run scripts/test-windows-installer-packaging.sh
run go test ./...
run scripts/package-server.sh
run scripts/package-release-artifacts.sh "$TAG"

if [[ "$RUN_VPS_DRY_RUN" == "1" ]]; then
  banner "Running VPS localhost-only dry-run"
  MODE=dry-run SSH_USER="$SSH_USER" HOST="$HOST" scripts/deploy-server-vps.sh
else
  banner "Skipping VPS dry-run"
  printf 'Set RUN_VPS_DRY_RUN=1 to run MODE=dry-run against %s as %s.\n' "$HOST" "$SSH_USER"
fi

banner "Running Kotlin/Android/Desktop gates"
ANDROID_HOME="$ANDROID_HOME" ./gradlew \
  :shared:allTests \
  :androidApp:assembleDebug \
  :androidApp:assembleRelease \
  :androidApp:bundleRelease \
  :desktopApp:build \
  :shared:assembleVKTurnSharedReleaseXCFramework

banner "Running Android release preflight"
EXPECTED_ANDROID_VERSION_CODE="${TAG##*build}" ANDROID_HOME="$ANDROID_HOME" scripts/preflight-android-release.sh

if [[ "$RUN_ANDROID_RELEASE_SMOKE" == "1" ]]; then
  banner "Running Android signed release imported-profile smoke"
  ANDROID_HOME="$ANDROID_HOME" scripts/smoke-android-release-imported-profile.sh
else
  banner "Skipping Android signed release imported-profile smoke"
  printf 'Set RUN_ANDROID_RELEASE_SMOKE=1 with an attached/booted Android device or emulator to run it.\n'
fi

banner "Running Windows desktop preflight with external blockers allowed"
ALLOW_EXTERNAL_BLOCKERS=1 ANDROID_HOME="$ANDROID_HOME" scripts/preflight-windows-desktop.sh

if [[ "$RUN_APPLE_RELEASE" == "1" ]]; then
  banner "Running local unsigned Apple Release gate"
  ANDROID_HOME="$ANDROID_HOME" scripts/build-apple-release-local.sh all
else
  banner "Skipping local unsigned Apple Release gate"
fi

banner "Running TestFlight preflight with external blockers allowed"
scripts/collect-apple-signing-evidence.sh build/evidence/apple-signing-current
ALLOW_EXTERNAL_BLOCKERS=1 scripts/preflight-testflight.sh

banner "Local readiness gate passed"
