# VK TURN Proxy KMP Implementation Plan

## Принципы плана

- Не ломать текущий рабочий сервер и клиентов.
- Сначала получить управляемый baseline, потом менять архитектуру.
- KMP внедрять как shared business logic, не как UI framework.
- Apple targets идут первыми: iOS и macOS через TestFlight.
- Server hardening идет отдельно от client UI work.

## Phase 0 - Repo Baseline

Цель: превратить скопированный fork в рабочую локальную базу.

Status 2026-06-05: done for local baseline.

Задачи:

1. Зафиксировать upstream source:
   - current commit `anton48/vk-turn-proxy-ios`;
   - current remote;
   - local fork target remote после создания GitHub fork.
2. Проверить локальную сборку Go:
   - `go test ./...`;
   - `cd WireGuardBridge && make xcframework` на macOS.
3. Проверить iOS Xcode project:
   - scheme;
   - bundle ids;
   - entitlements;
   - App Group;
   - Network Extension capability.
4. Добавить базовую документацию:
   - architecture;
   - implementation plan;
   - release/deploy notes later.

Acceptance:

- Repo открыт в Xcode.
- Go tests проходят или список failures задокументирован.
- iOS bridge собирается или blockers известны.

Verification:

- `go test ./...` passed.
- `cd WireGuardBridge && make xcframework` passed.
- `VKTurnProxy` iOS simulator build passed after XCFramework generation.

## Phase 1 - Production Server Audit

Цель: понять текущий сервер `142.252.220.91` без риска для клиентов.

Только read-only действия:

1. Найти running services:
   - systemd units;
   - docker containers;
   - listening UDP/TCP ports;
   - process command lines.
2. Найти WireGuard backend:
   - interface;
   - listen port;
   - peers count;
   - routing/NAT rules.
3. Зафиксировать current deployment:
   - binary path;
   - version/hash;
   - config/env;
   - logs path;
   - restart policy.
4. Проверить health вручную:
   - UDP listener доступен;
   - backend WG port жив;
   - logs не показывают постоянный crash/restart loop.

Acceptance:

- Есть документ `docs/SERVER_AUDIT_142_252_220_91.md`.
- Известны ports, binary, service manager, rollback path.
- Нет destructive changes на сервере.

## Phase 2 - Server Fork Hardening

Цель: сделать сервер стабильнее без изменения client protocol.

Status 2026-06-06: fork-owned SRTP server command, systemd/logrotate deploy kit, package script, VPS deploy script with explicit production promote confirmation and backup evidence, rollback path, localhost-only VPS dry-run, temporary public second-port server helper, and Android emulator client smoke on the public second port are done. Production `56004` has not been touched.

Задачи:

1. Вынести server fork в `server/`.
2. Добавить config file + env override.
3. Добавить structured logs.
4. Добавить `/healthz`, `/readyz`, `/metrics` на отдельном local/admin port.
5. Добавить session registry:
   - active sessions;
   - bytes in/out;
   - handshakes;
   - errors;
   - last activity.
6. Добавить graceful shutdown.
7. Добавить systemd unit:
   - `Restart=always`;
   - sane `RestartSec`;
   - logs/logrotate;
   - file descriptor limits;
   - optional watchdog.
8. Добавить deploy script:
   - backup current binary/config/unit;
   - upload new binary;
   - restart;
   - health check;
   - rollback.

Acceptance:

- New server binary speaks same protocol as current clients.
- Local UDP forwarding test passes.
- Production deploy can be dry-run.
- Rollback documented.

Current verification:

- `go test ./...` passed with `cmd/vk-turn-proxy-server`.
- Local server smoke passed on `127.0.0.1:56094`.
- `/healthz`, `/readyz`, `/metrics` passed on `127.0.0.1:56095`.
- Linux amd64 binary built at `build/server/vk-turn-proxy-server-linux-amd64`.
- Server package built at `build/server/vk-turn-proxy-server-7189d29-linux-amd64.tar.gz`.
- Package verified with no pax/xattr headers.
- VPS dry-run passed on localhost-only ports `127.0.0.1:56014` and `127.0.0.1:56085`.
- `/healthz`, `/readyz`, and `/metrics` returned expected responses on VPS dry-run.
- Production UDP `*:56004` remained owned by the existing production process after dry-run exit.
- Re-ran VPS dry-run after release artifact packaging changes:
  - `/healthz` returned `ok`;
  - `/readyz` returned `ready`;
  - `/metrics` exposed active/rejected/byte counters;
  - post-run check showed no `56014/56085` dry-run listeners;
  - production UDP `*:56004` remained owned by existing process `pid=943206`;
  - `vk-turn-proxy-ios.service` remained `active`.
- Temporary public smoke helper verified:
  - `ACTION=start` opened UDP `*:56014`;
  - health returned `ok` and `ready` on `127.0.0.1:56085`;
  - `ACTION=stop` removed the temporary listener;
  - production UDP `*:56004` remained the only server listener after stop.
- Android second-port smoke script can override peer address through `PEER_ADDRESS=142.252.220.91:56014`.
- Android emulator client smoke against `142.252.220.91:56014` passed:
  - `SRTP+TURN session established`;
  - `mobilebridge: WireGuard attached handle=1`;
  - WireGuard `Received handshake response`;
  - app stop removed active VPN/tun0.
- Fresh read-only production baseline collected at `build/evidence/server-production-baseline-2026-06-06-current`:
  - `summary.txt` records `result=passed`, `evidence_type=server_production_baseline`, and `attachment_count=9`;
  - production service is `active`;
  - listener evidence shows UDP `*:56004`;
  - legacy production still has no admin health listener on `127.0.0.1:56080`, as expected before promote.
- `scripts/deploy-server-vps.sh` now refuses accidental production actions:
  - `MODE=promote` requires `CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004`;
  - `MODE=dry-run` refuses `DRY_LISTEN` on production port `56004`;
  - promote writes `before-promote.txt` and `after-promote.txt` into the backup directory.
- Promote now automatically restores the same backup if post-promote
  systemd/`/healthz`/`/readyz` checks fail, writes `failed-promote.txt` and
  `after-auto-rollback.txt`, then exits non-zero.
- `scripts/test-server-deploy-safety.sh` verifies the production promote and dry-run guards locally.
- Server startup now fails fast if the admin health listener cannot bind, so a
  promoted process cannot silently run without `/healthz` and `/readyz`.
- Final server production evidence now requires active systemd, production UDP
  `:56004`, admin TCP `:56080`, `healthz=ok`, `readyz=ready`, exported
  `vk_turn_proxy_*` metrics, and a non-empty production client smoke log.
- `scripts/final-release-readiness.sh <tag>` requires production-port smoke evidence before final release readiness can pass.
- `scripts/prepare-external-smoke-kit.sh <tag>` creates a no-secrets handoff kit under `build/external-smoke-kit/<tag>/` with the guarded TestFlight secrets dry-run/write wrapper, external smoke commands/templates, and final readiness env placeholders.
- `scripts/collect-server-staging-evidence.sh <dir>` verifies the staged VPS binary/unit/logrotate/env files before any production promote.
- `scripts/release-blockers-status.sh <tag>` produces a read-only readiness snapshot under `build/release-status/<tag>/` with current GitHub CI/artifact, TestFlight workflow/secrets, Android physical-device, Apple signing/TestFlight, Windows, production-server blocker status, and staged VPS readiness.

Remaining:

- Promote to production only after explicit approval.
- Run production-port client smoke immediately after promote and keep rollback ready.

## Phase 3 - KMP Shared Module

Цель: добавить shared Kotlin module без переписывания UI и VPN layer.

Status 2026-06-05: initial scaffold done.

Задачи:

1. Создать Gradle KMP scaffold:
   - `shared`;
   - `iosArm64`, `iosSimulatorArm64`;
   - `macosArm64`;
   - `androidTarget`;
   - `jvm` for desktop/windows planning.
2. Добавить shared models:
   - `Profile`;
   - `WireGuardConfig`;
   - `ProxyConfig`;
   - `TransportMode`;
   - `ConnectionState`;
   - `DiagnosticsEvent`.
3. Добавить validators:
   - peer address;
   - VK link/link id;
   - conn count;
   - wrap keys/password;
   - config schema version.
4. Добавить migrations:
   - old backup JSON to versioned profile.
5. Добавить tests.

Acceptance:

- `./gradlew :shared:allTests` проходит.
- iOS/macOS frameworks генерируются.
- Old iOS config JSON можно распарсить shared-кодом.

Current verification:

- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:desktopTest :shared:assemble` passed.
- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:allTests` passed.
- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:assembleVKTurnSharedReleaseXCFramework` passed.
- Generated Android AAR.
- Generated iOS arm64, iOS simulator arm64 and macOS arm64 `VKTurnShared.framework`.
- Generated release `VKTurnShared.xcframework`.
- iOS app links `VKTurnShared.xcframework` through XcodeGen and pre-build Gradle task.
- Old iOS full backup and one-click connection link parsing is covered in shared tests.
- Swift import flow now calls shared validation for full backup JSON and one-click connection links.
- Fresh/default `numConnections` is now 10 after analyzing the supplied build-134 `vpn-export.log`; explicit imported values are preserved for backward compatibility.

## Phase 4 - iOS Native UI + KMP Integration

Цель: подключить KMP shared к существующему iOS app без ломки PacketTunnel.

Задачи:

1. Подключить generated KMP framework в Xcode.
2. Заменить часть Swift models на shared models там, где безопасно.
3. Оставить `PacketTunnelProvider` native Swift.
4. Сохранить Go XCFramework bridge.
5. Добавить build/version event в app и extension logs.
6. Проверить TestFlight release script.

Acceptance:

- iOS app собирается archive.
- Tunnel стартует на физическом iPhone.
- Current profile/backup импортируется.
- Build готов к TestFlight internal testing.

## Phase 5 - macOS TestFlight MVP

Цель: первый macOS client через TestFlight.

Status 2026-06-06: native macOS app target, shared validation, macOS Packet Tunnel extension target, macOS Go bridge slice, `MacTunnelManager`, and in-app diagnostics log export added; signed runtime tunnel smoke and TestFlight archive path remain.

Задачи:

1. Создать macOS app target.
2. Подключить KMP shared framework.
3. Реализовать native SwiftUI/AppKit UI:
   - profile list;
   - connect/disconnect;
   - status;
   - logs export;
   - import/export config.
4. Реализовать macOS tunnel layer:
   - Network Extension/System Extension path;
   - entitlement/capability validation;
   - Go bridge build for macOS.
5. Настроить App Store Connect/TestFlight macOS build.

Acceptance:

- macOS app запускается.
- Tunnel работает на test Mac.
- Internal TestFlight build uploaded.

Current verification:

- XcodeGen generated `VKTurnProxyMac` scheme.
- XcodeGen generated `MacPacketTunnel` scheme.
- `WireGuardTURN.xcframework` contains iOS device, iOS simulator, and macOS arm64 libraries.
- `WireGuardTURN.xcframework` now contains macOS universal `arm64+x86_64` library for Release/App Store builds.
- `VKTurnProxyMac` Debug build passed on local macOS with `CODE_SIGNING_ALLOWED=NO`.
- Build embeds `MacPacketTunnel.appex` into `VKTurnProxyMac.app/Contents/PlugIns`.
- Local launch smoke opened the macOS app successfully.
- macOS app uses `VKTurnShared.xcframework` for import validation.
- macOS app can parse legacy iOS profiles and configure `NETunnelProviderManager` for provider `com.vkturnproxy.mac.tunnel`.
- macOS app records bounded local diagnostics for import, validation, connect/disconnect, preference load, and VPN status changes.
- macOS diagnostics panel supports refresh, copy, export to `.log`, and clear without writing profile secrets, VK links, or WireGuard keys.
- macOS app target now includes `SharedLogger.swift`, so the Logs panel can read App Group `vpn.log` / `vpn.log.1` written by the Packet Tunnel extension.
- `release.sh` supports `all|ios|macos` and can archive/upload the macOS scheme to TestFlight when App Store Connect credentials are present.
- `scripts/preflight-testflight.sh` verifies iOS/macOS schemes, entitlements, XCFramework slices, App Store Connect env/key, local signing identities, and distribution provisioning profiles for every iOS/macOS app and tunnel bundle id.
- `scripts/configure-testflight-env.sh` creates ignored local `VKTurnProxy/AppStoreConnect.env` with mode `0600`; `docs/TESTFLIGHT_SETUP.md` documents the remaining Apple setup flow.
- `scripts/diagnose-apple-signing.sh` reports bundle ids, App Store Connect env state, keychain identities, revoked identities, and provisioning profile matches without mutating keychain/profile state.
- `scripts/build-apple-release-local.sh all` verifies unsigned iOS and macOS Release builds before signing/TestFlight upload.
- `scripts/final-release-readiness.sh <tag>` requires strict iPhone TestFlight Network Extension smoke evidence and signed macOS Packet Tunnel smoke evidence before final release readiness can pass: both must include clean connect/disconnect markers and supporting evidence files, not only a summary.
- `scripts/build-apple-release-local.sh macos` passed after adding the macOS diagnostics panel.
- Local Release gate passed after adding macOS x86_64 slices to both `WireGuardTURN.xcframework` and `VKTurnShared.xcframework`.
- `scripts/local-readiness-gate.sh` passed with `RUN_APPLE_RELEASE=1` and `RUN_VPS_DRY_RUN=0`.
- Preflight passed project-side checks and currently fails only on missing external setup:
  - `VKTurnProxy/AppStoreConnect.env`;
  - valid `Apple Distribution` signing identity;
  - installed distribution provisioning profiles for `com.vkturnproxy.app`, `com.vkturnproxy.app.tunnel`, `com.vkturnproxy.mac`, and `com.vkturnproxy.mac.tunnel`.
- Signing diagnostics currently show:
  - no App Store Connect env file;
  - no Apple Distribution identity;
  - one revoked Apple Development identity;
  - zero local provisioning profiles.

Remaining:

- Run signed macOS Packet Tunnel runtime smoke on a Mac with Network Extension entitlement.
- Validate Apple entitlements and signing for TestFlight.
- Archive/upload internal iOS and macOS TestFlight builds after App Store Connect credentials are configured.

## Phase 6 - Android MVP

Цель: Android client с общей KMP логикой и native VPN layer.

Status 2026-06-06: first Android native UI shell, in-app diagnostics log with Copy/Share/Clear, safe `VpnService` lifecycle, `gomobile` AAR bridge, socket protection, profile-route wiring, Android TUN fd attach, UAPI mapping, imported-profile emulator smoke, release-safe `vkturnproxy://import` deep links, signed release APK/AAB builds, release signing preflight, signed release emulator launch smoke, and signed release imported-profile smoke are added.

Задачи:

1. Создать Android app.
2. Подключить shared KMP.
3. Реализовать UI native Android.
4. Реализовать `VpnService`.
5. Выбрать bridge:
   - gomobile/JNI;
   - sidecar binary;
   - alternative only after spike.
6. Smoke test on Android emulator + physical device.

Acceptance:

- Android client connects through same server.
- Profile import/export совместим с iOS/macOS.
- Logs/events same schema as Apple clients.

Current verification:

- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :androidApp:assembleDebug` passed.
- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :androidApp:assembleRelease :androidApp:bundleRelease` passed.
- Debug APK installed on `Pixel_9_API_35` emulator.
- App launched successfully.
- UI tree confirmed status/import/validate controls.
- Empty validation interaction produced expected shared/state-holder error.
- `Start VPN` opened the Android system VPN permission dialog.
- After `OK`, app opened `tun0` with address `10.88.0.2/32`, MTU `1280`, and a narrow route `10.255.255.255/32`.
- UI showed `Interface active` and `Android VPN interface opened; Go bridge pending.`
- `Stop` closed the tunnel and UI returned to `Not connected`.
- Crash buffer had no `FATAL EXCEPTION`.
- `mobilebridge` Go package builds with `go test ./...`.
- `gomobile bind` produced `androidApp/libs/vkturnbridge.aar`.
- Android APK packages `lib/arm64-v8a/libgojni.so`.
- Android APK builds after linking the AAR.
- Go outbound sockets can be routed through `VpnService.protect(fd)` via `mobilebridge.SocketProtector`.
- Imported profile starts pass WireGuard UAPI, proxy JSON, interface address, DNS, and allowed routes to `AndroidVpnService`.
- No-profile emulator smoke still starts/stops the narrow-route TUN with no `FATAL EXCEPTION`.
- Imported-profile emulator smoke with a real iOS-derived profile reached:
  - full-route `tun0`;
  - VK/TURN bootstrap;
  - `SRTP+TURN session established`;
  - `mobilebridge: WireGuard attached`;
  - WireGuard handshake response;
  - clean `Stop` with `tun0` removed.
- `scripts/smoke-android-imported-profile.sh` automates the imported-profile emulator smoke and passed locally.
- Signed release artifacts exist:
  - `androidApp/build/outputs/apk/release/androidApp-release.apk`;
  - `androidApp/build/outputs/bundle/release/androidApp-release.aab`.
- Android release APK sha256: `c9d5a20717e95f2e5972be57c0cdd4db1cd894643eae9cc2a5afe39fc7831ac7`.
- Android release AAB sha256: `a38365739b2cf7caa4d10a0181d4edf2aea17d735f736160ea2203241c65593e`.
- Android diagnostics panel records status/profile events and supports Copy/Share/Clear for physical-device smoke artifacts.
- Local Android release signing exists:
  - `androidApp/signing.properties`;
  - `androidApp/keystore/vk-turn-proxy-release.jks`;
  - key alias `vk-turn-proxy-release`;
  - certificate SHA-256 fingerprint `8E:C1:C3:75:88:CF:0F:A8:38:B9:13:99:9E:03:D1:D8:AA:FF:A9:2E:92:D9:53:B3:CD:2A:BB:CB:6B:5A:C8:0E`.
- `scripts/preflight-android-release.sh` passed with zero warnings.
- `apksigner verify --print-certs androidApp/build/outputs/apk/release/androidApp-release.apk` passed.
- `jarsigner -verify -certs -verbose androidApp/build/outputs/bundle/release/androidApp-release.aab` passed.
- Signed release APK launch smoke on headless `Pixel_9_API_35` passed:
  - installed `androidApp-release.apk`;
  - launched `com.vkturnproxy.android/.MainActivity`;
  - UI tree contained `VK Turn Proxy`, `Import profile`, and `Start VPN`;
  - crash buffer had no `FATAL EXCEPTION`.
- Release-safe `vkturnproxy://import?data=...` deep links open `MainActivity`, populate the import field, and validate the profile automatically.
- `scripts/smoke-android-release-imported-profile.sh` passed on headless `Pixel_9_API_35`:
  - installed signed release APK;
  - opened the profile via `vkturnproxy://import`;
  - approved localized VPN permission;
  - observed `mobilebridge: WireGuard attached`;
  - stopped the VPN and verified cleanup.
- `scripts/smoke-android-release-imported-profile.sh` now accepts `IMPORT_LINK` and `PROFILE_FILE`, so physical-device smoke can use an exported full backup or connection JSON without reading the macOS iOS preferences plist.
- Android release smoke now rewrites `peerAddress` inside `PROFILE_FILE` JSON and `vkturnproxy://import?data=...` links when `PEER_ADDRESS` is set, so public second-port smoke cannot accidentally test production `56004`.
- `scripts/smoke-android-release-imported-profile.sh` writes a bounded evidence directory with summary, APK sha256, UI dumps, filtered logcat, package info, and connectivity snapshots; `REQUIRE_PHYSICAL_DEVICE=1` rejects emulator devices for the physical-release gate.
- `scripts/smoke-android-release-with-public-server.sh` keeps the temporary VPS public second-port server alive while `scripts/smoke-android-release-imported-profile.sh` runs, captures combined server/client evidence, stops the temporary server in cleanup, and refuses production port `56004`.
- `SERIAL=emulator-5554 ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk BUILD_RELEASE=0 scripts/smoke-android-release-imported-profile.sh` passed again after adding the Android diagnostics panel.
- `SERIAL=emulator-5554 ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk BUILD_RELEASE=0 NUM_CONNECTIONS=10 EVIDENCE_DIR=build/android-release-smoke/default10-emulator-v156 scripts/smoke-android-release-imported-profile.sh` passed for build 156 with the new fresh/default stability setting; evidence shows SRTP/TURN session establishment, WireGuard attach, active VPN network, and clean VPN stop.
- External smoke kit includes `commands/android-physical-smoke.sh`, which forces `REQUIRE_PHYSICAL_DEVICE=1` and prints `ANDROID_PHYSICAL_SMOKE_EVIDENCE=<dir>` after a passed physical-device smoke.

Remaining:

- Physical Android device smoke.

## Phase 7 - Windows Desktop MVP + Planning Spike

Цель: получить Windows-compatible desktop shell на shared KMP логике и выбрать реалистичный Windows VPN path.

Status 2026-06-06: desktop MVP shell, shared import/validation, Windows start-request generation, CLI preflight, service command generation, desktop tests, desktop-managed service Start/Status/Stop/Logs controls, Windows service executable, service request validation, named-pipe start/stop/status/log export control API, VK/TURN bootstrap runner, Wintun/wireguard-go attach path, route/DNS setup, Windows runtime package with idempotent PowerShell service install/update helpers, one-command Windows runtime smoke/evidence script, and Inno Setup EXE installer source/script are added; Windows host runtime smoke and installer build/sign smoke remain.

Задачи:

1. Добавить `desktopApp` JVM module.
2. Подключить shared KMP import/validation.
3. Добавить desktop UI для full backup / `vkturnproxy://` import.
4. Проверить build/distribution artifacts.
5. Добавить CLI/preflight для Windows service handoff.
6. Проверить Wintun + wireguard-go integration.
7. Проверить Go sidecar/service model.
8. Оценить installer/signing requirements.

Acceptance:

- Есть technical decision doc.
- Есть Windows-compatible desktop MVP на shared логике.
- Есть typed start-request contract for privileged service или clear blocker list для VPN layer.

Current verification:

- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :desktopApp:build` passed.
- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :desktopApp:test :desktopApp:build` passed.
- `ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk ./gradlew :shared:allTests :androidApp:assembleDebug :desktopApp:build` passed after moving runtime payload mapping into shared.
- Produced `desktopApp/build/distributions/desktopApp.zip`.
- Added `docs/WINDOWS_IMPLEMENTATION_PLAN.md`.
- Added shared `ProfileRuntimeMapper` for WireGuard UAPI/proxy JSON payloads used by Android and future Windows service code.
- Added `WindowsTunnelRuntime` and `WindowsTunnelStartRequest` so desktop GUI/CLI can prepare the payload a privileged Windows service should consume.
- Added desktop CLI:
  - `validate`;
  - `windows-start-request`;
  - `windows-preflight`;
  - `windows-service-commands`;
  - `windows-control-start`;
  - `windows-control-status`;
  - `windows-control-stop`.
- Added desktop window service controls:
  - service executable path discovery/configuration;
  - Browse selector;
  - Start writes `~/.vkturnproxy/windows/start-request.json` and calls the service control client;
  - Status and Stop call the same service control client.
- Added `scripts/preflight-windows-desktop.sh`.
- `ALLOW_EXTERNAL_BLOCKERS=1 ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk scripts/preflight-windows-desktop.sh` passed with the non-Windows host blocker downgraded; service executable path exists.
- Windows runtime zip includes `smoke-windows-runtime.ps1`; on a Windows host it validates prerequisites, installs/updates the service, starts the tunnel, waits for `wireguard_attached`, exports timestamped evidence, and stops the tunnel by default.
- Windows runtime zip includes `install-wintun.ps1`; it downloads official signed Wintun `0.14.1`, verifies SHA-256 `07c256185d6ee3652e09fa55c0b673e2624b565e02c4b9091c79ca7d2f24ef51`, and installs `wintun.dll` beside the service executable.
- `scripts/final-release-readiness.sh <tag>` requires Windows runtime smoke evidence and Windows installer build/sign/install evidence before final release readiness can pass.
- Added `cmd/vk-turn-proxy-windows-service` and `internal/windowstunnel`.
- Added `scripts/build-windows-service.sh`.
- `go test ./internal/windowstunnel ./cmd/vk-turn-proxy-windows-service` passed.
- `scripts/build-windows-service.sh` produced `build/windows/vk-turn-proxy-windows-service.exe`.
- Windows service executable sha256 is printed by the build/preflight script; use the runtime zip checksum from `build/release/<tag>-cross-platform-sha256.txt` for release tracking because the PE hash can change across rebuilds.
- `go run ./cmd/vk-turn-proxy-windows-service -mode validate -request <sample-start-request.json>` passed.
- Updated Windows preflight now cross-builds the service executable and verifies that the path exists.
- Added Windows-only Wintun/wireguard-go attach path:
  - `tun.CreateTUN`;
  - `netsh` interface address/DNS/route setup;
  - `device.IpcSet`;
  - `device.Up`;
  - route and device cleanup on stop.
- Added Windows named-pipe service control:
  - service mode without `-request` listens on `\\.\pipe\VKTurnProxyTunnel`;
  - `-mode control-start -request <path>` starts the active tunnel through the running service;
  - `-mode control-status` returns status JSON;
  - `-mode control-stop` stops the active tunnel and lets the service stay installed/running.
  - `-mode control-logs` returns status JSON plus a bounded service log tail.
- `scripts/package-windows-runtime.sh` produced `build/windows-package/vk-turn-proxy-windows-runtime.zip`.
- Windows runtime package now includes:
  - `lib/common.ps1`;
  - `test-prereqs.ps1`;
  - `install-wintun.ps1` for official Wintun download and SHA-256 verification;
  - idempotent `install-service.ps1` that installs or updates `VKTurnProxyTunnel`;
  - Administrator and `wintun.dll` prerequisite checks;
  - `status-tunnel.ps1` and `export-logs.ps1` fallbacks when the service is stopped.
- Windows runtime package checksum is recorded in the generated release checksum manifest because the zip is rebuilt per release package run.
- Release checksum manifests are written through `scripts/release-manifest-lib.sh` and use repo-relative paths; `scripts/test-release-manifest-format.sh` covers this in the local readiness gate.
- External smoke kit includes Windows runtime/installer templates plus `final-readiness.env.example`, so Windows evidence paths can be collected into the same final readiness command.
- Added Windows EXE installer packaging:
  - `packaging/windows/inno/vk-turn-proxy.iss.tpl`;
  - `scripts/package-windows-installer.ps1`;
  - supports Inno Setup 6 build and optional Authenticode signing through `signtool`;
  - `scripts/package-release-artifacts.sh` attaches the setup EXE when it exists under `build/windows-installer/`;
  - local sanity check `scripts/test-windows-installer-packaging.sh` is part of the readiness gate.

Remaining:

- Run real Windows service smoke on a Windows host.
- Build/sign/install the Windows EXE installer on a Windows host.

## Immediate Next Tasks

1. Run Android release smoke through `scripts/smoke-android-release-with-public-server.sh` on a booted emulator, then repeat on a physical Android device with `REQUIRE_PHYSICAL_DEVICE=1`.
2. Run physical iPhone smoke with the current Network Extension build.
3. Run `desktopApp` and `vk-turn-proxy-windows-service.exe` on a Windows host, verify current profile import, validate `start-request.json`, and run strict `windows-preflight --service-exe <path>`.
4. Install/create an `Apple Distribution` signing identity and remove the revoked development identity from keychain.
5. Prepare `VKTurnProxy/AppStoreConnect.env` with `scripts/configure-testflight-env.sh` and run `scripts/preflight-testflight.sh`.
6. Re-run `scripts/local-readiness-gate.sh` after external signing setup.
7. Run `scripts/release-blockers-status.sh v1.0-build167` to confirm the remaining external blockers before final smoke collection.
8. Run the external smokes and save evidence paths for Android physical, iPhone TestFlight, signed macOS Packet Tunnel, Windows runtime, Windows installer, and production server/client smoke.
9. Run `scripts/final-release-readiness.sh <tag>` with the evidence environment variables set.
10. Run `./release.sh <tag> all` after final readiness passes; it uploads iOS/macOS to TestFlight and attaches Android APK/AAB, Windows runtime zip, optional Windows setup EXE, Linux server package, cross-platform checksum manifest, and full release checksum manifest to GitHub Release.
11. Decide whether to promote the hardened server to production `56004`; public second-port Android emulator smoke has passed, but final readiness requires production-port smoke evidence after promote.
