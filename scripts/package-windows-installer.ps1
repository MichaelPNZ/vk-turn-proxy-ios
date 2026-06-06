param(
  [string]$RuntimeZip = "",
  [string]$Version = "1.0.0",
  [string]$OutDir = "",
  [string]$InnoSetupCompiler = "",
  [string]$SignTool = "",
  [string]$SignCertSha1 = "",
  [string]$TimestampUrl = "http://timestamp.digicert.com"
)

$ErrorActionPreference = "Stop"

$RootDir = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ([string]::IsNullOrWhiteSpace($RuntimeZip)) {
  $RuntimeZip = Join-Path $RootDir "build\windows-package\vk-turn-proxy-windows-runtime.zip"
}
if ([string]::IsNullOrWhiteSpace($OutDir)) {
  $OutDir = Join-Path $RootDir "build\windows-installer"
}
if ([string]::IsNullOrWhiteSpace($InnoSetupCompiler)) {
  $InnoSetupCompiler = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
}

$RuntimeZip = (Resolve-Path $RuntimeZip).Path
$Template = Join-Path $RootDir "packaging\windows\inno\vk-turn-proxy.iss.tpl"
if (!(Test-Path $Template)) {
  throw "Missing installer template: $Template"
}
if (!(Test-Path $InnoSetupCompiler)) {
  throw "Inno Setup compiler not found: $InnoSetupCompiler. Install Inno Setup 6 or pass -InnoSetupCompiler."
}

$StageRoot = Join-Path $RootDir "build\windows-installer-stage"
$RuntimeStage = Join-Path $StageRoot "runtime"
$SourceDir = Join-Path $StageRoot "source"
Remove-Item -Recurse -Force $StageRoot -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $RuntimeStage, $SourceDir, $OutDir | Out-Null

Expand-Archive -Force -Path $RuntimeZip -DestinationPath $RuntimeStage
$RuntimeDir = Join-Path $RuntimeStage "vk-turn-proxy-windows"
if (!(Test-Path $RuntimeDir)) {
  throw "Runtime zip does not contain vk-turn-proxy-windows root: $RuntimeZip"
}

Copy-Item -Recurse -Force (Join-Path $RuntimeDir "*") $SourceDir
$DesktopZip = Join-Path $SourceDir "app\desktopApp.zip"
if (!(Test-Path $DesktopZip)) {
  throw "Runtime package does not contain app\desktopApp.zip"
}

$DesktopOut = Join-Path $SourceDir "desktopApp"
Remove-Item -Recurse -Force $DesktopOut -ErrorAction SilentlyContinue
Expand-Archive -Force -Path $DesktopZip -DestinationPath $SourceDir
Remove-Item -Force $DesktopZip

if (!(Test-Path (Join-Path $SourceDir "desktopApp\bin\desktopApp.bat"))) {
  throw "Expanded desktopApp is missing bin\desktopApp.bat"
}
if (!(Test-Path (Join-Path $SourceDir "bin\vk-turn-proxy-windows-service.exe"))) {
  throw "Runtime package is missing bin\vk-turn-proxy-windows-service.exe"
}

$InstallerBaseName = "vk-turn-proxy-windows-$Version-setup"
$IssPath = Join-Path $StageRoot "vk-turn-proxy.generated.iss"
$Iss = Get-Content -Raw $Template
$Iss = $Iss.Replace("{APP_VERSION}", $Version)
$Iss = $Iss.Replace("{SOURCE_DIR}", $SourceDir)
$Iss = $Iss.Replace("{OUTPUT_DIR}", $OutDir)
$Iss = $Iss.Replace("{INSTALLER_BASE_NAME}", $InstallerBaseName)
Set-Content -Encoding UTF8 -Path $IssPath -Value $Iss

& $InnoSetupCompiler $IssPath
if ($LASTEXITCODE -ne 0) {
  throw "Inno Setup failed with exit code $LASTEXITCODE"
}

$InstallerPath = Join-Path $OutDir "$InstallerBaseName.exe"
if (!(Test-Path $InstallerPath)) {
  throw "Expected installer was not created: $InstallerPath"
}

if (![string]::IsNullOrWhiteSpace($SignCertSha1)) {
  if ([string]::IsNullOrWhiteSpace($SignTool)) {
    $SignTool = "signtool.exe"
  }
  & $SignTool sign /fd SHA256 /sha1 $SignCertSha1 /tr $TimestampUrl /td SHA256 $InstallerPath
  if ($LASTEXITCODE -ne 0) {
    throw "signtool failed with exit code $LASTEXITCODE"
  }
}

$Hash = (Get-FileHash -Algorithm SHA256 $InstallerPath).Hash.ToLowerInvariant()
Write-Host "installer=$InstallerPath"
Write-Host "sha256=$Hash"
