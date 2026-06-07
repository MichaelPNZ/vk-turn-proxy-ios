#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/smoke-windows-runtime-package-ci.ps1"
WORKFLOW="$ROOT_DIR/.github/workflows/release-gates.yml"

[[ -f "$SCRIPT" ]]
[[ -f "$WORKFLOW" ]]

grep -q 'windows_runtime_package_ci_smoke' "$SCRIPT"
grep -q 'windows-start-request' "$SCRIPT"
grep -q 'windows-preflight' "$SCRIPT"
grep -q 'windows-service-commands' "$SCRIPT"
grep -q '"-mode" "validate" "-request"' "$SCRIPT"
grep -q 'serviceValidateOk = \$true' "$SCRIPT"
grep -q 'desktopPreflightOk = \$true' "$SCRIPT"

if grep -q 'evidenceType = "windows_runtime_smoke"' "$SCRIPT"; then
  echo "Package CI smoke must not claim final windows_runtime_smoke evidence." >&2
  exit 1
fi

grep -q 'windows-runtime-package-smoke:' "$WORKFLOW"
grep -q 'runs-on: windows-latest' "$WORKFLOW"
grep -q 'scripts/package-windows-runtime.sh' "$WORKFLOW"
grep -q 'scripts/smoke-windows-runtime-package-ci.ps1' "$WORKFLOW"
grep -q 'vk-turn-proxy-windows-package-smoke-' "$WORKFLOW"

if command -v pwsh >/dev/null 2>&1; then
  pwsh -NoProfile -NonInteractive -Command "\$null = [scriptblock]::Create((Get-Content -Raw '$SCRIPT'))"
fi

printf 'windows runtime package CI smoke contract ok\n'
