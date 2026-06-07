param(
  [string]$RootDir = "",
  [string]$RuntimeZip = "",
  [string]$Version = "",
  [string]$EvidenceDir = "",
  [string]$InnoSetupCompiler = ""
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

function Save-Text {
  param(
    [Parameter(Mandatory=$true)][string]$Path,
    [Parameter(Mandatory=$true)][string]$Text
  )
  $Text | Set-Content -Path $Path -Encoding utf8
}

function Invoke-PackageInstaller {
  param(
    [Parameter(Mandatory=$true)][string]$OutFile,
    [Parameter(Mandatory=$true)][string]$RuntimeZipPath,
    [Parameter(Mandatory=$true)][string]$InstallerVersion,
    [Parameter(Mandatory=$true)][string]$Compiler
  )
  $args = @(
    "-NoProfile",
    "-NonInteractive",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    (Join-Path $root "scripts\package-windows-installer.ps1"),
    "-RuntimeZip",
    $RuntimeZipPath,
    "-Version",
    $InstallerVersion
  )
  if ($Compiler -ne "") {
    $args += @("-InnoSetupCompiler", $Compiler)
  }
  & pwsh @args 2>&1 | Tee-Object -FilePath $OutFile
  if ($LASTEXITCODE -ne 0) {
    throw "package-windows-installer.ps1 failed with exit code $LASTEXITCODE"
  }
}

$isWindowsHost = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
  [System.Runtime.InteropServices.OSPlatform]::Windows
)
if (!$isWindowsHost) {
  throw "This installer package smoke must run on a Windows host."
}

$root = Resolve-RootDir
if ($RuntimeZip -eq "") {
  $RuntimeZip = Join-Path $root "build\windows-package\vk-turn-proxy-windows-runtime.zip"
}
$runtimeZipPath = Require-File -Path $RuntimeZip

if ($Version -eq "") {
  $tag = $env:TAG
  if ($tag -eq "") {
    $tag = "v1.0-build0"
  }
  $Version = $tag -replace "^v", ""
}

if ($EvidenceDir -eq "") {
  $EvidenceDir = Join-Path $root "build\evidence\windows-installer-package-ci-smoke"
}
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$evidencePath = (Resolve-Path $EvidenceDir).Path

$transcript = Join-Path $evidencePath "package-windows-installer.txt"
Invoke-PackageInstaller `
  -OutFile $transcript `
  -RuntimeZipPath $runtimeZipPath `
  -InstallerVersion $Version `
  -Compiler $InnoSetupCompiler

$installerLine = Select-String -Path $transcript -Pattern '^installer=' | Select-Object -Last 1
if ($null -eq $installerLine) {
  throw "package transcript does not contain installer=<path>: $transcript"
}
$installerPath = Require-File -Path ($installerLine.Line -replace '^installer=', '')
$hash = (Get-FileHash -Algorithm SHA256 -Path $installerPath).Hash.ToLowerInvariant()
$signature = Get-AuthenticodeSignature -FilePath $installerPath
$signatureStatus = [string]$signature.Status

Save-Text -Path (Join-Path $evidencePath "installer-sha256.txt") -Text "$hash  $(Split-Path -Leaf $installerPath)"
Save-Text -Path (Join-Path $evidencePath "authenticode-signature.txt") -Text (
  "Status: $signatureStatus`nSignerCertificate: $($signature.SignerCertificate.Subject)`nPath: $installerPath"
)

$summary = [ordered]@{
  ok = $true
  result = "passed"
  evidenceType = "windows_installer_package_ci_smoke"
  host = $env:COMPUTERNAME
  version = $Version
  runtimeZip = $runtimeZipPath
  installer = $installerPath
  installerSha256 = $hash
  installerBuilt = $true
  signatureStatus = $signatureStatus
  signed = ($signatureStatus -eq "Valid")
  createdAtUtc = (Get-Date).ToUniversalTime().ToString("o")
}
$summary | ConvertTo-Json -Depth 5 | Set-Content -Path (Join-Path $evidencePath "summary.json") -Encoding utf8

Write-Host "windows installer package CI smoke passed"
Write-Host "installer=$installerPath"
Write-Host "sha256=$hash"
Write-Host "signatureStatus=$signatureStatus"
Write-Host "evidence=$evidencePath"
