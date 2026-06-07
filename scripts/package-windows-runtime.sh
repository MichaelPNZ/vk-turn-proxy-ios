#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ANDROID_HOME="${ANDROID_HOME:-"$HOME/Library/Android/sdk"}"
OUT_DIR="$ROOT_DIR/build/windows-package"
PKG_DIR="$OUT_DIR/vk-turn-proxy-windows"
ZIP="$OUT_DIR/vk-turn-proxy-windows-runtime.zip"

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v certutil.exe >/dev/null 2>&1; then
    certutil.exe -hashfile "$(cygpath -w "$file" 2>/dev/null || printf '%s' "$file")" SHA256 |
      awk 'NR == 2 { gsub(/[^0-9A-Fa-f]/, ""); print tolower($0) }'
  elif command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -NonInteractive -Command "(Get-FileHash -Algorithm SHA256 -Path '$file').Hash.ToLowerInvariant()"
  else
    echo "shasum, sha256sum, certutil.exe, or pwsh is required to hash $file" >&2
    return 1
  fi
}

cd "$ROOT_DIR"

ANDROID_HOME="$ANDROID_HOME" ./gradlew :desktopApp:distZip >/dev/null
scripts/build-windows-service.sh >/dev/null

rm -rf "$PKG_DIR"
mkdir -p "$PKG_DIR/bin" "$PKG_DIR/app" "$PKG_DIR/config" "$PKG_DIR/lib"

cp "$ROOT_DIR/build/windows/vk-turn-proxy-windows-service.exe" "$PKG_DIR/bin/"
cp "$ROOT_DIR/desktopApp/build/distributions/desktopApp.zip" "$PKG_DIR/app/"

cat > "$PKG_DIR/README-WINDOWS.txt" <<'TXT'
VK Turn Proxy Windows runtime package

Contents:
- bin/vk-turn-proxy-windows-service.exe
- app/desktopApp.zip
- lib/common.ps1
- test-prereqs.ps1
- install-wintun.ps1
- install-service.ps1
- uninstall-service.ps1
- start-tunnel.ps1
- stop-tunnel.ps1
- status-tunnel.ps1
- export-logs.ps1
- smoke-windows-runtime.ps1
- run-console.ps1
- config/start-request.example.json

Runtime prerequisites:
- Windows 10/11 x64.
- Administrator shell for service install and adapter setup.
- wintun.dll must be placed next to bin/vk-turn-proxy-windows-service.exe or in C:\Windows\System32.
  Run .\install-wintun.ps1 to download the official signed Wintun 0.14.1 DLL
  from https://www.wintun.net/builds/wintun-0.14.1.zip with SHA-256 verification.
- Generate a real start-request.json with desktopApp:
  .\desktopApp\bin\desktopApp.bat windows-start-request --profile-file .\profile.txt --out .\start-request.json
- Or use the desktop window: select bin\vk-turn-proxy-windows-service.exe,
  paste/import a profile, validate it, then use Start / Status / Stop.

Smoke flow:
1. Unpack app/desktopApp.zip.
2. Run .\install-wintun.ps1, or copy an official wintun.dll into bin/.
3. Run prerequisite check:
   powershell -ExecutionPolicy Bypass -File .\test-prereqs.ps1
4. Generate config/start-request.json from the desktop app.
5. Full packaged service smoke with evidence export:
   powershell -ExecutionPolicy Bypass -File .\smoke-windows-runtime.ps1
6. Quick console smoke:
   powershell -ExecutionPolicy Bypass -File .\run-console.ps1
7. Manual service smoke:
   powershell -ExecutionPolicy Bypass -File .\install-service.ps1
   powershell -ExecutionPolicy Bypass -File .\start-tunnel.ps1
   powershell -ExecutionPolicy Bypass -File .\status-tunnel.ps1
   powershell -ExecutionPolicy Bypass -File .\export-logs.ps1
   powershell -ExecutionPolicy Bypass -File .\stop-tunnel.ps1
8. Desktop-managed service smoke:
   .\desktopApp\bin\desktopApp.bat
   Use Browse to select bin\vk-turn-proxy-windows-service.exe, import a profile,
   validate it, then use Start / Status / Stop.
9. Confirm status.json reaches "wireguard_attached" while running and "stopped" after stop.
TXT

cat > "$PKG_DIR/config/start-request.example.json" <<'JSON'
{
  "schemaVersion": 1,
  "serviceName": "VKTurnProxyTunnel",
  "adapterName": "VK Turn Proxy",
  "profileId": "replace-with-profile-id",
  "profileName": "Replace with profile name",
  "peerAddress": "142.252.220.91:56004",
  "interfaceAddress": "10.88.0.2/32",
  "dnsServers": ["1.1.1.1"],
  "allowedIps": ["0.0.0.0/0"],
  "wireGuardUapi": "replace with generated WireGuard UAPI",
  "proxyJson": "{\"peer_addr\":\"142.252.220.91:56004\",\"vk_link\":\"https://vk.com/call/join/replace\",\"num_conns\":10,\"use_dtls\":true,\"use_udp\":false,\"use_srtp\":true,\"use_wrap_a\":false}"
}
JSON

cat > "$PKG_DIR/lib/common.ps1" <<'PS1'
$ErrorActionPreference = "Stop"

function Get-VKTurnRoot {
  return (Split-Path -Parent $PSScriptRoot)
}

function Get-VKTurnServiceName {
  return "VKTurnProxyTunnel"
}

function Get-VKTurnProgramData {
  return "C:\ProgramData\VKTurnProxy"
}

function Get-VKTurnServiceExe {
  $root = Get-VKTurnRoot
  $exe = Join-Path $root "bin\vk-turn-proxy-windows-service.exe"
  if (!(Test-Path $exe)) {
    throw "Missing service executable: $exe"
  }
  return $exe
}

function Get-VKTurnRequestPath {
  $root = Get-VKTurnRoot
  return (Join-Path $root "config\start-request.json")
}

function Get-VKTurnStatusPath {
  return (Join-Path (Get-VKTurnProgramData) "status.json")
}

function Get-VKTurnLogPath {
  return (Join-Path (Get-VKTurnProgramData) "service.log")
}

function Assert-VKTurnAdmin {
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $principal = New-Object Security.Principal.WindowsPrincipal($identity)
  if (!$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Administrator PowerShell is required for service install/start and Wintun route/DNS setup."
  }
}

function Assert-VKTurnWintun {
  $root = Get-VKTurnRoot
  $local = Join-Path $root "bin\wintun.dll"
  $system = Join-Path $env:WINDIR "System32\wintun.dll"
  if (!(Test-Path $local) -and !(Test-Path $system)) {
    throw "wintun.dll not found. Run .\install-wintun.ps1, or place it next to bin\vk-turn-proxy-windows-service.exe or in C:\Windows\System32."
  }
}

function Assert-VKTurnRequest {
  $request = Get-VKTurnRequestPath
  if (!(Test-Path $request)) {
    throw "Missing $request. Generate it with desktopApp windows-start-request or the desktop UI."
  }
}

function Ensure-VKTurnProgramData {
  New-Item -ItemType Directory -Force -Path (Get-VKTurnProgramData) | Out-Null
}

function Test-VKTurnServiceExists {
  $serviceName = Get-VKTurnServiceName
  $svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
  return ($null -ne $svc)
}

function Get-VKTurnServiceBinPath {
  $exe = Get-VKTurnServiceExe
  $status = Get-VKTurnStatusPath
  $log = Get-VKTurnLogPath
  return "`"$exe`" -mode service -status-file `"$status`" -logfile `"$log`""
}

function Invoke-VKTurnSc {
  param([Parameter(ValueFromRemainingArguments = $true)][string[]]$Args)
  & sc.exe @Args
  if ($LASTEXITCODE -ne 0) {
    throw "sc.exe $($Args -join ' ') failed with exit code $LASTEXITCODE"
  }
}

function Start-VKTurnServiceIfNeeded {
  $serviceName = Get-VKTurnServiceName
  if (!(Test-VKTurnServiceExists)) {
    throw "Windows service $serviceName is not installed. Run install-service.ps1 first."
  }
  $svc = Get-Service -Name $serviceName
  if ($svc.Status -ne "Running") {
    Start-Service -Name $serviceName
    $svc.WaitForStatus("Running", [TimeSpan]::FromSeconds(15))
  }
}
PS1

cat > "$PKG_DIR/test-prereqs.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

Assert-VKTurnAdmin
$exe = Get-VKTurnServiceExe
Assert-VKTurnWintun

$desktopZip = Join-Path (Get-VKTurnRoot) "app\desktopApp.zip"
if (!(Test-Path $desktopZip)) {
  throw "Missing desktop distribution zip: $desktopZip"
}

Write-Host "Prerequisites OK"
Write-Host "Service executable: $exe"
Write-Host "Desktop zip: $desktopZip"
Write-Host "Service installed: $(Test-VKTurnServiceExists)"
PS1

cat > "$PKG_DIR/install-wintun.ps1" <<'PS1'
param(
  [string]$SourceZip = "",
  [switch]$Force
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

$Version = "0.14.1"
$DownloadUrl = "https://www.wintun.net/builds/wintun-$Version.zip"
$ExpectedSha256 = "07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51"

function Test-Sha256 {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Expected
  )
  $actual = (Get-FileHash -Algorithm SHA256 -Path $Path).Hash.ToLowerInvariant()
  if ($actual -ne $Expected.ToLowerInvariant()) {
    throw "SHA-256 mismatch for $Path. Expected $Expected, got $actual"
  }
  return $actual
}

$root = Get-VKTurnRoot
$bin = Join-Path $root "bin"
$target = Join-Path $bin "wintun.dll"

if ((Test-Path $target) -and !$Force) {
  Write-Host "wintun.dll already exists: $target"
  Write-Host "Use -Force to replace it."
  exit 0
}

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("vkturn-wintun-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null
try {
  $zip = if ($SourceZip -ne "") {
    if (!(Test-Path $SourceZip)) {
      throw "SourceZip does not exist: $SourceZip"
    }
    (Resolve-Path $SourceZip).Path
  } else {
    $downloaded = Join-Path $tempRoot "wintun-$Version.zip"
    Write-Host "Downloading $DownloadUrl"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloaded
    $downloaded
  }

  $sha = Test-Sha256 -Path $zip -Expected $ExpectedSha256
  Write-Host "Verified Wintun ZIP SHA-256: $sha"

  $extractDir = Join-Path $tempRoot "extract"
  Expand-Archive -Path $zip -DestinationPath $extractDir -Force

  $dll = Join-Path $extractDir "wintun\bin\amd64\wintun.dll"
  if (!(Test-Path $dll)) {
    throw "Expected Wintun DLL not found inside ZIP: wintun\bin\amd64\wintun.dll"
  }

  New-Item -ItemType Directory -Force -Path $bin | Out-Null
  Copy-Item -Force $dll $target

  $license = Join-Path $extractDir "wintun\LICENSE.txt"
  if (Test-Path $license) {
    Copy-Item -Force $license (Join-Path $bin "wintun.LICENSE.txt")
  }

  Write-Host "Installed $target"
} finally {
  Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
}
PS1

cat > "$PKG_DIR/run-console.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

Assert-VKTurnAdmin
Assert-VKTurnWintun
Assert-VKTurnRequest
$Root = Get-VKTurnRoot
$Exe = Get-VKTurnServiceExe
$Request = Get-VKTurnRequestPath
$Status = Join-Path $Root "config\status.json"
& $Exe -mode validate -request $Request
& $Exe -mode run-console -request $Request -status-file $Status -logfile (Join-Path $Root "config\service.log")
PS1

cat > "$PKG_DIR/install-service.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

Assert-VKTurnAdmin
Assert-VKTurnWintun
Ensure-VKTurnProgramData

$serviceName = Get-VKTurnServiceName
$binPath = Get-VKTurnServiceBinPath

if (Test-VKTurnServiceExists) {
  $svc = Get-Service -Name $serviceName
  if ($svc.Status -ne "Stopped") {
    Stop-Service -Name $serviceName -Force
    $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
  }
  Invoke-VKTurnSc config $serviceName binPath= $binPath start= demand DisplayName= "VK Turn Proxy Tunnel"
  Write-Host "Updated existing $serviceName service."
} else {
  Invoke-VKTurnSc create $serviceName binPath= $binPath start= demand DisplayName= "VK Turn Proxy Tunnel"
  Write-Host "Installed $serviceName service."
}

Invoke-VKTurnSc description $serviceName "VK Turn Proxy privileged tunnel service"
Write-Host "Service binary: $binPath"
Write-Host "Start service with: powershell -ExecutionPolicy Bypass -File .\start-tunnel.ps1"
PS1

cat > "$PKG_DIR/start-tunnel.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

Assert-VKTurnAdmin
Assert-VKTurnWintun
Assert-VKTurnRequest
Ensure-VKTurnProgramData

$Exe = Get-VKTurnServiceExe
$Request = Get-VKTurnRequestPath
Copy-Item -Force $Request (Join-Path (Get-VKTurnProgramData) "start-request.json")
Start-VKTurnServiceIfNeeded
& $Exe -mode control-start -request $Request
PS1

cat > "$PKG_DIR/status-tunnel.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

$Exe = Get-VKTurnServiceExe
$serviceName = Get-VKTurnServiceName
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $svc -and $svc.Status -eq "Running") {
  & $Exe -mode control-status
  exit $LASTEXITCODE
}

$status = Get-VKTurnStatusPath
if (Test-Path $status) {
  Get-Content -Raw $status
} else {
  Write-Host "{`"ok`":true,`"status`":{`"state`":`"service_not_running`"}}"
}
PS1

cat > "$PKG_DIR/export-logs.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

$Root = Get-VKTurnRoot
$Exe = Get-VKTurnServiceExe
$Out = Join-Path $Root "config\diagnostics.json"
$serviceName = Get-VKTurnServiceName
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $svc -and $svc.Status -eq "Running") {
  & $Exe -mode control-logs | Tee-Object -FilePath $Out
  exit $LASTEXITCODE
}

$statusPath = Get-VKTurnStatusPath
$logPath = Get-VKTurnLogPath
$statusJson = if (Test-Path $statusPath) { Get-Content -Raw $statusPath } else { "" }
$logTail = if (Test-Path $logPath) { (Get-Content $logPath -Tail 300 | Out-String) } else { "" }
$offline = [ordered]@{
  ok = $true
  serviceRunning = $false
  logs = [ordered]@{
    statusPath = $statusPath
    statusJson = $statusJson
    logPath = $logPath
    logTail = $logTail
    maxBytes = 0
    truncated = $false
  }
}
$offline | ConvertTo-Json -Depth 6 | Tee-Object -FilePath $Out
Write-Host "Wrote $Out"
PS1

cat > "$PKG_DIR/stop-tunnel.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

$Exe = Get-VKTurnServiceExe
$serviceName = Get-VKTurnServiceName
$svc = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
if ($null -ne $svc -and $svc.Status -eq "Running") {
  & $Exe -mode control-stop
} else {
  Write-Host "Service $serviceName is not running."
}
PS1

cat > "$PKG_DIR/uninstall-service.ps1" <<'PS1'
$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

Assert-VKTurnAdmin
$serviceName = Get-VKTurnServiceName
$Exe = Get-VKTurnServiceExe
try {
  & $Exe -mode control-stop | Out-Null
} catch {
  Write-Host "Tunnel control stop skipped: $($_.Exception.Message)"
}
if (Test-VKTurnServiceExists) {
  $svc = Get-Service -Name $serviceName
  if ($svc.Status -ne "Stopped") {
    Stop-Service -Name $serviceName -Force
    $svc.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(15))
  }
  Invoke-VKTurnSc delete $serviceName
  Write-Host "Deleted $serviceName."
} else {
  Write-Host "Service $serviceName is not installed."
}
PS1

cat > "$PKG_DIR/smoke-windows-runtime.ps1" <<'PS1'
param(
  [int]$TimeoutSeconds = 60,
  [switch]$KeepRunning
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot\lib\common.ps1"

function New-EvidenceDirectory {
  $root = Get-VKTurnRoot
  $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
  $dir = Join-Path $root "config\windows-smoke-$stamp"
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $dir
}

function Save-TextEvidence {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )
  $Text | Out-File -FilePath $Path -Encoding UTF8
}

function Read-StatusState {
  $statusPath = Get-VKTurnStatusPath
  if (!(Test-Path $statusPath)) {
    return ""
  }
  try {
    $status = Get-Content -Raw $statusPath | ConvertFrom-Json
    return [string]$status.state
  } catch {
    return ""
  }
}

function Wait-ForState {
  param(
    [Parameter(Mandatory=$true)][string]$Expected,
    [Parameter(Mandatory=$true)][int]$TimeoutSeconds
  )
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $state = Read-StatusState
    if ($state -eq $Expected) {
      return $true
    }
    if ($state -eq "failed" -or $state -eq "invalid_request" -or $state -eq "invalid_proxy_json" -or $state -eq "invalid_proxy_config" -or $state -eq "bootstrap_failed" -or $state -eq "wireguard_attach_failed") {
      return $false
    }
    Start-Sleep -Seconds 2
  }
  return $false
}

$evidenceDir = New-EvidenceDirectory
$transcript = Join-Path $evidenceDir "transcript.txt"
Start-Transcript -Path $transcript -Force | Out-Null

$failed = $false
$validateOk = $false
$serviceInstalled = $false
$wireguardAttachedObserved = $false
$programDataStatusCaptured = $false
$stopVerified = $false
try {
  Write-Host "VK Turn Proxy Windows runtime smoke"
  Write-Host "Evidence: $evidenceDir"

  Assert-VKTurnAdmin
  Assert-VKTurnWintun
  Assert-VKTurnRequest
  Ensure-VKTurnProgramData

  $exe = Get-VKTurnServiceExe
  $request = Get-VKTurnRequestPath
  $statusPath = Get-VKTurnStatusPath
  $logPath = Get-VKTurnLogPath

  Write-Host "Validating start request"
  & $exe -mode validate -request $request | Tee-Object -FilePath (Join-Path $evidenceDir "validate.txt")
  if ($LASTEXITCODE -ne 0) {
    throw "Start request validation failed with exit code $LASTEXITCODE"
  }
  $validateOk = $true

  Write-Host "Installing or updating service"
  & "$PSScriptRoot\install-service.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "install-service.txt")
  $serviceInstalled = Test-VKTurnServiceExists
  if (!$serviceInstalled) {
    throw "Service was not installed after install-service.ps1"
  }

  Write-Host "Starting tunnel"
  & "$PSScriptRoot\start-tunnel.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "start-tunnel.txt")

  if (!(Wait-ForState -Expected "wireguard_attached" -TimeoutSeconds $TimeoutSeconds)) {
    $state = Read-StatusState
    throw "Timed out waiting for status state wireguard_attached. Last state: $state"
  }
  $wireguardAttachedObserved = $true

  Write-Host "wireguard_attached observed"
  & "$PSScriptRoot\status-tunnel.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "status-running.json")
  & "$PSScriptRoot\export-logs.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "export-logs-running.txt")

  if (Test-Path $statusPath) {
    Copy-Item -Force $statusPath (Join-Path $evidenceDir "programdata-status-running.json")
    $programDataStatusCaptured = $true
  }
  if (Test-Path $logPath) {
    Copy-Item -Force $logPath (Join-Path $evidenceDir "programdata-service.log")
  }

  if (!$KeepRunning) {
    Write-Host "Stopping tunnel"
    & "$PSScriptRoot\stop-tunnel.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "stop-tunnel.txt")
    if (!(Wait-ForState -Expected "stopped" -TimeoutSeconds 20)) {
      $state = Read-StatusState
      throw "Timed out waiting for status state stopped after stop. Last state: $state"
    }
    $stopVerified = $true
    & "$PSScriptRoot\status-tunnel.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "status-stopped.json")
  } else {
    Write-Host "KeepRunning was set; leaving tunnel running."
  }

  $summary = [ordered]@{
    ok = $true
    result = "passed"
    evidenceType = "windows_runtime_smoke"
    evidenceDir = $evidenceDir
    statusPath = $statusPath
    logPath = $logPath
    keepRunning = [bool]$KeepRunning
    validateOk = $validateOk
    serviceInstalled = $serviceInstalled
    wireguardAttachedObserved = $wireguardAttachedObserved
    programDataStatusCaptured = $programDataStatusCaptured
    stopVerified = $stopVerified
    completedAt = (Get-Date).ToUniversalTime().ToString("o")
  }
  $summary | ConvertTo-Json -Depth 4 | Tee-Object -FilePath (Join-Path $evidenceDir "summary.json")
} catch {
  $failed = $true
  $message = $_.Exception.Message
  Write-Host "Smoke failed: $message"
  Save-TextEvidence -Path (Join-Path $evidenceDir "failure.txt") -Text $message
  try {
    & "$PSScriptRoot\status-tunnel.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "status-failure.json")
  } catch {
    Save-TextEvidence -Path (Join-Path $evidenceDir "status-failure-error.txt") -Text $_.Exception.Message
  }
  try {
    & "$PSScriptRoot\export-logs.ps1" | Tee-Object -FilePath (Join-Path $evidenceDir "export-logs-failure.txt")
  } catch {
    Save-TextEvidence -Path (Join-Path $evidenceDir "export-logs-failure-error.txt") -Text $_.Exception.Message
  }
  if (!$KeepRunning) {
    try {
      & "$PSScriptRoot\stop-tunnel.ps1" | Out-Null
    } catch {
      Save-TextEvidence -Path (Join-Path $evidenceDir "stop-failure-error.txt") -Text $_.Exception.Message
    }
  }
} finally {
  Stop-Transcript | Out-Null
}

if ($failed) {
  Write-Host "Evidence: $evidenceDir"
  exit 1
}

Write-Host "Windows runtime smoke passed. Evidence: $evidenceDir"
PS1

rm -f "$ZIP"
if command -v zip >/dev/null 2>&1; then
  (cd "$OUT_DIR" && zip -qr "$ZIP" "vk-turn-proxy-windows")
elif command -v pwsh >/dev/null 2>&1; then
  (cd "$OUT_DIR" && pwsh -NoProfile -NonInteractive -Command \
    "Compress-Archive -Path 'vk-turn-proxy-windows' -DestinationPath 'vk-turn-proxy-windows-runtime.zip' -Force")
elif command -v powershell.exe >/dev/null 2>&1; then
  (cd "$OUT_DIR" && powershell.exe -NoProfile -NonInteractive -Command \
    "Compress-Archive -Path 'vk-turn-proxy-windows' -DestinationPath 'vk-turn-proxy-windows-runtime.zip' -Force")
else
  echo "zip or PowerShell Compress-Archive is required to create $ZIP" >&2
  exit 1
fi

sha256="$(sha256_file "$ZIP")"
printf 'package=%s\n' "$ZIP"
printf 'sha256=%s\n' "$sha256"
