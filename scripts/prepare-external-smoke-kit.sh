#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TAG="${1:-}"
OUT_DIR="${2:-}"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"

usage() {
  cat >&2 <<'EOF'
Usage:
  scripts/prepare-external-smoke-kit.sh <tag> [out-dir]

Creates a no-secrets handoff kit for external release gates:
- physical Android signed APK smoke;
- iPhone TestFlight Network Extension evidence;
- signed macOS Packet Tunnel evidence;
- Windows runtime/installer evidence;
- production server/client smoke evidence after explicit promote.

The kit contains commands/templates only. It does not promote production,
write Apple secrets, or embed profile/import-link secrets.
EOF
}

if [[ -z "$TAG" || "$TAG" == "-h" || "$TAG" == "--help" || "$TAG" == "help" ]]; then
  usage
  exit 64
fi
if [[ ! "$TAG" =~ build[0-9]+$ ]]; then
  echo "ERROR: tag must end with build<N>, got: $TAG" >&2
  exit 64
fi
BUILD_NUM="${TAG##*build}"

cd "$ROOT_DIR"

if [[ -z "$OUT_DIR" ]]; then
  OUT_DIR="$ROOT_DIR/build/external-smoke-kit/$TAG"
fi

manifest="$ROOT_DIR/build/release/$TAG-cross-platform-sha256.txt"
if [[ ! -f "$manifest" ]]; then
  ANDROID_HOME="$ANDROID_HOME" "$ROOT_DIR/scripts/package-release-artifacts.sh" "$TAG" >/dev/null
fi

mkdir -p "$OUT_DIR/commands" "$OUT_DIR/templates"
cp "$manifest" "$OUT_DIR/cross-platform-sha256.txt"

cat > "$OUT_DIR/README.md" <<EOF
# VK Turn Proxy External Smoke Kit

Tag: \`$TAG\`

This kit contains no Apple credentials, no private profile payloads, and no
production promote command that can run accidentally.

Use it to collect final evidence for Android physical-device, iPhone TestFlight,
signed macOS Packet Tunnel, Windows runtime/installer, and production
server/client smoke gates.

Final readiness command template:

\`\`\`bash
source "$OUT_DIR/templates/final-readiness.env.example"
scripts/final-release-readiness.sh "$TAG"
\`\`\`

Current cross-platform artifacts:

\`\`\`text
$(cat "$manifest")
\`\`\`
EOF

cat > "$OUT_DIR/commands/android-physical-smoke.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
SERIAL="${SERIAL:-}"
PROFILE_FILE="${PROFILE_FILE:-}"
IMPORT_LINK="${IMPORT_LINK:-}"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
EVIDENCE_DIR="${EVIDENCE_DIR:-"$ROOT_DIR/build/evidence/android-physical-$STAMP"}"

if [[ -z "$PROFILE_FILE" && -z "$IMPORT_LINK" ]]; then
  cat >&2 <<'EOF'
Set one of:
  PROFILE_FILE=/absolute/path/to/full-backup-or-connection.json
  IMPORT_LINK='vkturnproxy://import?data=...'

Then connect one physical Android device with USB debugging enabled.
EOF
  exit 64
fi

ANDROID_HOME="$ANDROID_HOME" \
SERIAL="$SERIAL" \
PROFILE_FILE="$PROFILE_FILE" \
IMPORT_LINK="$IMPORT_LINK" \
BUILD_RELEASE=0 \
REQUIRE_PHYSICAL_DEVICE=1 \
EVIDENCE_DIR="$EVIDENCE_DIR" \
"$ROOT_DIR/scripts/smoke-android-release-imported-profile.sh"

printf 'ANDROID_PHYSICAL_SMOKE_EVIDENCE=%s\n' "$EVIDENCE_DIR"
SH
chmod +x "$OUT_DIR/commands/android-physical-smoke.sh"

cat > "$OUT_DIR/commands/collect-iphone-testflight-evidence.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
FILE="${1:-}"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
EVIDENCE_DIR="${EVIDENCE_DIR:-"$ROOT_DIR/build/evidence/iphone-testflight-$STAMP"}"

if [[ -z "$FILE" || ! -f "$FILE" ]]; then
  cat >&2 <<'EOF'
Usage:
  commands/collect-iphone-testflight-evidence.sh /absolute/path/to/exported-vpn-log-or-screenshot

Run this after a real iPhone TestFlight build connects and disconnects cleanly.
EOF
  exit 64
fi

"$ROOT_DIR/scripts/collect-apple-smoke-evidence.sh" \
  iphone \
  "$EVIDENCE_DIR" \
  --file "$FILE" \
  --connected-cleanly \
  --disconnected-cleanly \
  --note "iPhone TestFlight Network Extension connected and disconnected cleanly"

printf 'IPHONE_TESTFLIGHT_SMOKE_EVIDENCE=%s\n' "$EVIDENCE_DIR"
SH
chmod +x "$OUT_DIR/commands/collect-iphone-testflight-evidence.sh"

cat > "$OUT_DIR/commands/collect-macos-testflight-evidence.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
EVIDENCE_DIR="${EVIDENCE_DIR:-"$ROOT_DIR/build/evidence/macos-testflight-$STAMP"}"

"$ROOT_DIR/scripts/collect-apple-smoke-evidence.sh" \
  macos \
  "$EVIDENCE_DIR" \
  --connected-cleanly \
  --disconnected-cleanly \
  --last "${LAST:-30m}" \
  --note "Signed macOS Packet Tunnel connected and disconnected cleanly"

printf 'MACOS_TESTFLIGHT_SMOKE_EVIDENCE=%s\n' "$EVIDENCE_DIR"
SH
chmod +x "$OUT_DIR/commands/collect-macos-testflight-evidence.sh"

cat > "$OUT_DIR/templates/windows-runtime-smoke.ps1" <<'PS1'
# Run on Windows as Administrator after unpacking vk-turn-proxy-windows-runtime.zip.
# Generate config\start-request.json from the desktop app first.

powershell -ExecutionPolicy Bypass -File .\install-wintun.ps1
powershell -ExecutionPolicy Bypass -File .\test-prereqs.ps1
powershell -ExecutionPolicy Bypass -File .\smoke-windows-runtime.ps1

Write-Host "Set WINDOWS_RUNTIME_SMOKE_EVIDENCE to the printed config\windows-smoke-<timestamp> directory."
PS1

cat > "$OUT_DIR/templates/windows-installer-smoke.ps1" <<'PS1'
# Run on Windows after copying the repository or release artifacts.
# Requires Inno Setup 6. SignCertSha1 is optional.

powershell -ExecutionPolicy Bypass -File .\scripts\package-windows-installer.ps1 `
  -RuntimeZip .\build\windows-package\vk-turn-proxy-windows-runtime.zip `
  -Version 1.0.$BUILD_NUM

# Install the generated setup EXE as Administrator, verify shortcuts/service
# install/uninstall, then put transcript/signature/install evidence files into:
#   build\evidence\windows-installer-<date>
#
# Then write final summary:
# bash scripts/write-smoke-evidence-summary.sh windows_installer_smoke build/evidence/windows-installer-<date>
PS1

cat > "$OUT_DIR/templates/server-production-final.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

cat >&2 <<'EOF'
This template is intentionally not executable as a promote command.

After explicit approval to promote production 142.252.220.91:56004:

1. Promote:
   CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004 \
     MODE=promote \
     SSH_USER=root \
     HOST=142.252.220.91 \
     scripts/deploy-server-vps.sh

2. Run a production-port client smoke and save its log.

3. Collect final evidence:
   MODE=final \
     BACKUP_DIR=/var/backups/vk-turn-proxy-ios/<timestamp-from-promote> \
     CLIENT_SMOKE_LOG=/absolute/path/to/production-client-smoke.log \
     HOST=142.252.220.91 \
     SSH_USER=root \
     scripts/collect-server-production-evidence.sh \
     build/evidence/server-production-<date>

4. Set SERVER_PRODUCTION_SMOKE_EVIDENCE to that evidence directory.
EOF
exit 64
SH
chmod +x "$OUT_DIR/templates/server-production-final.sh"

cat > "$OUT_DIR/templates/final-readiness.env.example" <<EOF
# Fill these after each external smoke passes, then run:
#   source "$OUT_DIR/templates/final-readiness.env.example"
#   scripts/final-release-readiness.sh "$TAG"

export ANDROID_PHYSICAL_SMOKE_EVIDENCE=/absolute/path/to/build/evidence/android-physical-...
export IPHONE_TESTFLIGHT_SMOKE_EVIDENCE=/absolute/path/to/build/evidence/iphone-testflight-...
export MACOS_TESTFLIGHT_SMOKE_EVIDENCE=/absolute/path/to/build/evidence/macos-testflight-...
export WINDOWS_RUNTIME_SMOKE_EVIDENCE=/absolute/path/to/windows-smoke-...
export WINDOWS_INSTALLER_SMOKE_EVIDENCE=/absolute/path/to/build/evidence/windows-installer-...
export SERVER_PRODUCTION_SMOKE_EVIDENCE=/absolute/path/to/build/evidence/server-production-...
EOF

cat > "$OUT_DIR/summary.txt" <<EOF
result=prepared
tag=$TAG
created_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
kit_dir=$OUT_DIR
manifest=$OUT_DIR/cross-platform-sha256.txt
android_command=$OUT_DIR/commands/android-physical-smoke.sh
iphone_command=$OUT_DIR/commands/collect-iphone-testflight-evidence.sh
macos_command=$OUT_DIR/commands/collect-macos-testflight-evidence.sh
windows_runtime_template=$OUT_DIR/templates/windows-runtime-smoke.ps1
windows_installer_template=$OUT_DIR/templates/windows-installer-smoke.ps1
server_template=$OUT_DIR/templates/server-production-final.sh
final_env_template=$OUT_DIR/templates/final-readiness.env.example
EOF

printf 'external_smoke_kit=%s\n' "$OUT_DIR"
