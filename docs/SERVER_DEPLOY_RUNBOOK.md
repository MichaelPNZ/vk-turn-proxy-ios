# Server Deploy Runbook

Target host: `142.252.220.91`

Production service must stay on `56004` until a controlled second-port client test passes.

## Files

- Binary: `/usr/local/bin/vk-turn-proxy-server`
- Staged binary: `/usr/local/bin/vk-turn-proxy-server.next`
- Service: `/etc/systemd/system/vk-turn-proxy-ios.service`
- Env: `/etc/vk-turn-proxy-ios.env`
- Log: `/var/log/vk-turn-proxy-ios.log`
- Logrotate: `/etc/logrotate.d/vk-turn-proxy-ios`
- Backups: `/var/backups/vk-turn-proxy-ios/<timestamp>/`

## Local Package

```bash
scripts/package-server.sh
```

This builds:

- `build/server/vk-turn-proxy-server-linux-amd64`
- `build/server/vk-turn-proxy-server-linux-amd64.sha256`
- `build/server/vk-turn-proxy-server-<version>-linux-amd64.tar.gz`

## VPS Dry Run

Dry run uploads the package and starts a short-lived process on localhost-only ports.
It does not touch production `56004`.
The script refuses to run if `DRY_LISTEN` uses production port `56004`.

```bash
MODE=dry-run SSH_USER=root HOST=142.252.220.91 scripts/deploy-server-vps.sh
```

Default dry-run ports:

- SRTP: `127.0.0.1:56014`
- admin HTTP: `127.0.0.1:56085`
- WireGuard backend: `127.0.0.1:51820`

Expected:

- `/healthz` returns `ok`
- `/readyz` returns `ready`
- `/metrics` prints Prometheus-style counters

Last verified on 2026-06-06:

- package: `build/server/vk-turn-proxy-server-7189d29-linux-amd64.tar.gz`
- sha256: `c5700a6b8e2f7a48e890c0eeb23e096f35b53d497dd9f819a5175b846085b44b`
- package format: `ustar`, no pax/xattr headers
- dry-run response: `ok`, `ready`, metrics counters
- dry-run log: `listening on 127.0.0.1:56014 (srtp) -> 127.0.0.1:51820`
- production check after dry-run: only UDP `*:56004` remained listening; dry-run ports were not left running

## Install Staged

Installs the new binary and deploy metadata into staging paths without restarting production.

```bash
MODE=install-staged SSH_USER=root HOST=142.252.220.91 scripts/deploy-server-vps.sh
```

Expected staged files:

- `/usr/local/bin/vk-turn-proxy-server.next`
- `/tmp/vk-turn-proxy-ios.service.next`
- `/tmp/vk-turn-proxy-ios.logrotate.next`

## Controlled Client Test

Before promoting production `56004`, run one client against a public second port.

Use the public smoke helper:

```bash
ACTION=start \
  SSH_USER=root \
  HOST=142.252.220.91 \
  PUBLIC_LISTEN=0.0.0.0:56014 \
  PUBLIC_HEALTH=127.0.0.1:56085 \
  scripts/server-public-smoke-vps.sh
```

Then import a test profile pointing at:

```text
142.252.220.91:56014
```

For the Android emulator smoke script, override only the peer address:

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  PEER_ADDRESS=142.252.220.91:56014 \
  scripts/smoke-android-imported-profile.sh
```

Inspect the temporary server:

```bash
ACTION=status SSH_USER=root HOST=142.252.220.91 scripts/server-public-smoke-vps.sh
ACTION=logs SSH_USER=root HOST=142.252.220.91 scripts/server-public-smoke-vps.sh
```

Always stop it after the client test:

```bash
ACTION=stop SSH_USER=root HOST=142.252.220.91 scripts/server-public-smoke-vps.sh
```

Promote only after the client reaches a real WireGuard handshake and traffic passes.

Last public second-port server helper verification on 2026-06-06:

- `ACTION=start` opened UDP `*:56014` and admin `127.0.0.1:56085`;
- `ACTION=status` returned `ok`, `ready`, and showed the listener;
- `ACTION=logs` showed `listening on [::]:56014 (srtp) -> 127.0.0.1:51820`;
- `ACTION=stop` removed the temporary listener;
- post-stop server check showed only production UDP `*:56004`.

The server binary also has a built-in concurrent-session guard:

```bash
-max-sessions 1024
```

This flag defaults to `1024`. Keep the default unless production metrics show real pressure; setting it to `0` disables the guard. The packaged systemd unit currently relies on the binary default so existing production env files do not need an immediate edit.

Last Android client verification on public second port on 2026-06-06:

- command: `PEER_ADDRESS=142.252.220.91:56014 scripts/smoke-android-imported-profile.sh`;
- result: `Android imported-profile smoke passed.`;
- Android logcat showed `SRTP+TURN session established`;
- Android logcat showed `mobilebridge: WireGuard attached handle=1`;
- WireGuard log showed `Received handshake response`;
- post-stop Android connectivity dump no longer showed the app VPN/tun0;
- temporary server was stopped after the test.

## Current Production Baseline

Before promote, collect read-only evidence from the currently running production
service:

```bash
MODE=baseline \
HOST=142.252.220.91 \
SSH_USER=root \
scripts/collect-server-production-evidence.sh \
  build/evidence/server-production-baseline-<date>
```

Expected for the existing legacy service:

- `systemctl is-active vk-turn-proxy-ios.service` returns `active`
- listener evidence shows UDP `:56004`
- health files may show connection refused if the old binary/unit has no
  `-health-listen`
- `summary.txt` contains `evidence_type=server_production_baseline`
- `summary.txt` and `server-status.txt` include machine-readable fields:
  `service`, `listener_56004`, `listener_56080`, `healthz`, `readyz`, and
  `metrics`

This baseline is useful for audit and rollback context. It does not satisfy
`SERVER_PRODUCTION_SMOKE_EVIDENCE` in final readiness.

Last read-only production baseline on 2026-06-06:

- command: `MODE=baseline HOST=142.252.220.91 SSH_USER=root scripts/collect-server-production-evidence.sh build/evidence/server-production-baseline-2026-06-06-current`;
- result: `summary.txt` has `result=passed`, `evidence_type=server_production_baseline`, and `attachment_count=9`;
- service: `systemctl-is-active.txt` returned `active`;
- listener: `listeners.txt` showed UDP `*:56004` owned by `vk-turn-proxy-s`;
- health: `healthz.txt` and `readyz.txt` show connection refused on `127.0.0.1:56080`, which matches the current legacy service without admin health;
- current production binary sha256: `275ff8e9308392620b424ad59ce8ba095e5f4872f5de9cd4b9baa7fc37dfaf23`;
- current production unit sha256: `83e58992c30031e8c0fd6215f6c87b6d5bec55a9696d96b0266ee93bb024b28c`.

Fresh read-only production baseline on 2026-06-07:

- command: `MODE=baseline HOST=142.252.220.91 SSH_USER=root scripts/collect-server-production-evidence.sh build/evidence/server-production-baseline-2026-06-07-status-fields`;
- result: `summary.txt` has `result=passed`, `evidence_type=server_production_baseline`, and `attachment_count=10`;
- status fields: `service=active`, `listener_56004=present`, `listener_56080=missing`, `healthz=missing`, `readyz=missing`, `metrics=missing`;
- production service remains the legacy running service without admin health on `127.0.0.1:56080`.

## Promote

Promote backs up the current binary/unit/env/logrotate, installs the staged
binary and service files, restarts systemd, and checks local health. If
post-promote health fails, the deploy script automatically restores the same
backup, restarts the old service, and writes rollback evidence before exiting
non-zero.

```bash
CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004 \
  MODE=promote \
  SSH_USER=root \
  HOST=142.252.220.91 \
  scripts/deploy-server-vps.sh
```

Expected:

- `systemctl is-active vk-turn-proxy-ios.service` succeeds
- `http://127.0.0.1:56080/healthz` returns `ok`
- `http://127.0.0.1:56080/readyz` returns `ready`
- promote output prints `promoted_backup=/var/backups/vk-turn-proxy-ios/<timestamp>`
- backup directory contains `before-promote.txt` and `after-promote.txt` with sha256, systemd status, and listener evidence

Failure behavior:

- failed post-promote health writes `failed-promote.txt`
- automatic rollback writes `after-auto-rollback.txt`
- stderr prints `auto_rolled_back_from=/var/backups/vk-turn-proxy-ios/<timestamp>`

After the production-port client smoke passes, copy the promote backup evidence,
production-port client smoke logs, and rollback timestamp into an evidence
directory. The read-only collector can gather production health/listener/status
evidence and write the final readiness summary:

```bash
MODE=final \
BACKUP_DIR=/var/backups/vk-turn-proxy-ios/<timestamp> \
CLIENT_SMOKE_LOG=/absolute/path/to/production-client-smoke.log \
HOST=142.252.220.91 \
SSH_USER=root \
scripts/collect-server-production-evidence.sh \
  build/evidence/server-production-<date>
```

Use that directory as `SERVER_PRODUCTION_SMOKE_EVIDENCE` for
`scripts/final-release-readiness.sh`.
The directory must contain at least one supporting file besides `summary.txt`;
include the production-port client smoke output and promote backup evidence.
`CLIENT_SMOKE_LOG` is required in `MODE=final`.
The collector is read-only: it does not promote, rollback, restart, or edit
production.

## Rollback

Rollback restores the latest backup and restarts the service.

```bash
MODE=rollback SSH_USER=root HOST=142.252.220.91 scripts/deploy-server-vps.sh
```

After rollback, verify:

```bash
ssh root@142.252.220.91 'systemctl status vk-turn-proxy-ios.service --no-pager'
```

## Safety Rules

- Do not promote before a second-port client test.
- `MODE=promote` intentionally requires `CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004`.
- Do not edit `/etc/vk-turn-proxy-ios.env` from scripts except creating it from the example when absent.
- Keep `VKTURN_CONNECT=127.0.0.1:51820` unless the WireGuard backend changes.
- Keep health/admin bind on localhost.
- Preserve backup timestamp from promote output.
