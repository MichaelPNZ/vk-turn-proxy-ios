#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${TAG:-v1.0-build160}"
OUT_DIR="$(mktemp -d "$ROOT_DIR/build/test-external-smoke-kit-$TAG.XXXXXX")"
MANIFEST="$ROOT_DIR/build/release/$TAG-cross-platform-sha256.txt"
created_manifest=0
cleanup() {
  rm -rf "$OUT_DIR"
  if [[ "$created_manifest" == "1" ]]; then
    rm -f "$MANIFEST"
  fi
}
trap cleanup EXIT

if [[ ! -f "$MANIFEST" ]]; then
  mkdir -p "$(dirname "$MANIFEST")"
  {
    printf 'fixture-sha256  fixture-artifact\n'
  } > "$MANIFEST"
  created_manifest=1
fi

"$ROOT_DIR/scripts/prepare-external-smoke-kit.sh" "$TAG" "$OUT_DIR" >/dev/null

required=(
  README.md
  summary.txt
  cross-platform-sha256.txt
  commands/download-ci-artifacts.sh
  commands/apple-testflight-secrets.sh
  commands/android-physical-smoke.sh
  commands/collect-iphone-testflight-evidence.sh
  commands/collect-macos-testflight-evidence.sh
  commands/final-readiness-check.sh
  templates/windows-runtime-smoke.ps1
  templates/windows-installer-smoke.ps1
  templates/server-production-final.sh
  templates/final-readiness.env.example
)

for file in "${required[@]}"; do
  [[ -f "$OUT_DIR/$file" ]] || {
    echo "Missing kit file: $OUT_DIR/$file" >&2
    exit 1
  }
done

bash -n \
  "$OUT_DIR/commands/download-ci-artifacts.sh" \
  "$OUT_DIR/commands/apple-testflight-secrets.sh" \
  "$OUT_DIR/commands/android-physical-smoke.sh" \
  "$OUT_DIR/commands/collect-iphone-testflight-evidence.sh" \
  "$OUT_DIR/commands/collect-macos-testflight-evidence.sh" \
  "$OUT_DIR/commands/final-readiness-check.sh" \
  "$OUT_DIR/templates/server-production-final.sh"

grep -q '^result=prepared$' "$OUT_DIR/summary.txt"
grep -q 'commands/download-ci-artifacts.sh' "$OUT_DIR/README.md"
grep -q 'commands/final-readiness-check.sh' "$OUT_DIR/README.md"
grep -q '^export ANDROID_PHYSICAL_SMOKE_EVIDENCE=' "$OUT_DIR/templates/final-readiness.env.example"
grep -q '^export SERVER_PRODUCTION_SMOKE_EVIDENCE=' "$OUT_DIR/templates/final-readiness.env.example"
grep -q '^final_readiness_command=' "$OUT_DIR/summary.txt"
grep -q '^download_ci_artifacts_command=' "$OUT_DIR/summary.txt"
grep -q '^apple_secrets_command=' "$OUT_DIR/summary.txt"
grep -q 'gh run download "$RUN_ID"' "$OUT_DIR/commands/download-ci-artifacts.sh"
grep -q 'shasum -a 256 -c "build/release/$TAG-cross-platform-sha256.txt"' "$OUT_DIR/commands/download-ci-artifacts.sh"
grep -q 'DRY_RUN="${DRY_RUN:-1}"' "$OUT_DIR/commands/apple-testflight-secrets.sh"
grep -q 'CONFIRM_WRITE_GITHUB_SECRETS' "$OUT_DIR/commands/apple-testflight-secrets.sh"
grep -q -- '--profiles-from-dir "$PROFILE_DIR"' "$OUT_DIR/commands/apple-testflight-secrets.sh"
grep -q -- '--appstore-env "$APPSTORE_ENV"' "$OUT_DIR/commands/apple-testflight-secrets.sh"
grep -q 'REQUIRE_PHYSICAL_DEVICE=1' "$OUT_DIR/commands/android-physical-smoke.sh"
grep -q 'Missing concrete value for $name' "$OUT_DIR/commands/final-readiness-check.sh"
grep -q 'Evidence directory does not exist for $name' "$OUT_DIR/commands/final-readiness-check.sh"
grep -q 'scripts/final-release-readiness.sh "$TAG"' "$OUT_DIR/commands/final-readiness-check.sh"
grep -q 'CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004' "$OUT_DIR/templates/server-production-final.sh"
grep -q 'exit 64' "$OUT_DIR/templates/server-production-final.sh"

if grep -RE 'vkturnproxy://import\?data=[A-Za-z0-9_-]{20,}' "$OUT_DIR" >/dev/null; then
  echo "External smoke kit must not embed concrete import links." >&2
  exit 1
fi
if grep -R 'APPSTORE_KEY_ID=.*[A-Z0-9]' "$OUT_DIR" >/dev/null; then
  echo "External smoke kit must not embed App Store Connect key ids." >&2
  exit 1
fi

printf 'external smoke kit ok\n'
