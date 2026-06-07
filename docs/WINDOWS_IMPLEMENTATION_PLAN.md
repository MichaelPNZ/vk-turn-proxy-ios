# Windows Implementation Plan

## Current State

The repository now contains a Windows-compatible desktop MVP module:

- module: `desktopApp`;
- runtime: Kotlin/JVM 17;
- UI toolkit: Swing using the host system look and feel;
- shared dependency: `:shared`;
- entrypoint: `com.vkturnproxy.desktop.DesktopAppKt`.

The MVP can:

- accept a full iOS backup JSON;
- accept a `vkturnproxy://import?data=...` connection link;
- parse legacy iOS formats through `LegacyIosConfig`;
- validate profile data through `ConfigValidator`;
- reuse `ProfileRuntimeMapper` for WireGuard UAPI/proxy JSON payloads;
- show peer, transport mode, connection count, DNS, allowed routes, and WireGuard config size;
- export the parsed runtime summary to clipboard;
- prepare a typed Windows service start request from a validated profile;
- discover/configure the Windows service executable path;
- call service `Start`, `Status`, `Logs`, and `Stop` controls from the desktop window;
- expose CLI commands for validation, Windows start-request export, Windows preflight, and Windows service install command generation.

The desktop MVP intentionally does not start a Windows tunnel directly from the UI. The privileged service executable now owns the runtime path: it can validate a request, run a console smoke, or listen for named-pipe start/stop/status commands when installed as a Windows service.

The repository also contains a first Windows service executable:

- command: `cmd/vk-turn-proxy-windows-service`;
- output: `build/windows/vk-turn-proxy-windows-service.exe`;
- package: `internal/windowstunnel`;
- modes:
  - `-mode validate`;
  - `-mode run-console`;
  - `-mode service`;
  - `-mode control-start`;
  - `-mode control-status`;
  - `-mode control-logs`;
  - `-mode control-stop`;
- validates `WindowsTunnelStartRequest`;
- starts VK/TURN bootstrap through the shared Go `pkg/proxy` runtime;
- creates/reuses a Wintun adapter through `wireguard/tun.CreateTUN` on Windows;
- applies interface address, DNS, and allowed routes through Windows `netsh`;
- applies WireGuard UAPI to a `wireguard/device.Device`;
- binds WireGuard traffic to the VK/TURN proxy through `turnbind.NewTURNBind`;
- writes status JSON;
- exposes named-pipe start/stop/status/log export control when the service is launched without `-request`;
- exposes a Windows Service Control Manager entrypoint when running on Windows.

The service executable now contains the Wintun/wireguard-go attach path, but it still needs runtime verification on a Windows host with Administrator rights and `wintun.dll` available beside the executable or in `System32`.

## Build

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :desktopApp:build
```

Artifacts:

- `desktopApp/build/distributions/desktopApp.zip`
- `desktopApp/build/distributions/desktopApp.tar`
- `desktopApp/build/libs/desktopApp.jar`
- `build/windows/vk-turn-proxy-windows-service.exe`
- `build/windows-package/vk-turn-proxy-windows-runtime.zip`
- `build/windows-installer/vk-turn-proxy-windows-<version>-setup.exe` when built on Windows with Inno Setup.

Build the Windows service executable:

```bash
scripts/build-windows-service.sh
```

Build the Windows runtime package:

```bash
scripts/package-windows-runtime.sh
```

Current runtime package:

- `build/windows-package/vk-turn-proxy-windows-runtime.zip`
- sha256 is recorded in the generated release checksum manifest because the package is rebuilt per release run.
- includes `lib/common.ps1`, `test-prereqs.ps1`, `install-wintun.ps1`, idempotent service install/update, service start/status/stop, offline log export helpers, and `smoke-windows-runtime.ps1` for one-command Windows host evidence collection.

Build the Windows EXE installer on a Windows host with Inno Setup 6:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows-installer.ps1 `
  -RuntimeZip .\build\windows-package\vk-turn-proxy-windows-runtime.zip `
  -Version 1.0.156
```

After the installer is copied or built under `build/windows-installer/`, the main release packager includes it automatically:

```bash
scripts/package-release-artifacts.sh v1.0-build159
```

Optional Authenticode signing:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\package-windows-installer.ps1 `
  -RuntimeZip .\build\windows-package\vk-turn-proxy-windows-runtime.zip `
  -Version 1.0.156 `
  -SignCertSha1 "<certificate-thumbprint>"
```

Run locally:

```bash
./gradlew :desktopApp:run
```

On Windows, unpack `desktopApp.zip` and run:

```powershell
.\desktopApp\bin\desktopApp.bat
```

CLI checks:

```powershell
.\desktopApp\bin\desktopApp.bat validate --profile-file .\profile.txt
.\desktopApp\bin\desktopApp.bat windows-start-request --profile-file .\profile.txt --out .\start-request.json
.\desktopApp\bin\desktopApp.bat windows-preflight --service-exe "C:\Program Files\VKTurnProxy\vkturnproxy-tunnel-service.exe"
.\desktopApp\bin\desktopApp.bat windows-service-commands --service-exe "C:\Program Files\VKTurnProxy\vkturnproxy-tunnel-service.exe"
.\desktopApp\bin\desktopApp.bat windows-control-start --service-exe "C:\Program Files\VKTurnProxy\vkturnproxy-tunnel-service.exe" --profile-file .\profile.txt
.\desktopApp\bin\desktopApp.bat windows-control-status --service-exe "C:\Program Files\VKTurnProxy\vkturnproxy-tunnel-service.exe"
.\desktopApp\bin\desktopApp.bat windows-control-logs --service-exe "C:\Program Files\VKTurnProxy\vkturnproxy-tunnel-service.exe"
.\desktopApp\bin\desktopApp.bat windows-control-stop --service-exe "C:\Program Files\VKTurnProxy\vkturnproxy-tunnel-service.exe"
```

Service executable checks:

```powershell
.\vk-turn-proxy-windows-service.exe -mode validate -request .\start-request.json
.\vk-turn-proxy-windows-service.exe -mode run-console -request .\start-request.json -status-file .\status.json
.\vk-turn-proxy-windows-service.exe -mode service -request "C:\ProgramData\VKTurnProxy\start-request.json" -status-file "C:\ProgramData\VKTurnProxy\status.json"
```

Managed service control checks:

```powershell
.\vk-turn-proxy-windows-service.exe -mode service -status-file "C:\ProgramData\VKTurnProxy\status.json"
.\vk-turn-proxy-windows-service.exe -mode control-start -request .\start-request.json
.\vk-turn-proxy-windows-service.exe -mode control-status
.\vk-turn-proxy-windows-service.exe -mode control-logs
.\vk-turn-proxy-windows-service.exe -mode control-stop
```

Runtime prerequisite:

- `wintun.dll` must be in the same directory as `vk-turn-proxy-windows-service.exe` or in `C:\Windows\System32`.
- The packaged `install-wintun.ps1` downloads official signed Wintun `0.14.1` from `https://www.wintun.net/builds/wintun-0.14.1.zip`, verifies SHA-256 `07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`, and copies `bin\amd64\wintun.dll` into `bin\wintun.dll`.
- Run PowerShell as Administrator for service install/start and Wintun route/DNS setup.

Packaged runtime smoke:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-wintun.ps1
powershell -ExecutionPolicy Bypass -File .\test-prereqs.ps1
powershell -ExecutionPolicy Bypass -File .\smoke-windows-runtime.ps1
```

`smoke-windows-runtime.ps1` validates prerequisites and `config\start-request.json`,
installs or updates `VKTurnProxyTunnel`, starts the tunnel, waits for
`wireguard_attached`, exports status/log evidence into
`config\windows-smoke-<timestamp>\`, and stops the tunnel unless `-KeepRunning`
is passed. Its `summary.json` must contain `ok=true` and
`evidenceType=windows_runtime_smoke`, plus `validateOk=true`,
`serviceInstalled=true`, `wireguardAttachedObserved=true`,
`programDataStatusCaptured=true`, `stopVerified=true`, and
`keepRunning=false`; use that directory as `WINDOWS_RUNTIME_SMOKE_EVIDENCE`
for `scripts/final-release-readiness.sh`.
Final readiness also requires `transcript.txt`, `validate.txt`,
`install-service.txt`, `start-tunnel.txt`, `status-running.json`,
`programdata-status-running.json`, `stop-tunnel.txt`, and
`status-stopped.json` from that evidence directory.

Manual packaged runtime smoke:

```powershell
powershell -ExecutionPolicy Bypass -File .\install-service.ps1
powershell -ExecutionPolicy Bypass -File .\start-tunnel.ps1
powershell -ExecutionPolicy Bypass -File .\status-tunnel.ps1
powershell -ExecutionPolicy Bypass -File .\export-logs.ps1
powershell -ExecutionPolicy Bypass -File .\stop-tunnel.ps1
powershell -ExecutionPolicy Bypass -File .\uninstall-service.ps1
```

`install-service.ps1` is idempotent: it creates or updates `VKTurnProxyTunnel`. `export-logs.ps1` writes `config\diagnostics.json` even if the service is not running, using the latest ProgramData status/log files when available.

After building/signing/installing the Inno Setup EXE on Windows, put the
installer transcript, signature verification, install smoke output, and
uninstall transcript into an evidence directory. Final readiness requires these
supporting files:

- `installer-build-transcript.txt`
- `authenticode-signature.txt`
- `installer-sha256.txt`
- `install-transcript.txt`
- `launch-or-service-smoke.txt`
- `uninstall-transcript.txt`

Then write the summary and append the installer-specific markers:

```powershell
bash scripts/write-smoke-evidence-summary.sh `
  windows_installer_smoke `
  build/evidence/windows-installer-<date>

@"
installer_built=1
signature_verified=1
installed_cleanly=1
launched_cleanly=1
uninstalled_cleanly=1
installer_sha256=<64-hex-sha256>
"@ | Add-Content build/evidence/windows-installer-<date>/summary.txt
```

Use that directory as `WINDOWS_INSTALLER_SMOKE_EVIDENCE`.
`authenticode-signature.txt` must include `Status: Valid`, and
`installer-sha256.txt` must contain the same SHA-256 as `installer_sha256`.

Local preflight from this repository:

```bash
ALLOW_EXTERNAL_BLOCKERS=1 \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  scripts/preflight-windows-desktop.sh
```

## Production Windows VPN Design

### Process Model

Use a split model:

- user app:
  - native Windows UI in a future production target;
  - imports and validates profiles through shared KMP logic;
  - sends start/stop/status requests to the service;
- privileged Windows service:
  - owns Wintun adapter and wireguard-go device lifecycle;
  - starts the Go TURN bridge;
  - applies WireGuard UAPI config;
  - protects TURN/VK control sockets from being routed into the tunnel;
  - writes logs and metrics;
  - exposes local named-pipe control API.

### Tunnel Options

Current first implementation:

1. Wintun adapter plus wireguard-go.
2. Keep WireGuardNT only as a future alternative if real Windows-host smoke proves that the current Wintun/wireguard-go path is not stable enough.

Avoid routing all service control traffic through the VPN adapter. The Windows service must exclude:

- VK HTTP/TLS bootstrap traffic;
- DNS fallback traffic;
- TURN UDP/TCP/SRTP traffic;
- service named-pipe control traffic.

### Shared Logic Boundary

KMP shared code should own:

- profile schema;
- legacy iOS import parsing;
- validation;
- runtime DTOs for profile/proxy/WireGuard config;
- diagnostics event schema.

Windows-specific code should own:

- `WindowsTunnelStartRequest` consumption;
- service installation;
- adapter creation/deletion;
- route/DNS application;
- socket route protection;
- Windows logging/event source;
- installer/signing.

## Next Windows Tasks

1. Run service runtime smoke on Windows:
   - run `install-wintun.ps1` or place `wintun.dll` next to `vk-turn-proxy-windows-service.exe`;
   - run `-mode validate`;
   - run `-mode run-console` as Administrator;
   - verify adapter creation, route/DNS application, WireGuard handshake, and cleanup.
2. Harden Windows route/DNS cleanup from real-host evidence.
3. Run desktop-managed service controls on a Windows host:
   - import current profile in the desktop window;
   - select `vk-turn-proxy-windows-service.exe`;
   - use Start / Status / Logs / Stop.
4. Build and sign the Windows EXE installer on a Windows host:
   - run `scripts/package-windows-installer.ps1`;
   - install the generated `vk-turn-proxy-windows-<version>-setup.exe`;
   - verify Start Menu shortcuts, desktop app launch, service install/uninstall, and optional Authenticode signature.
5. Run a full Windows smoke:
   - import current profile;
   - connect to `142.252.220.91:56004`;
   - observe WireGuard handshake;
   - verify stop removes adapter/routes.

## Current Gaps

- No Windows host runtime smoke yet.
- Windows EXE installer source/script exists, but installer build/sign/install smoke still needs a Windows host.
