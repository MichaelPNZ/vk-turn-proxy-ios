# Server Baseline - 142.252.220.91

Date: 2026-06-05

## What Is Known From Client Logs

The exported iOS runtime log repeatedly shows:

```text
peer_addr=142.252.220.91:56004
use_srtp=true
use_dtls=true
num_conns=30
cred_pool_cooldown_seconds=150
```

Transport varies by build/session:

- older sessions: `use_udp=false`;
- newer sessions: `use_udp=true`.

This means the currently used production server endpoint for the iOS client is:

```text
142.252.220.91:56004
```

## External Read-Only Probe

Performed from local machine:

```bash
nc -vz -w 3 142.252.220.91 22
nc -vz -w 3 142.252.220.91 443
nc -vz -w 3 142.252.220.91 56004
nc -vzu -w 3 142.252.220.91 56004
```

Observed:

- TCP 22 accepts connections.
- TCP 443 accepts connections.
- TCP 56004 accepts connections.
- UDP 56004 did not return an immediate ICMP reject via `nc`.

Important: UDP `nc` success is weak evidence. It does not prove that the TURN proxy protocol is healthy. A real server audit needs SSH and service/log inspection.

## Upstream Server Baseline

The iOS fork copied here does not contain a production server daemon. It only contains test tools:

- `tools/turn_bw_server`
- `tools/turn_srtp_server`
- `tools/wrapa_test`

The upstream `cacggghp/vk-turn-proxy` repository at HEAD `e8a96967dc66f3dbd631596ea6a8b9fe03f9be69` contains:

- `server/main.go`
- `client/main.go`
- `Dockerfile`
- README systemd example

The upstream server is a compact DTLS listener that forwards traffic to a configured backend:

```bash
./server -listen 0.0.0.0:56000 -connect 127.0.0.1:<wg_port>
```

It currently lacks production hardening we need for this fork:

- structured logs;
- health/readiness endpoint;
- metrics;
- explicit config file/env model;
- session registry;
- safe graceful shutdown reporting;
- deploy backup/rollback script;
- systemd unit owned by this fork;
- compatibility gates for SRTP/WRAP-A/probe-echo behavior used by this iOS fork.

## Required SSH Read-Only Audit

Before changing production on `142.252.220.91`, collect:

```bash
hostname
date
uname -a
id
systemctl --no-pager --type=service --state=running
systemctl --no-pager status vk-turn-proxy '*turn*' '*wg*'
ss -lntup
ip addr
ip route
wg show
iptables-save
nft list ruleset
ps auxww | egrep 'vk|turn|wireguard|wg|server-linux|xray' | grep -v egrep
journalctl -u vk-turn-proxy --since '24 hours ago' --no-pager
```

If the service name is different, find it from `ss -lntup` and `ps auxww` first.

## Safe Server Plan

1. Do SSH read-only audit and save `docs/SERVER_AUDIT_142_252_220_91.md`.
2. Copy current production binary, unit and env/config before any deploy.
3. Build a fork-owned server under `server/` or `cmd/vk-turn-proxy-server/`.
4. Keep current protocol and port `56004` unchanged for existing clients.
5. Add health/metrics on a separate localhost/admin port.
6. Dry-run deploy to a second port first.
7. Only then switch production service with one-command rollback.
