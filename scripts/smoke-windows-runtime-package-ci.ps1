param(
  [string]$RootDir = "",
  [string]$RuntimeZip = "",
  [string]$EvidenceDir = ""
)

$ErrorActionPreference = "Stop"

function Resolve-RootDir {
  if ($RootDir -ne "") {
    return (Resolve-Path $RootDir).Path
  }
  return (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
}

function Require-File {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (!(Test-Path -Path $Path -PathType Leaf)) {
    throw "Missing file: $Path"
  }
  return (Resolve-Path $Path).Path
}

function Require-Dir {
  param([Parameter(Mandatory=$true)][string]$Path)
  if (!(Test-Path -Path $Path -PathType Container)) {
    throw "Missing directory: $Path"
  }
  return (Resolve-Path $Path).Path
}

function Invoke-NativeChecked {
  param(
    [Parameter(Mandatory=$true)][string]$Name,
    [Parameter(Mandatory=$true)][string]$OutFile,
    [Parameter(Mandatory=$true)][string]$Command,
    [Parameter(ValueFromRemainingArguments=$true)][string[]]$Args
  )
  Write-Host "==> $Name"
  & $Command @Args 2>&1 | Tee-Object -FilePath $OutFile
  if ($LASTEXITCODE -ne 0) {
    throw "$Name failed with exit code $LASTEXITCODE"
  }
}

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
  [System.Runtime.InteropServices.OSPlatform]::Windows
)
if (!$isWindowsHost) {
  throw "This package smoke must run on a Windows host."
}

$root = Resolve-RootDir
if ($RuntimeZip -eq "") {
  $RuntimeZip = Join-Path $root "build\windows-package\vk-turn-proxy-windows-runtime.zip"
}
$runtimeZipPath = Require-File -Path $RuntimeZip

if ($EvidenceDir -eq "") {
  $EvidenceDir = Join-Path $root "build\evidence\windows-runtime-package-ci-smoke"
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$evidencePath = (Resolve-Path $EvidenceDir).Path

$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ("vkturn-windows-package-ci-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

try {
  Expand-Archive -Path $runtimeZipPath -DestinationPath $tempRoot -Force
  $pkgRoot = Require-Dir -Path (Join-Path $tempRoot "vk-turn-proxy-windows")

  $serviceExe = Require-File -Path (Join-Path $pkgRoot "bin\vk-turn-proxy-windows-service.exe")
  $desktopZip = Require-File -Path (Join-Path $pkgRoot "app\desktopApp.zip")
  Require-File -Path (Join-Path $pkgRoot "README-WINDOWS.txt") | Out-Null
  Require-File -Path (Join-Path $pkgRoot "config\start-request.example.json") | Out-Null
  Require-File -Path (Join-Path $pkgRoot "smoke-windows-runtime.ps1") | Out-Null
  Require-File -Path (Join-Path $pkgRoot "install-wintun.ps1") | Out-Null
  Require-File -Path (Join-Path $pkgRoot "lib\common.ps1") | Out-Null

  $desktopExtract = Join-Path $tempRoot "desktopApp"
  Expand-Archive -Path $desktopZip -DestinationPath $desktopExtract -Force
  $desktopBat = Require-File -Path (Join-Path $desktopExtract "desktopApp\bin\desktopApp.bat")

  $profilePath = Join-Path $evidencePath "profile-full-backup.json"
  @'
{
  "version": 1,
  "type": "full",
  "exported_at": 1780690000,
  "settings": {
    "privateKey": "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=",
    "peerPublicKey": "AgMEBQYHCAkKCwwNDg8QERITFBUWFxgZGhscHR4fICE=",
    "presharedKey": "AwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8gISI=",
    "tunnelAddress": "10.88.0.2/32",
    "dnsServers": "1.1.1.1",
    "allowedIPs": "0.0.0.0/0",
    "vkLink": "https://vk.com/call/join/windowsPackageCiSmoke",
    "peerAddress": "142.252.220.91:56004",
    "useDTLS": true,
    "numConnections": 10,
    "useSrtp": true,
    "useUDP": false,
    "useWrapA": false
  }
}
'@ | Set-Content -Path $profilePath -Encoding utf8

  $requestPath = Join-Path $evidencePath "start-request.json"
  Invoke-NativeChecked `
    -Name "desktop windows-start-request" `
    -OutFile (Join-Path $evidencePath "desktop-start-request.txt") `
    -Command $desktopBat `
    "windows-start-request" "--profile-file" $profilePath "--out" $requestPath

  Require-File -Path $requestPath | Out-Null

  Invoke-NativeChecked `
    -Name "desktop validate" `
    -OutFile (Join-Path $evidencePath "desktop-validate.txt") `
    -Command $desktopBat `
    "validate" "--profile-file" $profilePath

  Invoke-NativeChecked `
    -Name "desktop windows-preflight" `
    -OutFile (Join-Path $evidencePath "desktop-windows-preflight.txt") `
    -Command $desktopBat `
    "windows-preflight" "--service-exe" $serviceExe

  Invoke-NativeChecked `
    -Name "desktop windows-service-commands" `
    -OutFile (Join-Path $evidencePath "desktop-windows-service-commands.txt") `
    -Command $desktopBat `
    "windows-service-commands" "--service-exe" $serviceExe

  Invoke-NativeChecked `
    -Name "service validate" `
    -OutFile (Join-Path $evidencePath "service-validate.txt") `
    -Command $serviceExe `
    "-mode" "validate" "-request" $requestPath

  $summary = [ordered]@{
    ok = $true
    result = "passed"
    evidenceType = "windows_runtime_package_ci_smoke"
    host = $env:COMPUTERNAME
    runtimeZip = $runtimeZipPath
    packageRoot = $pkgRoot
    serviceExeExists = $true
    desktopCliOk = $true
    desktopPreflightOk = $true
    serviceValidateOk = $true
    generatedStartRequest = $requestPath
    createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
  }
  $summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evidencePath "summary.json") -Encoding utf8
  Write-Host "windows runtime package CI smoke passed"
  Write-Host "evidence=$evidencePath"
}
finally {
  Remove-Item -Recurse -Force $tempRoot -ErrorAction SilentlyContinue
}
