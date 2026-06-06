#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEMPLATE="$ROOT_DIR/packaging/windows/inno/vk-turn-proxy.iss.tpl"
SCRIPT="$ROOT_DIR/scripts/package-windows-installer.ps1"
RELEASE_PACKAGER="$ROOT_DIR/scripts/package-release-artifacts.sh"
RUNTIME_DIR="$ROOT_DIR/build/windows-package/vk-turn-proxy-windows"

[[ -f "$TEMPLATE" ]] || { echo "Missing $TEMPLATE" >&2; exit 1; }
[[ -f "$SCRIPT" ]] || { echo "Missing $SCRIPT" >&2; exit 1; }
[[ -f "$RELEASE_PACKAGER" ]] || { echo "Missing $RELEASE_PACKAGER" >&2; exit 1; }

grep -q 'PrivilegesRequired=admin' "$TEMPLATE"
grep -q 'UninstallVKTurnProxyTunnelService' "$TEMPLATE"
grep -q 'desktopApp\\bin\\desktopApp.bat' "$TEMPLATE"
grep -q 'install-service.ps1' "$TEMPLATE"
grep -q 'signtool' "$SCRIPT"
grep -q 'Inno Setup 6\\ISCC.exe' "$SCRIPT"
grep -q 'Expand-Archive' "$SCRIPT"
grep -q 'add_optional_windows_installer' "$RELEASE_PACKAGER"
grep -Fq 'vk-turn-proxy-windows-*-setup.exe' "$RELEASE_PACKAGER"
grep -q 'smoke-windows-runtime.ps1' "$ROOT_DIR/scripts/package-windows-runtime.sh"
grep -q 'wireguard_attached' "$ROOT_DIR/scripts/package-windows-runtime.sh"
grep -q 'windows_runtime_smoke' "$ROOT_DIR/scripts/package-windows-runtime.sh"
grep -q 'install-wintun.ps1' "$ROOT_DIR/scripts/package-windows-runtime.sh"
grep -q 'https://www.wintun.net/builds/wintun-0.14.1.zip' "$ROOT_DIR/scripts/package-windows-runtime.sh"
grep -q '07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51' "$ROOT_DIR/scripts/package-windows-runtime.sh"

if grep -R '/Users/' "$TEMPLATE" "$SCRIPT" >/dev/null; then
  echo "Installer packaging files must not contain local absolute paths." >&2
  exit 1
fi

if [[ -d "$RUNTIME_DIR" ]]; then
  [[ -f "$RUNTIME_DIR/bin/vk-turn-proxy-windows-service.exe" ]]
  [[ -f "$RUNTIME_DIR/app/desktopApp.zip" ]]
  [[ -f "$RUNTIME_DIR/install-wintun.ps1" ]]
  [[ -f "$RUNTIME_DIR/install-service.ps1" ]]
  [[ -f "$RUNTIME_DIR/start-tunnel.ps1" ]]
  [[ -f "$RUNTIME_DIR/status-tunnel.ps1" ]]
  [[ -f "$RUNTIME_DIR/export-logs.ps1" ]]
  [[ -f "$RUNTIME_DIR/smoke-windows-runtime.ps1" ]]
fi

printf 'windows installer packaging ok\n'
