# VK TURN Proxy KMP Architecture

## Цель

Сделать форк `anton48/vk-turn-proxy-ios` как мультиплатформенный продукт:

- iOS и macOS распространяются через TestFlight.
- Android получает отдельный native client.
- Windows получает desktop MVP для shared import/validation; полноценный VPN layer идет через отдельный privileged service на Wintun + wireguard-go.
- Серверная часть становится стабильнее, наблюдаемее и безопаснее для rolling updates.

Главное архитектурное решение: **KMP используется для общей бизнес-логики, UI остается нативным**.

KMP не должен владеть VPN/TUN, Network Extension, Wintun, WireGuard device lifecycle или Go TURN transport. Эти части завязаны на системные API и должны оставаться платформенными.

## Текущий базовый проект

Исходная кодовая база:

- `VKTurnProxy/` - iOS SwiftUI app + PacketTunnel extension.
- `WireGuardBridge/` - Go to C bridge, сборка `WireGuardTURN.xcframework`.
- `pkg/proxy/` - Go TURN/DTLS/SRTP/WRAP-A transport, VK credentials, captcha flow.
- `pkg/turnbind/` - WireGuard bind layer.
- `tools/` - тестовые и диагностические Go utilities.

Серверный daemon в текущем iOS-форке не является полной production-серверной базой. Для server fork/hardening нужно учитывать upstream `cacggghp/vk-turn-proxy`, где есть `server/main.go`, Dockerfile, systemd-пример и базовый UDP forwarder к WireGuard.

## Целевая структура репозитория

Планируемая структура:

```text
.
├── apps/
│   ├── ios/                    # SwiftUI app + Network Extension
│   ├── macos/                  # SwiftUI/AppKit app + Network Extension/System Extension
│   ├── android/                # Native Android app, Jetpack Compose допустим
│   └── windows/                # Desktop shell + future native service
├── shared/
│   ├── core/                   # Kotlin Multiplatform shared business logic
│   ├── models/                 # Common profile/config/state models
│   ├── storage/                # expect/actual storage ports
│   ├── diagnostics/            # events, log parsing, health snapshots
│   └── serverapi/              # server health/config API clients
├── native/
│   ├── go-transport/           # current Go proxy/turnbind/WireGuard bridge
│   ├── ios-bridge/             # C headers / XCFramework integration
│   ├── android-bridge/         # gomobile/JNI integration
│   └── desktop-bridge/         # macOS/Windows service/bridge integration
├── server/
│   ├── cmd/vk-turn-proxy-server/
│   ├── internal/
│   ├── deploy/
│   └── docs/
├── docs/
└── tools/
```

Не нужно переехать в эту структуру одним коммитом. Сначала добавляется `shared/`, затем переносится только общий код, после этого аккуратно раскладываются apps/native/server.

## Стек

### Shared/KMP

- Kotlin Multiplatform.
- Kotlinx Serialization для config/profile JSON.
- Kotlinx Coroutines/Flow для state stream.
- Ktor client для health/API вызовов, если серверный API будет добавлен.
- SQLDelight или platform storage abstraction. На старте лучше abstraction без тяжелой DB.
- Kotlin test для shared unit tests.

### iOS

- SwiftUI.
- NetworkExtension: `NETunnelProviderManager`, `NEPacketTunnelProvider`.
- Go bridge через XCFramework.
- App Group для shared logs/credentials/config между app и extension.
- TestFlight distribution.

### macOS

- SwiftUI или AppKit там, где SwiftUI ограничивает системные flows.
- Network Extension/System Extension по capability.
- Go bridge через macOS framework/static library.
- TestFlight distribution через App Store Connect.

### Android

- Kotlin.
- Native Android UI, Jetpack Compose допустим.
- `VpnService`.
- Go bridge через gomobile/JNI или sidecar binary, решение после spike.

### Windows

- Kotlin/JVM desktop MVP module: `desktopApp`.
- Swing system-look-and-feel UI for import/validation while the Windows native shell/service is designed.
- Wintun + wireguard-go service.
- Native shell + service.
- KMP shared logic может использоваться, VPN layer отдельный.

### Server

- Go.
- systemd и/или Docker.
- WireGuard backend stays local, server forwards decrypted DTLS/TURN packets to it.
- Structured logs.
- Health/readiness endpoint.
- Metrics endpoint.
- Safe deploy scripts.

## Архитектура KMP-приложения

### Что живет в `shared`

`shared` отвечает только за переносимую логику:

- `Profile` - пользовательский профиль подключения.
- `WireGuardConfig` - parsed/normalized WG config.
- `ProxyConfig` - VK link, peer address, transport mode, conn count, TURN overrides.
- `ConnectionState` - disconnected/connecting/captcha/connected/degraded/error.
- `ConnectionIntent` - connect/disconnect/reconnect/solve captcha/import profile.
- `ConnectionPolicy` - retry/backoff/timeout rules.
- `DiagnosticsEvent` - machine-readable logs/events.
- `ServerHealthSnapshot` - состояние сервера и совместимость клиента.
- `ConfigValidator` - validation без platform APIs.
- `ProfileRepository` interface - storage port.
- `TransportController` interface - platform tunnel port.

### Что живет на платформе

Платформа реализует:

- запуск/остановку VPN tunnel;
- выдачу TUN fd;
- lifecycle Network Extension / VpnService / desktop service;
- entitlement/capability checks;
- secure storage;
- UI;
- platform logging;
- сборку native Go bridge.

### Контракт между KMP и платформой

KMP не вызывает системный VPN API напрямую. Вместо этого:

```kotlin
interface TransportController {
    val state: Flow<ConnectionState>
    suspend fun connect(profileId: ProfileId)
    suspend fun disconnect()
    suspend fun reconnect(reason: ReconnectReason)
    suspend fun submitCaptcha(token: String)
    suspend fun collectDiagnostics(): DiagnosticsBundle
}
```

Platform app реализует `TransportController`, а KMP state machine принимает события и обновляет common state.

## Server Architecture

Минимальный production server fork:

- `cmd/vk-turn-proxy-server` - binary entrypoint.
- `internal/config` - flags/env/file config.
- `internal/relay` - DTLS/SRTP/WRAP transport listener.
- `internal/backend` - WireGuard UDP backend forwarding.
- `internal/session` - session registry, limits, stats.
- `internal/health` - HTTP health/readiness/metrics.
- `internal/logging` - structured logging.
- `deploy/systemd` - unit, env file, tmpfiles/logrotate.
- `deploy/docker` - image and compose examples.

Сервер должен быть обратно совместим с текущими клиентами на `142.252.220.91`. Любые новые режимы включаются флагами, старый порт не ломается.

## Development Rules

1. Сначала совместимость, потом рефакторинг.
2. Не переписывать Go transport на Kotlin без отдельного spike и benchmark.
3. Не смешивать shared KMP logic с платформенными VPN APIs.
4. Любой server change должен иметь rollback path.
5. Любой client change должен сохранять импорт старого profile/backup JSON.
6. iOS/macOS TestFlight builds проходят smoke на реальном устройстве до внешнего теста.
7. Logs/events должны быть machine-readable: стабильные event names, timestamps, session id, build version.
8. Secrets, VK links, WireGuard private keys и captcha tokens не пишутся в plain logs.
9. Network Extension memory budget важнее красивой архитектуры: heavy logic не тащить в extension.
10. Server deploy на production VPS сначала read-only audit, потом staged rollout.
11. Shared models versioned: config schema version обязателен.
12. Tests обязательны для validators, parsers, profile migration и retry policy.

## Release Rules

### iOS/macOS

- Только TestFlight на Apple targets.
- Build number синхронизируется между app, extension и Go bridge logs.
- External TestFlight build может требовать beta review.
- Entitlements проверяются до начала feature work.

### Server

- Production server на `142.252.220.91` не трогать без fresh audit.
- Перед deploy: backup current binary/unit/config, record listening ports, record WireGuard backend port.
- Deploy должен поддерживать rollback одной командой.
- Health check после deploy обязателен.
