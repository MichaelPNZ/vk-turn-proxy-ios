# Runtime Log Analysis - vpn-export.log

Source log:

`/Users/mihailpozalov/Library/Containers/com.vkturnproxy.app/Data/tmp/vpn-export.log`

Analyzed on 2026-06-05.

## Scope

Log covers iOS builds 134, 154, and 155. It includes app process logs, PacketTunnel extension logs, Go bridge logs, TURN/SRTP session logs, credential pool logs, captcha/WebView logs, path monitoring, memory stats, and shutdown traces.

Sensitive values are intentionally not copied here.

## High-Signal Counts

- Total log lines: 81,143.
- `i/o timeout`: 5,480.
- `no such host`: 734.
- `Bad Request`: 88.
- `Allocation Quota`: 3.
- `freeze detected`: 122.
- `active probe ... no echo`: 13.
- `ForceReconnect`: 4.
- `StopWithTimeout`: 8.
- `VK Calls path failed`: 159.
- `all ... client_ids failed`: 1,514.
- `SRTP+TURN session established`: 133.
- `TURN relay allocated`: 140.

## Main Findings

### 1. Credential Fetch DNS Breaks After Tunnel Is Up

The strongest repeated failure is DNS/host resolution during VK credential refresh/fill after the tunnel is already active:

- `lookup api.vk.me: i/o timeout`
- `lookup login.vk.ru: i/o timeout`
- `lookup login.vk.ru: no such host`

The app pre-resolves `login.vk.ru`, `api.vk.ru`, and `id.vk.ru`, but `api.vk.me` is used by the VK Calls captcha-free path and is not in the pre-resolved host map. This creates a direct hole in the DNS bypass strategy.

Likely effect:

- First seeded TURN credential works.
- Initial 10 connections on one credential can establish.
- Background fill / extra connection slots fail because new credentials cannot be fetched reliably.
- `num_conns=30` becomes misleading: many runs operate with 10-20 useful conns, sometimes fewer.

Priority: P0.

Recommended fix:

- Add `api.vk.me` to pre-bootstrap host resolution.
- Ensure all VK credential/captcha HTTP clients use the pre-resolved IP dialer, not system DNS.
- Add metric/log field for `resolver_source=pre_resolved|system|direct_dns` per VK request.

### 2. Credential Pool Pressure With `num_conns=30`

The log repeatedly shows connection workers parking or failing because the credential pool cannot supply slots:

- `credpool: no slot available`
- `all saturated, cooling down, or fetching`
- `cold-start cap ... parking to share`

In build 155 the cold-start cap is better than earlier noisy failure loops, but the product config still says `num_conns=30` while actual active conns can remain around 10 unless background credentials fill successfully.

Likely effect:

- UI/user expects 30-way parallel tunnel.
- Runtime often has only the seeded slot active at first.
- DNS failures prevent pool fill, so scaling stalls.

Priority: P0/P1.

Recommended fix:

- UI should show actual active conns vs requested conns.
- Default `num_conns` should be adaptive, not fixed 30.
- Credential fetch failures should reduce target pressure temporarily.
- Pool fill should use separate backoff keyed by error class: DNS, captcha, quota, TURN auth, server.

### 3. iOS Freeze/Wake Recovery Still Hurts Connections

The log has many sleep/freeze indicators:

- `SRTP probe tick gap 6m14s (freeze detected)`
- `SRTP read elapsed 6m14s (freeze detected)`
- `active probe (post-wake) no echo within 30s, killing`
- `wake() - running fast-path health check`

The watchdog does recover some sessions, but it also kills/recreates several connections after wake. TURN refreshes then race with closed sockets and produce noisy Pion errors.

Priority: P1.

Recommended fix:

- Make wake recovery an explicit state machine:
  - freeze detected;
  - suppress normal refresh error accounting for a short grace window;
  - probe active conns;
  - replace only failed conns;
  - escalate to full reconnect only when quorum fails.
- Treat `use of closed network connection` during planned teardown as debug-level, not error-level.

### 4. TURN Permission Refresh Errors Are Real But Often Secondary

There are repeated Pion/TURN refresh failures:

- `Refresh allocation: 438, got new nonce`
- `Fail to refresh permissions`
- `CreatePermission error response (error 400: Bad Request)`
- `No transaction for Refresh error response`

Some happen during active reconnect/teardown and should not be counted as tunnel degradation. Others happen while sessions are live and may indicate stale peer permissions or TURN-side state drift.

Priority: P1.

Recommended fix:

- Classify refresh failures by lifecycle:
  - active session;
  - reconnecting;
  - stopping;
  - post-wake grace.
- Only active-session refresh failures should contribute to watchdog degradation.
- Add per-conn TURN refresh counters to diagnostics.

### 5. Stop Path Leaves Many Goroutines Alive

Shutdown often reaches timeout:

- `StopWithTimeout - 2s elapsed, 51-87 goroutines still alive`

The extension exits anyway, but this points to goroutines blocked on TURN/Pion reads, refresh timers, credential fetch, or teardown races.

Priority: P1/P2.

Recommended fix:

- Audit all goroutines started per connection.
- Add context cancellation to credential fetch and Pion refresh paths.
- Increase shutdown observability: dump goroutine categories, not only count.
- Make stop timeout configurable for debug builds.

### 6. Memory Looks Controlled In Build 155

Build 155 generally stays below the expected iOS Network Extension pressure line in observed windows:

- RSS mostly around 13-22 MB.
- Go soft cap: 35 MB.
- No direct jetsam crash in the final observed build 155 section.

Priority: P2.

Recommended fix:

- Keep memory diagnostics.
- Add high-water marks to export summary.
- Avoid increasing extension-side Kotlin/Swift shared logic; KMP must stay outside PacketTunnel hot path where possible.

## Product/Architecture Implications

For the KMP/native rewrite:

1. Shared KMP should own profile/config/diagnostic models, not transport.
2. Native transport layer needs a strict diagnostic contract:
   - requested conns;
   - active conns;
   - credential pool size/fill;
   - last VK credential fetch error class;
   - wake recovery state;
   - server peer address;
   - TURN relay address;
   - memory high-water mark.
3. UI must not show only "connected"; it must show degraded state when requested conns are not actually active.
4. Server hardening matters, but this log shows the biggest current instability is client-side DNS/credential lifecycle under iOS Network Extension constraints.

## Suggested Fix Order

1. Add `api.vk.me` to pre-resolved VK host list and route all VK credential requests through the pre-resolved IP dialer.
2. Add diagnostic summary export: active conns, requested conns, resolver failures, credential pool state, wake recovery events.
3. Make `num_conns` adaptive and honest in UI.
4. Rework wake recovery lifecycle to avoid counting planned teardown/refresh races as tunnel degradation.
5. Clean shutdown goroutines and classify Pion errors by lifecycle.
6. Then proceed with KMP shared module integration.

## Implemented In This Fork

2026-06-05:

- Added `api.vk.me` to the Swift main-app pre-resolved VK host list.
- Added an explicit public-DNS `net.Resolver` to all `bogdanfinn/tls-client` VK HTTP clients via `WithDialer`, preserving the existing TLS/browser fingerprint while avoiding iOS Network Extension system-DNS stalls.
- Added stats fields:
  - `requested_conns`
  - `vk_last_fetch_error`
  - `vk_last_fetch_error_at`
- Changed iOS stats UI to show `active/requested` connections and mark the tunnel as `degraded` when active connections are below requested connections.

Verification:

- `go test ./...` passed.
- `make xcframework` passed and produced `WireGuardBridge/build/WireGuardTURN.xcframework`.
- XcodeBuildMCP simulator build/run for scheme `VKTurnProxy` passed with `CODE_SIGNING_ALLOWED=NO`.

Remaining:

- Physical iPhone TestFlight/device smoke is still required because Network Extension tunnel behavior cannot be validated in Simulator.
- Runtime log export should be rechecked after an on-device session to confirm `api.vk.me` / `login.vk.ru` DNS failures drop.

2026-06-07:

- Added a global concurrent wake-probe limiter in the Go proxy:
  - cap is `ceil(NumConns/10)`, bounded to `1..6`;
  - `NumConns=30` now runs at most 3 post-wake active probes at once;
  - both DTLS and SRTP wake-probe paths use the limiter.
- Rationale from the same `vpn-export.log`: after wake, multiple active
  probes timed out in the same window, then many connection workers entered
  reconnect/dormancy together. The limiter reduces the blast radius of a
  false-positive or network-wide post-wake probe failure; skipped connections
  remain covered by the normal timer-based zombie detector and later wakes.
- Added unit coverage for wake-probe limit sizing and semaphore behavior.
