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

Download CI artifacts:

\`\`\`bash
"$OUT_DIR/commands/download-ci-artifacts.sh"
\`\`\`

Apple TestFlight secrets dry-run:

\`\`\`bash
CERT_P12=/absolute/path/AppleDistribution.p12 \\
CERT_PASSWORD='<p12 password>' \\
"$OUT_DIR/commands/apple-testflight-secrets.sh"
\`\`\`

Final readiness command template:

\`\`\`bash
cp "$OUT_DIR/templates/final-readiness.env.example" "$OUT_DIR/final-readiness.env"
# edit $OUT_DIR/final-readiness.env
"$OUT_DIR/commands/final-readiness-check.sh" "$OUT_DIR/final-readiness.env"
\`\`\`

Current cross-platform artifacts:

\`\`\`text
$(cat "$manifest")
\`\`\`
EOF

cat > "$OUT_DIR/commands/apple-testflight-secrets.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../../../.." && pwd)"
REPO="\${REPO:-MichaelPNZ/vk-turn-proxy-ios}"
TAG="\${TAG:-$TAG}"
TARGET="\${TARGET:-all}"
CERT_P12="\${CERT_P12:-}"
CERT_PASSWORD="\${CERT_PASSWORD:-}"
APPSTORE_ENV="\${APPSTORE_ENV:-"\$ROOT_DIR/VKTurnProxy/AppStoreConnect.env"}"
PROFILE_DIR="\${PROFILE_DIR:-"\$HOME/Library/MobileDevice/Provisioning Profiles"}"
DRY_RUN="\${DRY_RUN:-1}"
CONFIRM_WRITE_GITHUB_SECRETS="\${CONFIRM_WRITE_GITHUB_SECRETS:-}"

if [[ -z "\$CERT_P12" || -z "\$CERT_PASSWORD" ]]; then
  cat >&2 <<'EOF'
Set:
  CERT_P12=/absolute/path/AppleDistribution.p12
  CERT_PASSWORD='<p12 password>'

Optional:
  APPSTORE_ENV=/absolute/path/to/AppStoreConnect.env
  PROFILE_DIR=/absolute/path/to/Provisioning Profiles
  DRY_RUN=0
  CONFIRM_WRITE_GITHUB_SECRETS=MichaelPNZ/vk-turn-proxy-ios
EOF
  exit 64
fi

if [[ "\$DRY_RUN" != "1" && "\$CONFIRM_WRITE_GITHUB_SECRETS" != "\$REPO" ]]; then
  echo "Refusing to write GitHub secrets without CONFIRM_WRITE_GITHUB_SECRETS=\$REPO" >&2
  exit 64
fi

DRY_RUN="\$DRY_RUN" REPO="\$REPO" \\
"\$ROOT_DIR/scripts/configure-github-testflight-secrets.sh" \\
  --cert-p12 "\$CERT_P12" \\
  --cert-password "\$CERT_PASSWORD" \\
  --profiles-from-dir "\$PROFILE_DIR" \\
  --appstore-env "\$APPSTORE_ENV"

if [[ "\$DRY_RUN" == "1" ]]; then
  cat <<EOF
Dry-run passed. To write GitHub secrets, rerun with:
  DRY_RUN=0 CONFIRM_WRITE_GITHUB_SECRETS=\$REPO CERT_P12=... CERT_PASSWORD=... \\
    \$0
EOF
else
  cat <<EOF
GitHub TestFlight secrets written for \$REPO.
Next:
  gh workflow run testflight-release.yml --repo \$REPO --ref main -f tag=\$TAG -f target=\$TARGET
EOF
fi
SH
chmod +x "$OUT_DIR/commands/apple-testflight-secrets.sh"

cat > "$OUT_DIR/commands/download-ci-artifacts.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../../../.." && pwd)"
REPO="\${REPO:-MichaelPNZ/vk-turn-proxy-ios}"
TAG="\${TAG:-$TAG}"
RUN_ID="\${RUN_ID:-}"
DOWNLOAD_DIR="\${DOWNLOAD_DIR:-"\$ROOT_DIR"}"
ARTIFACT_NAME="vk-turn-proxy-\$TAG-ci-artifacts"

if ! command -v gh >/dev/null 2>&1; then
  echo "gh CLI is required to download CI artifacts." >&2
  exit 64
fi
if ! gh auth status >/dev/null 2>&1; then
  echo "gh CLI is not authenticated." >&2
  exit 64
fi

cd "\$ROOT_DIR"
tag_commit="\$(git rev-list -n 1 "\$TAG" 2>/dev/null || true)"
if [[ -z "\$tag_commit" ]]; then
  echo "Tag \$TAG is missing locally; fetch tags or pass RUN_ID explicitly." >&2
  exit 64
fi

if [[ -z "\$RUN_ID" ]]; then
  RUN_ID="\$(gh run list \\
    --repo "\$REPO" \\
    --workflow release-gates.yml \\
    --limit 100 \\
    --json databaseId,workflowName,status,conclusion,headSha \\
    --jq ".[] | select(.workflowName == \\"Release Gates\\" and .headSha == \\"\$tag_commit\\" and .status == \\"completed\\" and .conclusion == \\"success\\") | .databaseId" \\
    | head -1 || true)"
fi

if [[ -z "\$RUN_ID" ]]; then
  echo "No successful Release Gates run found for \$TAG (\$tag_commit)." >&2
  exit 1
fi

mkdir -p "\$DOWNLOAD_DIR"
gh run download "\$RUN_ID" \\
  --repo "\$REPO" \\
  --name "\$ARTIFACT_NAME" \\
  --dir "\$DOWNLOAD_DIR"

manifest="\$DOWNLOAD_DIR/build/release/\$TAG-cross-platform-sha256.txt"
if [[ ! -f "\$manifest" ]]; then
  echo "Downloaded artifact is missing checksum manifest: \$manifest" >&2
  exit 1
fi

(cd "\$DOWNLOAD_DIR" && shasum -a 256 -c "build/release/\$TAG-cross-platform-sha256.txt")

cat <<EOF
CI artifacts downloaded and verified.
RUN_ID=\$RUN_ID
DOWNLOAD_DIR=\$DOWNLOAD_DIR
ANDROID_APK=\$DOWNLOAD_DIR/androidApp/build/outputs/apk/release/androidApp-release.apk
ANDROID_AAB=\$DOWNLOAD_DIR/androidApp/build/outputs/bundle/release/androidApp-release.aab
WINDOWS_RUNTIME_ZIP=\$DOWNLOAD_DIR/build/windows-package/vk-turn-proxy-windows-runtime.zip
SERVER_PACKAGE=\$DOWNLOAD_DIR/build/server/vk-turn-proxy-server-\$TAG-linux-amd64.tar.gz
EXTERNAL_SMOKE_KIT=\$DOWNLOAD_DIR/build/external-smoke-kit/\$TAG
EOF
SH
chmod +x "$OUT_DIR/commands/download-ci-artifacts.sh"

cat > "$OUT_DIR/commands/android-physical-smoke.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
SERIAL="${SERIAL:-}"
PROFILE_FILE="${PROFILE_FILE:-}"
IMPORT_LINK="${IMPORT_LINK:-}"
USE_PUBLIC_SERVER="${USE_PUBLIC_SERVER:-1}"
HOST="${HOST:-142.252.220.91}"
SSH_USER="${SSH_USER:-root}"
PUBLIC_LISTEN="${PUBLIC_LISTEN:-0.0.0.0:56014}"
PUBLIC_HEALTH="${PUBLIC_HEALTH:-127.0.0.1:56085}"
CONNECT="${CONNECT:-127.0.0.1:51820}"
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

if [[ "$USE_PUBLIC_SERVER" == "1" ]]; then
  ANDROID_HOME="$ANDROID_HOME" \
  SERIAL="$SERIAL" \
  PROFILE_FILE="$PROFILE_FILE" \
  IMPORT_LINK="$IMPORT_LINK" \
  BUILD_RELEASE=0 \
  REQUIRE_PHYSICAL_DEVICE=1 \
  HOST="$HOST" \
  SSH_USER="$SSH_USER" \
  PUBLIC_LISTEN="$PUBLIC_LISTEN" \
  PUBLIC_HEALTH="$PUBLIC_HEALTH" \
  CONNECT="$CONNECT" \
  "$ROOT_DIR/scripts/smoke-android-release-with-public-server.sh" "$EVIDENCE_DIR"
else
  ANDROID_HOME="$ANDROID_HOME" \
  SERIAL="$SERIAL" \
  PROFILE_FILE="$PROFILE_FILE" \
  IMPORT_LINK="$IMPORT_LINK" \
  BUILD_RELEASE=0 \
  REQUIRE_PHYSICAL_DEVICE=1 \
  EVIDENCE_DIR="$EVIDENCE_DIR" \
  "$ROOT_DIR/scripts/smoke-android-release-imported-profile.sh"
  printf 'ANDROID_PHYSICAL_SMOKE_EVIDENCE=%s\n' "$EVIDENCE_DIR"
fi

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

cat > "$OUT_DIR/commands/final-readiness-check.sh" <<SH
#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/../../../.." && pwd)"
TAG="\${TAG:-$TAG}"
ENV_FILE="\${1:-"\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)/final-readiness.env"}"

usage() {
  cat >&2 <<'EOF'
Usage:
  commands/final-readiness-check.sh [final-readiness.env]

Copy templates/final-readiness.env.example to final-readiness.env, fill every
evidence path after the external smoke runs, then run this command from the
repository checkout.
EOF
}

if [[ "\${1:-}" == "-h" || "\${1:-}" == "--help" || "\${1:-}" == "help" ]]; then
  usage
  exit 64
fi

if [[ ! -f "\$ENV_FILE" ]]; then
  echo "Final readiness env file not found: \$ENV_FILE" >&2
  usage
  exit 64
fi

set -a
# shellcheck disable=SC1090
source "\$ENV_FILE"
set +a

required_env=(
  ANDROID_PHYSICAL_SMOKE_EVIDENCE
  IPHONE_TESTFLIGHT_SMOKE_EVIDENCE
  MACOS_TESTFLIGHT_SMOKE_EVIDENCE
  WINDOWS_RUNTIME_SMOKE_EVIDENCE
  WINDOWS_INSTALLER_SMOKE_EVIDENCE
  SERVER_PRODUCTION_SMOKE_EVIDENCE
)

missing=0
for name in "\${required_env[@]}"; do
  value="\${!name:-}"
  if [[ -z "\$value" || "\$value" == /absolute/path/* || "\$value" == *"..."* ]]; then
    echo "Missing concrete value for \$name in \$ENV_FILE" >&2
    missing=1
    continue
  fi
  if [[ ! -d "\$value" ]]; then
    echo "Evidence directory does not exist for \$name: \$value" >&2
    missing=1
  fi
done

if [[ "\$missing" == "1" ]]; then
  exit 64
fi

cd "\$ROOT_DIR"
scripts/final-release-readiness.sh "\$TAG"
SH
chmod +x "$OUT_DIR/commands/final-readiness-check.sh"

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
# Requires Inno Setup 6 and a code-signing certificate for final release.

$LatestEvidenceDir = ".\build\evidence\windows-installer-latest"
New-Item -ItemType Directory -Force -Path $LatestEvidenceDir | Out-Null
$SignCertSha1 = $env:WINDOWS_SIGN_CERT_SHA1
if ([string]::IsNullOrWhiteSpace($SignCertSha1)) {
  throw "Set WINDOWS_SIGN_CERT_SHA1 to the Windows code-signing certificate SHA1 before final installer smoke."
}
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows-installer.ps1 `
  -RuntimeZip .\build\windows-package\vk-turn-proxy-windows-runtime.zip `
  -Version 1.0.$BUILD_NUM `
  -SignCertSha1 $SignCertSha1 `
  *>&1 | Tee-Object -FilePath "$LatestEvidenceDir\installer-build-transcript.txt"

$Installer = Get-ChildItem .\build\windows-installer\vk-turn-proxy-windows-*-setup.exe |
  Sort-Object LastWriteTime -Descending |
  Select-Object -First 1
if (!$Installer) { throw "Installer EXE not found." }

$EvidenceDir = ".\build\evidence\windows-installer-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss'))"
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
Copy-Item "$LatestEvidenceDir\installer-build-transcript.txt" "$EvidenceDir\installer-build-transcript.txt"
Get-AuthenticodeSignature $Installer.FullName | Format-List * |
  Tee-Object -FilePath "$EvidenceDir\authenticode-signature.txt"
Get-FileHash -Algorithm SHA256 $Installer.FullName |
  Tee-Object -FilePath "$EvidenceDir\installer-sha256.txt"

# Install the generated setup EXE as Administrator, then record install output:
#   <installer.exe> /VERYSILENT /SUPPRESSMSGBOXES /NORESTART /LOG="$EvidenceDir\install-transcript.txt"
#
# Verify shortcuts/service and record output into:
#   $EvidenceDir\launch-or-service-smoke.txt
#
# Uninstall cleanly and record output into:
#   $EvidenceDir\uninstall-transcript.txt
#
# Then run the summary block below.
$RequiredEvidence = @(
  "$EvidenceDir\installer-build-transcript.txt",
  "$EvidenceDir\authenticode-signature.txt",
  "$EvidenceDir\installer-sha256.txt",
  "$EvidenceDir\install-transcript.txt",
  "$EvidenceDir\launch-or-service-smoke.txt",
  "$EvidenceDir\uninstall-transcript.txt"
)
foreach ($Path in $RequiredEvidence) {
  if (!(Test-Path $Path)) { throw "Missing Windows installer evidence file: $Path" }
}
$Hash = (Get-FileHash -Algorithm SHA256 $Installer.FullName).Hash.ToLowerInvariant()
bash scripts/write-smoke-evidence-summary.sh windows_installer_smoke $EvidenceDir
@"
installer_built=1
signature_verified=1
installed_cleanly=1
launched_cleanly=1
uninstalled_cleanly=1
installer_sha256=$Hash
"@ | Add-Content "$EvidenceDir\summary.txt"

Write-Host "Set WINDOWS_INSTALLER_SMOKE_EVIDENCE to $EvidenceDir."
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
#   cp "$OUT_DIR/templates/final-readiness.env.example" "$OUT_DIR/final-readiness.env"
#   # edit "$OUT_DIR/final-readiness.env"
#   "$OUT_DIR/commands/final-readiness-check.sh" "$OUT_DIR/final-readiness.env"

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
download_ci_artifacts_command=$OUT_DIR/commands/download-ci-artifacts.sh
android_command=$OUT_DIR/commands/android-physical-smoke.sh
apple_secrets_command=$OUT_DIR/commands/apple-testflight-secrets.sh
iphone_command=$OUT_DIR/commands/collect-iphone-testflight-evidence.sh
macos_command=$OUT_DIR/commands/collect-macos-testflight-evidence.sh
final_readiness_command=$OUT_DIR/commands/final-readiness-check.sh
windows_runtime_template=$OUT_DIR/templates/windows-runtime-smoke.ps1
windows_installer_template=$OUT_DIR/templates/windows-installer-smoke.ps1
server_template=$OUT_DIR/templates/server-production-final.sh
final_env_template=$OUT_DIR/templates/final-readiness.env.example
EOF

printf 'external_smoke_kit=%s\n' "$OUT_DIR"
