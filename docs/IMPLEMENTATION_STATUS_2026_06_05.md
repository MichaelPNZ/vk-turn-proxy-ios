# Implementation Status - 2026-06-05

## Completed

### Repo baseline

- Fork copied to `/Users/mihailpozalov/StudioProjects/vk-turn-proxy-kmp`.
- Architecture doc added: `docs/ARCHITECTURE.md`.
- Implementation plan added: `docs/IMPLEMENTATION_PLAN.md`.
- Runtime log analysis added: `docs/RUNTIME_LOG_ANALYSIS_2026_06_05.md`.

### iOS/Go stability fixes

- Added `api.vk.me` to the iOS pre-resolve list.
- Added explicit resolver for `bogdanfinn/tls-client` VK HTTP calls.
- Added runtime stats fields:
  - `requested_conns`;
  - `vk_last_fetch_error`;
  - `vk_last_fetch_error_at`.
- Updated iOS stats UI to show active/requested connection count and degraded state.

### KMP shared scaffold

- Added Gradle root project and wrapper.
- Added `shared` Kotlin Multiplatform module.
- Targets:
  - Android library/AAR;
  - iOS arm64 framework;
  - iOS simulator arm64 framework;
  - macOS arm64 framework;
  - JVM desktop target for Windows planning.
- Added shared models:
  - `Profile`;
  - `WireGuardConfig`;
  - `ProxyConfig`;
  - `TransportMode`;
  - `ConnectionStatus`;
  - `DiagnosticsEvent`;
  - `ServerHealthSnapshot`.
- Added shared validation:
  - profile schema version;
  - peer `host:port`;
  - VK call URL/link id;
  - connection count;
  - TURN port.
- Added shared runtime payload mapper:
  - `ProfileRuntimeMapper`;
  - WireGuard UAPI generation;
  - proxy JSON generation;
  - interface address / DNS / allowed route defaults.
- Added JSON codec for profile encode/decode.
- Added iOS legacy compatibility mapper:
  - full backup JSON `AppConfig`;
  - one-click `ConnectionLink`;
  - `vkturnproxy://import?data=...` URL payload;
  - mapping into shared `Profile`.
- Added common tests for validation and JSON round-trip.
- Added `VKTurnShared.xcframework` assembly through Gradle:
  - `:shared:assembleVKTurnSharedReleaseXCFramework`.
- Connected `VKTurnShared.xcframework` to the iOS app through `VKTurnProxy/project.yml`.
- Added an Xcode pre-build script that assembles the shared framework before app build.

### iOS build hardening

- Regenerated `VKTurnProxy.xcodeproj` from XcodeGen.
- Removed Swift concurrency warnings in current Debug simulator build:
  - main actor timer callback;
  - `NETunnelProviderManager` status observer capture;
  - RTT probe completion state;
  - log fallback text capture.
- iOS import flow now calls `VKTurnShared.IosImportValidator` for full backups and one-click connection links.

### Android MVP shell

- Added Android app module:
  - `androidApp`.
- Added native Android Compose UI:
  - status panel;
  - profile import text field;
  - validation action;
  - validation result state.
- Android app depends on `shared` and calls `IosImportValidator`.
- Android VPN payload generation now uses shared `ProfileRuntimeMapper`, so Android and future Windows service code share the same WireGuard UAPI/proxy JSON shape.
- Added first Android `VpnService` lifecycle slice:
  - system VPN permission request;
  - safe TUN interface open/close;
  - narrow route `10.255.255.255/32` to avoid hijacking emulator traffic before the Go bridge exists;
  - runtime status propagation into the native UI.
- Added first Android Go mobile bridge:
  - `mobilebridge` Go package;
  - `gomobile bind` AAR at `androidApp/libs/vkturnbridge.aar`;
  - Kotlin dependency on `vkturnbridge.aar`;
  - imported profiles are translated into WireGuard UAPI + proxy JSON and passed into `AndroidVpnService`;
  - `AndroidVpnService` can call `Mobilebridge.startBootstrap`, `waitBootstrapReady`, `attachWireGuard`, and `turnOff`.
- Added Android socket protection:
  - `proxy.SetSocketProtector`;
  - protected Go outbound dial/listen helpers for VK HTTP, DNS fallback, TURN UDP/TCP, and SRTP control sockets;
  - `mobilebridge.SocketProtector`;
  - Kotlin implementation backed by `VpnService.protect(fd)`.
- Imported profiles now pass interface address, DNS servers, and allowed routes into `AndroidVpnService`; empty/no-profile starts still use the narrow smoke route.
- Added Android WireGuard attach fixes:
  - Android `mobilebridge` uses `tun.CreateUnmonitoredTUNFromFD` for `VpnService` TUN fd to avoid sandbox-blocked netlink monitoring;
  - Android profile mapper converts legacy iOS WireGuard INI into wireguard-go UAPI before calling `device.IpcSet`;
  - debug-only `SmokeStartActivity` can launch an imported profile through an intent extra for repeatable emulator smoke without typing secrets into the UI.
- Added repeatable Android imported-profile smoke script:
  - `scripts/smoke-android-imported-profile.sh`.
- Extended Android imported-profile smoke script with safe overrides:
  - `PEER_ADDRESS`;
  - `ALLOWED_IPS`;
  - `NUM_CONNECTIONS`.
- Added Android release build/signing baseline:
  - release `versionCode` is `156`;
  - release `versionName` is `1.0`;
  - optional release signing reads `androidApp/signing.properties`;
  - `androidApp/signing.properties.example` documents the required keystore fields;
  - `.gitignore` excludes local signing properties and keystores.
- Added local Android release signing:
  - `androidApp/signing.properties` exists locally and is ignored by Git;
  - `androidApp/keystore/vk-turn-proxy-release.jks` exists locally and is ignored by Git;
  - keystore format is PKCS12;
  - key alias is `vk-turn-proxy-release`;
  - certificate SHA-256 fingerprint is `8E:C1:C3:75:88:CF:0F:A8:38:B9:13:99:9E:03:D1:D8:AA:FF:A9:2E:92:D9:53:B3:CD:2A:BB:CB:6B:5A:C8:0E`.
- Added Android release signing runbook:
  - `docs/ANDROID_RELEASE_SIGNING.md`.
- Added Android release preflight:
  - `scripts/preflight-android-release.sh`;
  - checks `versionCode`, `versionName`, optional signing config, keystore path, APK artifact, and AAB artifact.
- Added release-safe Android import entrypoint:
  - `vkturnproxy://import?data=...` deep links open `MainActivity`;
  - external import payload is copied into the UI and validated automatically;
  - release builds no longer need debug-only `SmokeStartActivity` to exercise imported-profile startup.
- Added signed release imported-profile smoke:
  - `scripts/smoke-android-release-imported-profile.sh`;
  - installs signed release APK;
  - opens `vkturnproxy://import?data=...`;
  - taps `Start VPN`;
  - confirms localized Android VPN permission;
  - waits for `mobilebridge: WireGuard attached`;
  - taps `Stop` and verifies VPN cleanup.
- Added Android in-app diagnostics:
  - status/profile events are captured in a bounded in-memory event buffer;
  - Diagnostics panel shows the event tail;
  - Copy, Share, and Clear actions are available from the Android UI for physical-device smoke evidence.
- Built debug APK:
  - `androidApp/build/outputs/apk/debug/androidApp-debug.apk`;
  - size: 11M.
- Built release artifacts:
  - `androidApp/build/outputs/apk/release/androidApp-release.apk`;
  - `androidApp/build/outputs/bundle/release/androidApp-release.aab`.
  - APK sha256 `c9d5a20717e95f2e5972be57c0cdd4db1cd894643eae9cc2a5afe39fc7831ac7`;
  - AAB sha256 `a38365739b2cf7caa4d10a0181d4edf2aea17d735f736160ea2203241c65593e`.

### macOS MVP shell

- Added macOS app target:
  - scheme `VKTurnProxyMac`;
  - bundle id `com.vkturnproxy.mac`;
  - deployment target macOS 14.0.
- Added native SwiftUI macOS app:
  - profile import text editor;
  - shared validation action;
  - connection/status panel;
  - diagnostics panel with Refresh, Copy, Export, and Clear actions;
  - enabled connect/disconnect controls backed by `MacTunnelManager`.
- Connected `VKTurnShared.xcframework` to the macOS target through `VKTurnProxy/project.yml`.
- Connected `SharedLogger.swift` to the macOS app target so the app can read App Group Packet Tunnel logs.
- Added macOS pre-build Gradle step for `:shared:assembleVKTurnSharedReleaseXCFramework`.
- Added macOS tunnel layer source:
  - `MacTunnelManager` parses legacy iOS full backups and `vkturnproxy://import?data=...` links;
  - converts WireGuard keys into UAPI for wireguard-go;
  - creates `NETunnelProviderManager` with provider bundle id `com.vkturnproxy.mac.tunnel`;
  - records bounded diagnostics for profile import, validation, preference load, connect/disconnect, status changes, and export actions.
- Added macOS Packet Tunnel extension:
  - target `MacPacketTunnel`;
  - bundle id `com.vkturnproxy.mac.tunnel`;
  - embedded into `VKTurnProxyMac.app`;
  - reuses `PacketTunnelProvider.swift`, `SharedLogger.swift`, and `OSLogReader.swift`.
- Added macOS entitlements:
  - `MacApp/MacApp.entitlements`;
  - `MacPacketTunnel/MacPacketTunnel.entitlements`.
- Extended `WireGuardTURN.xcframework` with macOS arm64 static archive:
  - `WireGuardBridge/build/libwg-turn-macos-arm64.a`;
  - `WireGuardBridge/build/libwg-turn-macos-x86_64.a`;
  - universal `WireGuardBridge/build/libwg-turn-macos-universal.a`;
  - XCFramework library identifier `macos-arm64_x86_64`.
- Verified macOS Debug build and launch smoke locally after embedding the tunnel extension.
- Verified macOS unsigned Release build after adding diagnostics export.

### Windows desktop MVP

- Added desktop JVM module:
  - `desktopApp`.
- Added Windows-compatible desktop shell:
  - Swing system look and feel;
  - accepts full iOS backup JSON;
  - accepts `vkturnproxy://import?data=...` connection links;
  - parses legacy iOS formats through shared `LegacyIosConfig`;
  - validates profiles through shared `ConfigValidator`;
  - can reuse shared `ProfileRuntimeMapper` for the future Windows service payload;
  - shows peer, transport mode, connection count, DNS, allowed routes, and WireGuard config size;
  - copies runtime summary to clipboard.
- Added desktop import/runtime helpers:
  - `DesktopProfileImporter` centralizes full-backup and `vkturnproxy://` parsing for GUI and CLI;
  - `WindowsTunnelRuntime` builds typed `WindowsTunnelStartRequest` payloads from validated profiles;
  - Windows start request includes service name, adapter name, peer address, interface address, DNS, allowed routes, WireGuard UAPI, and proxy JSON.
- Added desktop CLI commands:
  - `validate --profile-file <path>`;
  - `windows-start-request --profile-file <path> --out <path>`;
  - `windows-preflight [--service-exe <path>]`;
  - `windows-service-commands --service-exe <path>`.
- Added Windows desktop tests:
  - `desktopApp/src/test/kotlin/com/vkturnproxy/desktop/windows/WindowsTunnelRuntimeTest.kt`.
- Added Windows desktop managed service controls:
  - service executable discovery/configuration;
  - UI Browse / Start / Status / Logs / Stop controls;
  - CLI `windows-control-start`, `windows-control-status`, `windows-control-logs`, and `windows-control-stop`;
  - generated start request path `~/.vkturnproxy/windows/start-request.json`.
- Added Windows desktop preflight:
  - `scripts/preflight-windows-desktop.sh`;
  - builds/tests/installs the desktop distribution;
  - cross-builds the Windows service executable;
  - runs CLI `windows-preflight`;
  - supports `ALLOW_EXTERNAL_BLOCKERS=1` for non-Windows hosts or missing service executable.
- Added Windows service executable scaffold:
  - `cmd/vk-turn-proxy-windows-service`;
  - `internal/windowstunnel`;
  - `scripts/build-windows-service.sh`;
  - supports `-mode validate`;
  - supports `-mode run-console`;
  - supports `-mode service` through Windows Service Control Manager on Windows;
  - supports named-pipe `control-start`, `control-status`, `control-logs`, and `control-stop`;
  - validates `WindowsTunnelStartRequest`;
  - starts VK/TURN bootstrap through shared Go `pkg/proxy`;
  - creates/reuses Wintun adapter through `wireguard/tun.CreateTUN` on Windows;
  - applies interface address, DNS, and routes through Windows `netsh`;
  - applies WireGuard UAPI to a `wireguard/device.Device`;
  - binds WireGuard packets to VK/TURN through `turnbind.NewTURNBind`;
  - writes status JSON with proxy stats and adapter/WireGuard state.
  - stops the active tunnel when the Windows service receives a stop/shutdown request.
- Added Windows service request tests:
  - `internal/windowstunnel/request_test.go`.
- Added Windows runtime package script:
  - `scripts/package-windows-runtime.sh`;
  - packages desktop distribution, Windows service executable, README, example request, and PowerShell run/install/uninstall helpers.
- Hardened the Windows runtime package helpers:
  - added `lib/common.ps1`;
  - added `test-prereqs.ps1`;
  - `install-service.ps1` now checks Administrator and `wintun.dll`, creates `C:\ProgramData\VKTurnProxy`, installs or updates the existing `VKTurnProxyTunnel` service, and keeps the service stopped until explicit start;
  - `start-tunnel.ps1` checks prerequisites, copies the active request to ProgramData for audit, starts the service if needed, then sends named-pipe `control-start`;
  - `status-tunnel.ps1` and `export-logs.ps1` provide offline status/log output when the service is not running;
  - `uninstall-service.ps1` is idempotent and handles already-absent services;
  - `smoke-windows-runtime.ps1` runs packaged prerequisites, request validation, install/update, start, status wait for `wireguard_attached`, timestamped evidence export, and stop by default.
- Added Windows EXE installer packaging source:
  - `packaging/windows/inno/vk-turn-proxy.iss.tpl`;
  - `scripts/package-windows-installer.ps1`;
  - installs the desktop app, service executable, PowerShell controls, and Start Menu shortcuts;
  - supports optional Authenticode signing through `signtool`;
  - `scripts/test-windows-installer-packaging.sh` sanity-checks the template/script and runtime inputs.
- Added Windows implementation plan:
  - `docs/WINDOWS_IMPLEMENTATION_PLAN.md`.
- Current Windows gap:
  - no Windows host service runtime smoke yet;
  - no Windows-side EXE installer build/sign/install smoke yet;
  - no full Windows VPN smoke yet.

### Server hardening source

- Added fork-owned server command:
  - `cmd/vk-turn-proxy-server`.
- Compatibility target:
  - `-listen`;
  - `-connect`;
  - `-srtp`;
  - `-logfile`.
- Added production hardening flags:
  - `-health-listen`;
  - `-session-idle-timeout`;
  - `-max-sessions`.
- Added admin endpoints:
  - `/healthz`;
  - `/readyz`;
  - `/metrics`.
- Added probe echo support for the iOS client watchdog sentinel.
- Added counters:
  - active sessions;
  - accepted/closed sessions;
  - rejected sessions after the concurrent-session guard trips;
  - accept/backend errors;
  - probe echoes;
  - rx/tx bytes;
  - last activity.
- Built local Linux amd64 deploy candidate:
  - `build/server/vk-turn-proxy-server-linux-amd64`;
  - sha256 `c5700a6b8e2f7a48e890c0eeb23e096f35b53d497dd9f819a5175b846085b44b`.

### Server deploy kit

- Added server deployment files:
  - `deploy/server/vk-turn-proxy-ios.service`;
  - `deploy/server/vk-turn-proxy-ios.env.example`;
  - `deploy/server/vk-turn-proxy-ios.logrotate`.
- Added server package script:
  - `scripts/package-server.sh`;
  - builds Linux amd64 binary;
  - writes sha256;
  - creates `ustar` tar.gz package without macOS pax/xattr headers.
- Added VPS deploy script:
  - `scripts/deploy-server-vps.sh`;
  - supports `MODE=dry-run`;
  - supports `MODE=install-staged`;
  - supports `MODE=promote`;
  - supports `MODE=rollback`;
  - refuses dry-run on production port `56004`;
  - requires `CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004` before `MODE=promote`;
  - writes `before-promote.txt` and `after-promote.txt` evidence files into the promote backup directory.
- Added public second-port smoke helper:
  - `scripts/server-public-smoke-vps.sh`;
  - supports `ACTION=start`;
  - supports `ACTION=status`;
  - supports `ACTION=logs`;
  - supports `ACTION=stop`.
- Added runbook:
  - `docs/SERVER_DEPLOY_RUNBOOK.md`.
- Added local readiness gate:
  - `scripts/local-readiness-gate.sh`;
  - runs shell syntax checks;
  - runs `git diff --check`;
  - runs `scripts/test-server-deploy-safety.sh`;
- runs `go test ./...`;
- builds server package;
- runs shared/Android/desktop Gradle gates;
- runs Android release APK/AAB builds;
- runs Android release preflight in strict mode;
- can run Android signed release imported-profile smoke when `RUN_ANDROID_RELEASE_SMOKE=1`;
- runs Windows desktop preflight with external service/host blockers allowed;
- runs local unsigned Apple Release gate;
- runs TestFlight preflight with external blockers allowed;
- does not run VPS dry-run unless `RUN_VPS_DRY_RUN=1`.
- Verified VPS localhost-only dry-run on `142.252.220.91`:
  - SRTP listen `127.0.0.1:56014`;
  - admin health `127.0.0.1:56085`;
  - WireGuard backend `127.0.0.1:51820`;
  - `/healthz` returned `ok`;
  - `/readyz` returned `ready`;
  - `/metrics` returned Prometheus-style counters.
- Verified production remained untouched:
  - UDP `*:56004` still owned by existing process `pid=943206`;
  - dry-run ports `56014` and `56085` were not left running.
- Re-ran VPS localhost-only dry-run after release artifact packaging changes:
  - command: `MODE=dry-run SSH_USER=root HOST=142.252.220.91 DRY_LISTEN=127.0.0.1:56014 DRY_HEALTH=127.0.0.1:56085 DRY_CONNECT=127.0.0.1:51820 scripts/deploy-server-vps.sh`;
  - `/healthz` returned `ok`;
  - `/readyz` returned `ready`;
  - `/metrics` exposed uptime/session/error/byte counters;
  - server log showed `listening on 127.0.0.1:56014 (srtp) -> 127.0.0.1:51820`;
  - post-run `ss` showed no `56014`/`56085` dry-run listener;
  - production UDP `*:56004` still owned by existing process `pid=943206`;
  - `vk-turn-proxy-ios.service` remained `active`.
- Verified public second-port server helper on `142.252.220.91`:
  - `ACTION=start` opened temporary UDP `*:56014`;
  - admin health `127.0.0.1:56085` returned `ok` and `ready`;
  - `ACTION=status` showed the temporary listener;
  - `ACTION=logs` showed `[::]:56014 (srtp) -> 127.0.0.1:51820`;
  - `ACTION=stop` removed the temporary listener;
  - post-stop check showed only production UDP `*:56004`.
- Fixed public second-port stop handling:
  - kills the `timeout` wrapper;
  - kills any orphaned `/tmp/vk-turn-proxy-public-smoke/vk-turn-proxy-server` child process;
  - regression start/stop check left only production UDP `*:56004`.
- Verified Android client against the hardened server on public second port:
  - temporary server listened on `142.252.220.91:56014`;
  - Android smoke used `PEER_ADDRESS=142.252.220.91:56014`;
  - `SRTP+TURN session established`;
  - `mobilebridge: WireGuard attached handle=1`;
  - WireGuard log showed `Received handshake response`;
  - app stop removed active VPN/tun0 from connectivity state;
  - temporary server was stopped after the test;
  - production UDP `*:56004` remained on the existing production process.

## Verified Commands

```bash
go test ./...
```

Result: passed.

```bash
cd WireGuardBridge
make xcframework
```

Result: passed, produced `WireGuardTURN.xcframework`.

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:desktopTest :shared:assemble
```

Result: passed.

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:allTests
```

Result: passed.

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :androidApp:assembleDebug
```

Result: passed.

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:allTests :androidApp:assembleDebug :shared:assembleVKTurnSharedReleaseXCFramework
```

Result: passed after Android `VpnService` lifecycle and Go AAR bridge changes.

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  /tmp/vkturn-gomobile-bin/gomobile bind \
  -target=android/arm64 \
  -androidapi 26 \
  -ldflags='-checklinkname=0' \
  -o androidApp/libs/vkturnbridge.aar \
  ./mobilebridge
```

Result: passed, produced:

- `androidApp/libs/vkturnbridge.aar`
- `androidApp/libs/vkturnbridge-sources.jar`

Produced KMP artifacts:

- `shared/build/outputs/aar/shared-release.aar`
- `shared/build/bin/iosArm64/releaseFramework/VKTurnShared.framework`
- `shared/build/bin/iosSimulatorArm64/releaseFramework/VKTurnShared.framework`
- `shared/build/bin/macosArm64/releaseFramework/VKTurnShared.framework`
- `shared/build/XCFrameworks/release/VKTurnShared.xcframework`

Xcode simulator build:

- Scheme: `VKTurnProxy`
- Bundle id: `com.vkturnproxy.app`
- Result: passed after `WireGuardTURN.xcframework` and `VKTurnShared.xcframework` were built.
- Latest result: passed with zero warnings/errors via XcodeBuildMCP simulator build/run after Android Go AAR bridge and shared model changes.
- `cd WireGuardBridge && make xcframework` passed after socket-protection changes.
- Latest post-macOS-target result: passed with zero warnings/errors via XcodeBuildMCP simulator build/run.

macOS build:

```bash
xcodebuild \
  -project VKTurnProxy/VKTurnProxy.xcodeproj \
  -scheme VKTurnProxyMac \
  -configuration Debug \
  -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO \
  build
```

Result: passed.

macOS tunnel extension packaging:

- `VKTurnProxyMac.app/Contents/PlugIns/MacPacketTunnel.appex` exists.
- `MacPacketTunnel.appex` Info.plist:
  - `CFBundleIdentifier = com.vkturnproxy.mac.tunnel`;
  - `NSExtensionPointIdentifier = com.apple.networkextension.packet-tunnel`;
  - `NSExtensionPrincipalClass = MacPacketTunnel.PacketTunnelProvider`.
- `WireGuardTURN.xcframework` contains `macos-arm64`.

macOS launch smoke:

- Opened `VKTurnProxyMac.app` from DerivedData.
- Process started successfully.

macOS diagnostics update:

- Added bounded in-app diagnostics to `MacTunnelManager`.
- Logged events cover app startup, saved VPN preference loading, profile file open, validation result, profile load result, connect/disconnect requests, VPN status changes, and diagnostics copy/export.
- Diagnostics intentionally avoid raw profile payloads, VK links, WireGuard keys, and peer endpoint values.
- `MacContentView` now renders the Logs panel and supports Refresh, Copy, Export to `.log`, and Clear.
- The macOS Logs panel combines bounded local app diagnostics with App Group `vpn.log` / `vpn.log.1` from `SharedLogger` when the Packet Tunnel writes file logs.
- `scripts/build-apple-release-local.sh macos` passed after the diagnostics panel change.

Windows desktop build:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :desktopApp:build
```

Result: passed, produced:

- `desktopApp/build/distributions/desktopApp.zip`
- `desktopApp/build/distributions/desktopApp.tar`
- `desktopApp/build/libs/desktopApp.jar`

Shared runtime mapper regression:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:allTests :androidApp:assembleDebug :desktopApp:build
```

Result: passed after moving Android WireGuard UAPI/proxy JSON generation into shared `ProfileRuntimeMapper`.

Server package:

```bash
bash -n scripts/package-server.sh scripts/deploy-server-vps.sh
scripts/package-server.sh
```

Result: passed, produced:

- `build/server/vk-turn-proxy-server-linux-amd64`
- `build/server/vk-turn-proxy-server-linux-amd64.sha256`
- `build/server/vk-turn-proxy-server-7189d29-linux-amd64.tar.gz`

Package metadata check:

```bash
python3 - <<'PY'
import tarfile
p='build/server/vk-turn-proxy-server-7189d29-linux-amd64.tar.gz'
with tarfile.open(p, 'r:gz') as t:
    assert not any(m.pax_headers for m in t.getmembers())
print('pax_headers=none')
PY
```

Result: passed.

VPS dry-run:

```bash
MODE=dry-run SSH_USER=root HOST=142.252.220.91 scripts/deploy-server-vps.sh
```

Result: passed.

Observed output:

- `ok`
- `ready`
- metrics counters
- dry-run log: `listening on 127.0.0.1:56014 (srtp) -> 127.0.0.1:51820`
- dry-run log: `admin health server listening on 127.0.0.1:56085`

Production listener check:

```bash
ssh root@142.252.220.91 "ss -lunp | grep -E '56004|56014|56085' || true"
```

Result: only production UDP `*:56004` was present after dry-run exit.
- Quit cleanly with AppleScript.

iOS regression gate after macOS tunnel changes:

- XcodeBuildMCP simulator build/run for scheme `VKTurnProxy` passed.
- Diagnostics reported zero warnings and zero errors.

Current general gates after macOS tunnel changes:

- `go test ./...` passed.
- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:allTests :androidApp:assembleDebug :shared:assembleVKTurnSharedReleaseXCFramework` passed.
- `cd WireGuardBridge && make xcframework` passed with iOS device, iOS simulator, and macOS arm64 libraries.

Server smoke:

```bash
go run ./cmd/vk-turn-proxy-server \
  -listen 127.0.0.1:56094 \
  -connect 127.0.0.1:51820 \
  -srtp \
  -health-listen 127.0.0.1:56095
```

Result:

- `GET /healthz` returned `ok`.
- `GET /readyz` returned `ready`.
- `GET /metrics` returned Prometheus-style counters.

VPS dry-run:

- Uploaded deploy candidate to `/tmp/vk-turn-proxy-server.next`.
- Server sha256 on VPS matched local sha256.
- Started with `timeout` on localhost-only ports:
  - SRTP listen: `127.0.0.1:56014`;
  - admin HTTP: `127.0.0.1:56085`.
- Verified on VPS:
  - `GET /healthz` returned `ok`;
  - `GET /readyz` returned `ready`;
  - `GET /metrics` returned Prometheus-style counters.
- Confirmed temporary process exited and `56014` / `56085` were no longer listening.
- Production `56004` was not touched.

Android emulator smoke:

- AVD: `Pixel_9_API_35`.
- Installed `androidApp-debug.apk`.
- Launched package `com.vkturnproxy.android`.
- UI tree showed:
  - `VK Turn Proxy`;
  - `Android MVP shell`;
  - `Import profile`;
  - `Validate`.
- Tapped `Validate` with empty input.
- UI showed validation message:
  - `Paste a full backup JSON or vkturnproxy:// import link.`
- Tapped `Start VPN`.
- Android system VPN permission dialog appeared for `VK Turn Proxy`.
- Confirmed permission with `OK`.
- UI showed:
  - `Interface active`;
  - `Android VPN interface opened; Go bridge pending.`;
  - state badge `TUN`.
- `dumpsys connectivity` showed active VPN:
  - package `com.vkturnproxy.android`;
  - interface `tun0`;
  - address `10.88.0.2/32`;
  - MTU `1280`;
  - route `10.255.255.255/32`.
- Tapped `Stop`.
- UI returned to:
  - `Not connected`;
  - `Android VpnService is stopped.`
- `dumpsys connectivity` no longer showed `tun0` for the app.
- Crash buffer had no `FATAL EXCEPTION`.
- Repeated smoke after Go AAR packaging:
  - APK contained `lib/arm64-v8a/libgojni.so`;
  - app launched successfully;
  - empty validation still showed expected validation error;
  - `Start VPN` still opened TUN safely without an imported profile;
  - `Stop` removed `tun0`;
  - logcat had no `FATAL EXCEPTION`.
- Repeated smoke after socket-protection/profile-route changes:
  - no-profile `Start VPN` opened `tun0` with smoke route;
  - no-profile `Stop` removed `tun0`;
  - logcat had no `FATAL EXCEPTION`.
- Imported-profile smoke after Android TUN/UAPI fixes:
  - profile source: current local iOS app preferences, transformed into a `vkturnproxy://import?data=...` payload locally;
  - secrets/VK link were not printed in command output;
  - debug-only `SmokeStartActivity` launched the imported profile through an intent extra;
  - `VpnService` opened `tun0` with address `10.77.77.3/32`, DNS `1.1.1.1`, route `0.0.0.0/0`;
  - Go AAR loaded `libgojni.so`;
  - VK/TURN bootstrap reached `SRTP+TURN session established`;
  - `mobilebridge: WireGuard attached handle=1`;
  - WireGuard log showed `Received handshake response`;
  - UI showed `Interface active`, `TUN`, and `Go bridge attached; protected routes active.`;
  - `Stop` removed `tun0`;
  - logcat had no app `FATAL EXCEPTION`.
- Automated imported-profile smoke script:
  - `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk scripts/smoke-android-imported-profile.sh`;
  - result: `Android imported-profile smoke passed.`
- Android second-port smoke preparation:
  - `scripts/smoke-android-imported-profile.sh` supports `PEER_ADDRESS=142.252.220.91:56014`;
  - `scripts/smoke-android-imported-profile.sh` supports `ALLOWED_IPS` and `NUM_CONNECTIONS`;
  - stale AVD locks were removed and adb server restarted;
  - `Pixel_9_API_35` booted successfully when run as a foreground emulator process;
  - `PEER_ADDRESS=142.252.220.91:56014 scripts/smoke-android-imported-profile.sh` passed;
  - relevant logcat lines included `SRTP+TURN session established`, `mobilebridge: WireGuard attached handle=1`, and `Received handshake response`;
  - post-stop connectivity dump no longer showed `VPN:com.vkturnproxy.android` or `tun0`.

## TestFlight Gate

The repository has a TestFlight release pipeline in `release.sh`.

Current release script support:

- `./release.sh <tag> all` uploads both iOS and macOS to TestFlight and attaches cross-platform artifacts to GitHub Release.
- `./release.sh <tag> ios` uploads only iOS.
- `./release.sh <tag> macos` uploads only macOS.
- For `all`, the script also builds and attaches:
  - Android release APK;
  - Android release AAB;
  - Windows runtime zip;
  - Windows setup EXE if prebuilt under `build/windows-installer/`;
  - Linux amd64 server package;
  - `build/release/<tag>-cross-platform-sha256.txt` from `scripts/package-release-artifacts.sh`;
  - `build/release/<tag>-sha256.txt` full release checksum manifest after Apple exports.
- The script builds `WireGuardTURN.xcframework` before archives.
- iOS archive:
  - scheme `VKTurnProxy`;
  - destination `generic/platform=iOS`.
- macOS archive:
  - scheme `VKTurnProxyMac`;
  - destination `generic/platform=macOS`;
  - embeds `MacPacketTunnel.appex`.
- GitHub Release upload now attaches every exported Apple local artifact plus the cross-platform artifacts for `all`.
- Added standalone cross-platform artifact packager:
  - `scripts/package-release-artifacts.sh <tag>`;
  - builds Android APK/AAB, Windows runtime zip, Linux server package;
  - attaches optional prebuilt Windows setup EXE from `build/windows-installer/vk-turn-proxy-windows-*-setup.exe`;
  - writes `build/release/<tag>-cross-platform-sha256.txt`;
  - checksum manifest uses repo-relative paths, not local absolute paths;
  - prints `artifact=<path>` lines consumed by `release.sh`.
- Added shared release manifest formatter:
  - `scripts/release-manifest-lib.sh`;
  - `release.sh` and `scripts/package-release-artifacts.sh` both write repo-relative manifest paths through the same helper;
  - `scripts/test-release-manifest-format.sh` verifies that manifest entries do not leak local `/Users/...` repo paths.
- `bash -n release.sh` passed.
- Added read-only TestFlight preflight:
  - `scripts/preflight-testflight.sh`;
  - checks Xcode/XcodeGen tools;
  - checks GitHub CLI auth;
  - checks iOS/macOS schemes;
  - checks project build numbers;
  - checks iOS/macOS packet tunnel entitlements;
  - checks `WireGuardTURN.xcframework` slices;
  - checks `VKTurnShared.xcframework`;
  - checks App Store Connect env/key;
  - checks local signing identities;
  - checks installed distribution provisioning profiles for every iOS/macOS app and tunnel bundle id.
- Added safe App Store Connect env template:
  - `VKTurnProxy/AppStoreConnect.env.example`.
- Added TestFlight setup helper and runbook:
  - `scripts/configure-testflight-env.sh`;
  - `scripts/diagnose-apple-signing.sh`;
  - `docs/TESTFLIGHT_SETUP.md`;
  - helper validates App Store Connect key id, issuer UUID, absolute `.p8` path, writes `VKTurnProxy/AppStoreConnect.env`, and sets file mode `0600`.
  - diagnostics script reads project bundle ids, App Store Connect env state, keychain signing identities, and local provisioning profiles without modifying secrets/keychain.
- Added local unsigned Apple Release build gate:
  - `scripts/build-apple-release-local.sh`;
  - builds `WireGuardTURN.xcframework`;
  - builds `VKTurnShared.xcframework`;
  - builds iOS Release without signing;
  - builds macOS Release without signing.
- Fixed macOS Release architecture issue found by the local gate:
  - macOS Release builds both `arm64` and `x86_64`;
  - previous Go/KMP frameworks had only `macos-arm64`;
  - `WireGuardTURN.xcframework` now contains `macos-arm64_x86_64`;
  - `VKTurnShared.xcframework` now contains `macos-arm64_x86_64`.

Preflight result:

```bash
scripts/preflight-testflight.sh
```

Result: failed only on release-blocking external setup, with project checks passing.

Passed:

- `xcodebuild` found;
- `xcodegen` found;
- GitHub CLI found and authenticated;
- iOS scheme `VKTurnProxy` exists;
- macOS scheme `VKTurnProxyMac` exists;
- build number is `156`;
- iOS/macOS packet tunnel entitlements contain `packet-tunnel-provider`;
- app group entitlements contain `group.com.vkturnproxy.app`;
- macOS sandbox entitlements are present;
- `WireGuardTURN.xcframework` contains `ios-arm64`, `ios-arm64-simulator`, and `macos-arm64_x86_64`;
- `VKTurnShared.xcframework` exists.
- `VKTurnShared.xcframework` contains `ios-arm64`, `ios-arm64-simulator`, and `macos-arm64_x86_64`.
- `DEVELOPMENT_TEAM` is `CDMQ33VFQC`.

Local unsigned Release gate:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk scripts/build-apple-release-local.sh all
```

Result: passed.

Latest macOS-only unsigned Release gate after diagnostics:

```bash
scripts/build-apple-release-local.sh macos
```

Result: passed.

Verified outputs:

- iOS Release build passed without signing;
- macOS Release build passed without signing;
- `VKTurnProxyMac.app` binary is universal `arm64+x86_64`;
- embedded `MacPacketTunnel.appex` binary is universal `arm64+x86_64`.

Current local blockers:

- `VKTurnProxy/AppStoreConnect.env` is missing.
- `Apple Distribution` signing identity is missing.
- Local provisioning profiles count is `0`.
- Distribution provisioning profiles are therefore missing for `com.vkturnproxy.app`, `com.vkturnproxy.app.tunnel`, `com.vkturnproxy.mac`, and `com.vkturnproxy.mac.tunnel`.
- A revoked `Apple Development` identity is present in keychain.
- Added read-only Apple signing evidence collector:
  - `scripts/collect-apple-signing-evidence.sh`;
  - writes `summary.txt`, `blockers.txt`, `bundle-ids.txt`, `provisioning-profiles.tsv`, `appstore-connect-env.txt`, `code-signing-identities.txt`, and `next-commands.txt`;
  - does not create certificates, install profiles, call App Store Connect, modify keychain, or write secret values.
- Latest Apple signing evidence:
  - command: `scripts/collect-apple-signing-evidence.sh build/evidence/apple-signing-current`;
  - `summary.txt` contains `evidence_type=apple_signing_readiness`;
  - `result=blocked`;
  - `team_id=CDMQ33VFQC`;
  - `bundle_count=4`;
  - `profiles_count=0`;
  - `apple_distribution_identity=missing`;
  - `revoked_identity=present`;
  - `blocker_count=6`;
  - `testflight_ready=false`.

Required variables:

```bash
APPSTORE_KEY_ID=
APPSTORE_ISSUER_ID=
APPSTORE_KEY_PATH=
```

`APPSTORE_KEY_PATH` must point to the local `.p8` App Store Connect API key.
Recommended setup command:

```bash
scripts/configure-testflight-env.sh \
  --key-id <APPSTORE_KEY_ID> \
  --issuer-id <APPSTORE_ISSUER_ID> \
  --key-path /absolute/path/to/AuthKey_<APPSTORE_KEY_ID>.p8
```

Current warnings:

- working tree is dirty, so `release.sh` will refuse to run until changes are committed or stashed;
- a revoked `Apple Development` identity is present in the keychain and should be removed to reduce Xcode signing ambiguity.

Local readiness gate:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  RUN_APPLE_RELEASE=1 \
  RUN_VPS_DRY_RUN=0 \
  scripts/local-readiness-gate.sh
```

Result: passed.

Covered:

- shell syntax for release/deploy/smoke/preflight scripts;
- `git diff --check`;
- `go test ./...`;
- server Linux amd64 package;
- `:shared:allTests`;
- `:androidApp:assembleDebug`;
- `:androidApp:assembleRelease`;
- `:androidApp:bundleRelease`;
- `:desktopApp:build`;
- `:shared:assembleVKTurnSharedReleaseXCFramework`;
- Android release preflight;
- Windows desktop preflight with non-Windows host downgraded to warning; service executable path exists;
- unsigned iOS Release build;
- unsigned macOS Release build;
- TestFlight preflight with known external blockers downgraded to warnings.

Re-run after Windows runtime package hardening:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  RUN_APPLE_RELEASE=0 \
  RUN_ANDROID_RELEASE_SMOKE=0 \
  RUN_VPS_DRY_RUN=0 \
  scripts/local-readiness-gate.sh
```

Result: passed.

Covered:

- shell syntax for release/deploy/smoke/preflight scripts;
- `git diff --check`;
- `go test ./...`;
- server Linux package build;
- shared/Android/Desktop Gradle gates;
- Android release preflight;
- Windows desktop preflight with external blockers allowed;
- TestFlight preflight with external blockers allowed.

Re-run after cross-platform `release.sh` artifact support:

```bash
bash -n release.sh
git diff --check
scripts/test-release-manifest-format.sh
scripts/package-release-artifacts.sh v1.0-build156
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  RUN_APPLE_RELEASE=0 \
  RUN_ANDROID_RELEASE_SMOKE=0 \
  RUN_VPS_DRY_RUN=0 \
  scripts/local-readiness-gate.sh
```

Result: passed.

Additional release artifact check:

- `scripts/package-release-artifacts.sh v1.0-build156` produced Android APK/AAB, Windows runtime zip, `build/server/vk-turn-proxy-server-v1.0-build156-linux-amd64.tar.gz`, and `build/release/v1.0-build156-cross-platform-sha256.txt`; no Windows setup EXE was present on this macOS host, so that optional artifact was skipped.
- `shasum -a 256 -c build/release/v1.0-build156-cross-platform-sha256.txt` passed for all listed artifacts.
- Current `build/release/v1.0-build156-cross-platform-sha256.txt` sha256 after Windows Wintun helper rebuild: `2c3a7fcebddb08df6964332b6bd5850fa8190d9716da7a468c1002b9659f55f8`.
- Current cross-platform artifact sha256 values:
  - Android APK: `9bf653de3fbac32c360852d6fa2e710a7db77cfe9addd4d9f80fbf96d3afba1b`;
  - Android AAB: `09a1643cd19c2de9c2badf2a6022074df46a6ef471f1161c8fcd0e867f3bd190`;
  - Windows runtime zip: `dd70dc39d79c037c4cf36638691c0f0dfedb92a894d563c4ea79c7a2707ad330`;
  - Linux server package: `399a737fcc12d3dcc27953997427646446f580ff00e1313e14803da90baf166d`.
- The cross-platform manifest contains repo-relative paths and no `/Users/...` absolute paths.
- Android release packaging no longer prints Kotlin metadata `e:` lines from `lintVital`; release lintVital is disabled for `androidApp` and `shared` because Kotlin/Compose artifacts use Kotlin metadata 2.4 while the Android lint parser reports expected metadata 2.2. Compile, tests, signing preflight, APK signing verification, and AAB signature verification still run.
- `release.sh` now writes `build/release/<tag>-sha256.txt` during a full release after collecting all artifacts, using the same repo-relative manifest formatter.
- `scripts/test-release-manifest-format.sh` passed and is part of `scripts/local-readiness-gate.sh`.
- Added strict final release readiness gate:
  - `scripts/final-release-readiness.sh <tag>`;
  - verifies local shell/script/package/checksum preflights;
  - runs Android release preflight, TestFlight preflight, and Windows desktop preflight;
  - validates external evidence summaries for Android physical smoke, iPhone TestFlight Network Extension smoke, signed macOS Packet Tunnel smoke, Windows runtime smoke, Windows installer smoke, and production server/client smoke;
  - supports `ALLOW_EXTERNAL_BLOCKERS=1` for local reporting while keeping strict mode release-blocking.
- Added no-secrets external smoke handoff kit:
  - `scripts/prepare-external-smoke-kit.sh <tag>`;
  - writes `build/external-smoke-kit/<tag>/` with cross-platform checksums, Android physical wrapper, iPhone/macOS evidence collectors, Windows runtime/installer templates, production final evidence template, and `final-readiness.env.example`;
  - production template is intentionally non-runnable (`exit 64`) and still requires explicit `CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004`;
  - `scripts/test-external-smoke-kit.sh` verifies required files, bash syntax, final-readiness env keys, Android `REQUIRE_PHYSICAL_DEVICE=1`, production promote guard text, and absence of concrete embedded import links / App Store Connect key ids.
- Added external smoke evidence summary helper:
  - `scripts/write-smoke-evidence-summary.sh`;
  - writes `summary.txt` with `result=passed`, `evidence_type=<type>`, timestamp, host, and attachment count for iPhone, macOS, Windows installer, server production baseline, and server production smoke evidence.
- Added Apple smoke evidence collector:
  - `scripts/collect-apple-smoke-evidence.sh`;
  - `iphone` mode copies exported TestFlight logs/screenshots/transcripts and writes `iphone_testflight_network_extension` summary;
  - `macos` mode collects local `log show` output plus App Group `vpn.log` / `vpn.log.1` when present and writes `macos_testflight_packet_tunnel` summary.
- Added read-only server production evidence collector:
  - `scripts/collect-server-production-evidence.sh`;
  - gathers systemd status, healthz, readyz, metrics head, listener state, sha256, server log tail, optional promote backup files, and optional production client smoke log;
  - supports `MODE=baseline` for the currently running legacy production service and writes `server_production_baseline`, which does not satisfy final readiness;
  - supports `MODE=final` after promote and production-port client smoke;
  - in `MODE=final`, validates service active, `healthz=ok`, `readyz=ready`, listener `:56004`, and required `CLIENT_SMOKE_LOG`;
  - writes `server_production_smoke` summary for final readiness without promoting, rolling back, restarting, or editing production.
- Collected current production baseline evidence on 2026-06-06:
  - command: `MODE=baseline HOST=142.252.220.91 SSH_USER=root scripts/collect-server-production-evidence.sh build/evidence/server-production-baseline-current`;
  - `summary.txt` contains `evidence_type=server_production_baseline`;
  - service `vk-turn-proxy-ios.service` is `active`;
  - listener evidence shows UDP `*:56004`;
  - `/healthz` and `/readyz` on `127.0.0.1:56080` fail to connect because the currently running legacy command line has no `-health-listen`;
  - `MODE=final` was checked against current production and correctly failed with `Production healthz did not return ok`.
- Final readiness now rejects empty evidence directories:
  - `summary.txt` evidence must have `attachment_count > 0` and at least one supporting file;
  - Android physical evidence must include `device-qemu.txt`, `running-connectivity.txt`, `stopped-connectivity.txt`, and `final-logcat-filtered.txt`;
  - Windows runtime evidence must include `transcript.txt`, `status-running.json`, and `programdata-status-running.json`.
- Fixed shell syntax coverage in readiness scripts: shell files are now checked one by one instead of passing extra files as positional arguments to the first `bash -n` invocation.

Android release preflight:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  scripts/preflight-android-release.sh
```

Result: passed with zero warnings.

Android release signing verification:

- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :androidApp:assembleRelease :androidApp:bundleRelease` passed.
- `/Users/mihailpozalov/Library/Android/sdk/build-tools/36.0.0/apksigner verify --print-certs androidApp/build/outputs/apk/release/androidApp-release.apk` passed.
- `jarsigner -verify -certs -verbose androidApp/build/outputs/bundle/release/androidApp-release.aab` passed.
- Signed APK certificate SHA-256 digest: `8ec1c37588cf0fa838b913999e03d1d8aaffa92e92d953b3cd2abbcb6b5ac80e`.
- Current Android release artifact sha256 values:
  - APK: `9bf653de3fbac32c360852d6fa2e710a7db77cfe9addd4d9f80fbf96d3afba1b`;
  - AAB: `09a1643cd19c2de9c2badf2a6022074df46a6ef471f1161c8fcd0e867f3bd190`.

Android release emulator launch smoke:

- Started headless `Pixel_9_API_35`.
- Installed `androidApp/build/outputs/apk/release/androidApp-release.apk`.
- Resolved and launched `com.vkturnproxy.android/.MainActivity`.
- UI tree contained `VK Turn Proxy`, `Import profile`, and `Start VPN`.
- App process was alive.
- Crash buffer had no `FATAL EXCEPTION`.

Android signed release imported-profile smoke:

```bash
SERIAL=emulator-5554 \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  BUILD_RELEASE=0 \
  scripts/smoke-android-release-imported-profile.sh
```

Additional Android physical-device smoke preparation:

- `scripts/smoke-android-release-imported-profile.sh` now supports:
  - `IMPORT_LINK=vkturnproxy://import?data=...`;
  - `PROFILE_FILE=/path/to/full-backup.json`;
  - `PROFILE_FILE=/path/to/connection.json`;
  - legacy fallback to `PREF=~/Library/Containers/com.vkturnproxy.app/Data/Library/Preferences/com.vkturnproxy.app.plist`;
  - `PREPARE_IMPORT_ONLY=1` to validate import-link preparation without installing/starting the app.
- This removes the macOS iOS-preferences dependency for physical Android smoke handoff.
- Android release smoke now writes an evidence directory on prepare, success, and failure:
  - `summary.txt` with result, source, APK sha256, link byte length, and `require_physical_device`;
  - UI dumps, filtered logcat, package info, and connectivity snapshots for runtime runs;
  - `REQUIRE_PHYSICAL_DEVICE=1` rejects emulator devices so final readiness cannot use emulator evidence for the physical Android gate.
- Stability default changed after analyzing `/Users/mihailpozalov/Library/Containers/com.vkturnproxy.app/Data/tmp/vpn-export.log` from build 134:
  - log size: 81,143 lines;
  - successful SRTP sessions: 133;
  - `cold-start cap`: 11,042 entries;
  - `3 consecutive short failures`: 7,311 entries;
  - `SRTP read elapsed ... freeze detected`: 54 entries;
  - `freeze detected`: 122 entries;
  - `summary: 30 idle`: 39 entries;
  - current fresh-profile/default `numConnections` is now `10` in KMP shared, iOS, and macOS;
  - explicit imported/edited `numConnections` values are still preserved, so old profiles that intentionally set `30` keep `30`.

Build-156 default-10 Android imported-profile smoke:

```bash
SERIAL=emulator-5554 \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  BUILD_RELEASE=0 \
  NUM_CONNECTIONS=10 \
  EVIDENCE_DIR=build/android-release-smoke/default10-emulator-v156 \
  scripts/smoke-android-release-imported-profile.sh
```

Result: passed on headless `Pixel` emulator.

Evidence:

- `build/android-release-smoke/default10-emulator-v156/summary.txt` records `result=passed`, `source=PREF`, `require_physical_device=0`, and release APK sha256 `9bf653de3fbac32c360852d6fa2e710a7db77cfe9addd4d9f80fbf96d3afba1b`;
- `build/android-release-smoke/default10-emulator-v156/import-valid-ui.xml` contains an imported profile generated with `numConnections=10`;
- `build/android-release-smoke/default10-emulator-v156/final-logcat-filtered.txt` shows `proxy: [conn 0, cred 0] SRTP+TURN session established` and `mobilebridge: WireGuard attached handle=1`;
- `build/android-release-smoke/default10-emulator-v156/running-connectivity.txt` shows active `VPN:com.vkturnproxy.android`;
- `build/android-release-smoke/default10-emulator-v156/stopped-connectivity.txt` shows VPN cleanup after stop.

Result: passed on headless `Pixel_9_API_35`.

Re-run after Android diagnostics panel was added:

```bash
SERIAL=emulator-5554 \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  BUILD_RELEASE=0 \
  scripts/smoke-android-release-imported-profile.sh
```

Result: passed.

Covered:

- signed release APK install;
- `vkturnproxy://import?data=...` deep-link import into `MainActivity`;
- automatic profile validation in release UI;
- localized Android VPN permission confirmation (`ОК`);
- VK/TURN bootstrap and WireGuard attach;
- stop action and VPN cleanup.

Windows desktop preflight:

```bash
ALLOW_EXTERNAL_BLOCKERS=1 \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  scripts/preflight-windows-desktop.sh
```

Result: passed with external blockers downgraded.

Windows service executable verification:

```bash
go test ./internal/windowstunnel ./cmd/vk-turn-proxy-windows-service
scripts/build-windows-service.sh
go run ./cmd/vk-turn-proxy-windows-service -mode validate -request <sample-start-request.json>
```

Result: passed.

Built artifact:

- `build/windows/vk-turn-proxy-windows-service.exe`
- size: 18M
- sha256 is printed by `scripts/build-windows-service.sh` / `scripts/preflight-windows-desktop.sh`; the PE hash can change across rebuilds, so release notes should use the runtime zip checksum from `build/release/<tag>-cross-platform-sha256.txt`.

Windows runtime package:

```bash
scripts/package-windows-runtime.sh
```

Result: passed.

Built artifact:

- `build/windows-package/vk-turn-proxy-windows-runtime.zip`
- sha256 is recorded in `build/release/<tag>-cross-platform-sha256.txt`; the zip is rebuilt during release packaging, so do not hardcode it in release notes.
- includes `lib/common.ps1` and `test-prereqs.ps1`.
- includes `install-wintun.ps1`, which downloads official signed Wintun `0.14.1` from `https://www.wintun.net/builds/wintun-0.14.1.zip`, verifies SHA-256 `07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`, and installs `bin/amd64/wintun.dll` beside the service executable.
- includes idempotent `install-service.ps1` and `uninstall-service.ps1`.
- includes `start-tunnel.ps1`, `status-tunnel.ps1`, and `stop-tunnel.ps1` for managed service control.
- includes `export-logs.ps1`, which writes `config/diagnostics.json`.

Known Windows blockers:

- current host is `Mac OS X`, so real Windows service checks must run on a Windows host;
- `wintun.dll` can be installed by running the packaged `install-wintun.ps1`, or supplied beside the service executable / installed in `System32` before Windows runtime smoke;
- adapter attach, route/DNS application, administrator permissions, EXE installer build/install, and code signing still need Windows-side verification.

The project currently uses:

- Team ID: `CDMQ33VFQC`
- App bundle id: `com.vkturnproxy.app`
- PacketTunnel bundle id: `com.vkturnproxy.app.tunnel`
- macOS App bundle id: `com.vkturnproxy.mac`
- macOS PacketTunnel bundle id: `com.vkturnproxy.mac.tunnel`
- Current build number: `156`

Server production baseline evidence:

```bash
MODE=baseline \
  HOST=142.252.220.91 \
  SSH_USER=root \
  scripts/collect-server-production-evidence.sh \
  build/evidence/server-production-baseline-2026-06-06-current
```

Result: passed.

Evidence:

- `build/evidence/server-production-baseline-2026-06-06-current/summary.txt` has `result=passed`, `evidence_type=server_production_baseline`, and `attachment_count=9`;
- `systemctl-is-active.txt` returned `active`;
- `listeners.txt` showed UDP `*:56004`;
- `healthz.txt` and `readyz.txt` show no `127.0.0.1:56080` admin listener, matching the currently running legacy production service;
- production binary sha256 is `275ff8e9308392620b424ad59ce8ba095e5f4872f5de9cd4b9baa7fc37dfaf23`.

Update on 2026-06-07: `scripts/collect-server-production-evidence.sh` now writes
`server-status.txt` and appends the same machine-readable fields to `summary.txt`:
`service`, `listener_56004`, `listener_56080`, `healthz`, `readyz`, and `metrics`.
This keeps baseline evidence readable while preserving the distinction between
legacy production audit evidence and final production smoke evidence.

Apple signing/TestFlight evidence:

```bash
scripts/collect-apple-signing-evidence.sh \
  build/evidence/apple-signing-2026-06-06-current
```

Result: blocked by external signing/App Store Connect setup.

Evidence:

- `summary.txt` has `result=blocked`, `evidence_type=apple_signing_readiness`, `team_id=CDMQ33VFQC`, `bundle_count=4`, `profiles_count=0`, `apple_distribution_identity=missing`, and `blocker_count=6`;
- `blockers.txt` lists missing `VKTurnProxy/AppStoreConnect.env`, missing Apple Distribution identity, and missing distribution profiles for `com.vkturnproxy.app`, `com.vkturnproxy.app.tunnel`, `com.vkturnproxy.mac`, and `com.vkturnproxy.mac.tunnel`;
- `code-signing-identities.txt` shows a valid Apple Development identity and one revoked Apple Development identity;
- `next-commands.txt` records the required setup sequence before TestFlight upload.

External smoke kit:

```bash
scripts/prepare-external-smoke-kit.sh v1.0-build156
```

Result: passed.

Generated:

- `build/external-smoke-kit/v1.0-build156/README.md`;
- `build/external-smoke-kit/v1.0-build156/cross-platform-sha256.txt`;
- `build/external-smoke-kit/v1.0-build156/commands/android-physical-smoke.sh`;
- `build/external-smoke-kit/v1.0-build156/commands/collect-iphone-testflight-evidence.sh`;
- `build/external-smoke-kit/v1.0-build156/commands/collect-macos-testflight-evidence.sh`;
- `build/external-smoke-kit/v1.0-build156/templates/windows-runtime-smoke.ps1`;
- `build/external-smoke-kit/v1.0-build156/templates/windows-installer-smoke.ps1`;
- `build/external-smoke-kit/v1.0-build156/templates/server-production-final.sh`;
- `build/external-smoke-kit/v1.0-build156/templates/final-readiness.env.example`.

Verification:

- `scripts/test-external-smoke-kit.sh` passed twice in parallel and inside `scripts/final-release-readiness.sh`;
- generated bash wrappers passed `bash -n`;
- Android wrapper exits `64` with instructions when neither `PROFILE_FILE` nor `IMPORT_LINK` is set;
- final release readiness remains `0 failure(s), 6 warning(s)` with external blockers allowed.

GitHub Actions CI:

- Added `.github/workflows/release-gates.yml` for the fork.
- Runs on `main`, release tags matching `v*build*`, pull requests, and manual dispatch.
- Uses a macOS runner so Xcode/TestFlight preflight tooling is present.
- Creates an ephemeral Android signing key only for CI package verification; real release signing still uses local/private `androidApp/signing.properties`.
- Runs shell/package safety tests, Go tests, Gradle shared/Android/Desktop builds, non-Apple release packaging, unsigned Apple Release build gate, external smoke kit generation, and final readiness with external blockers downgraded to warnings.
- Uploads CI artifacts: APK, AAB, Windows runtime ZIP, Linux server package, checksum manifest, and external smoke kit.

## Next Implementation Steps

1. Run physical iPhone smoke with Network Extension, because simulator cannot prove tunnel behavior.
2. Run Android physical-device smoke with the signed release APK and imported-profile flow; emulator signed-release smoke already passed.
3. Run `desktopApp` on a Windows host and verify current profile import.
4. Build/install/sign the Windows EXE installer with `scripts/package-windows-installer.ps1`.
5. Decide whether to promote the hardened server to production `56004`; the public second-port Android emulator client test has passed, but promote still requires explicit approval.
6. After promote, run production-port client smoke and keep rollback ready.
7. Run signed macOS/iOS archive/export once `VKTurnProxy/AppStoreConnect.env` is available; use `scripts/configure-testflight-env.sh` to create it.
8. Run `scripts/final-release-readiness.sh <tag>` with all external evidence paths set before calling the build ready.
