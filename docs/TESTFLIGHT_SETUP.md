# TestFlight Setup

This project uploads iOS and macOS builds through `release.sh`.

## Required Local Secrets

Create an App Store Connect API key with access to upload builds. Keep the `.p8`
file outside the repository when possible.

Generate the ignored env file:

```bash
scripts/configure-testflight-env.sh \
  --key-id ABCDE12345 \
  --issuer-id 00000000-0000-0000-0000-000000000000 \
  --key-path /absolute/path/to/AuthKey_ABCDE12345.p8
```

The script writes `VKTurnProxy/AppStoreConnect.env` with mode `0600`.

## Required Signing State

Install a valid Apple Distribution certificate/private key in the login
keychain. Then remove revoked code-signing identities so Xcode cannot select
the wrong certificate.

Install distribution provisioning profiles for every bundle id used by the
TestFlight build:

- `com.vkturnproxy.app`
- `com.vkturnproxy.app.tunnel`
- `com.vkturnproxy.mac`
- `com.vkturnproxy.mac.tunnel`

The profiles must be App Store/TestFlight distribution profiles
(`get-task-allow=false`). Development profiles are not enough for the release
archive/upload path.

Check current project-side readiness:

```bash
scripts/preflight-testflight.sh v1.0-build156
```

Inspect local signing state without modifying keychain or profiles:

```bash
scripts/diagnose-apple-signing.sh
```

Collect a read-only evidence directory with machine-readable summary, blockers,
bundle ids, profile matches, and next commands:

```bash
scripts/collect-apple-signing-evidence.sh \
  build/evidence/apple-signing-current
```

The collector writes:

- `summary.txt` with `evidence_type=apple_signing_readiness`
- `blockers.txt`
- `bundle-ids.txt`
- `provisioning-profiles.tsv`
- `appstore-connect-env.txt`
- `code-signing-identities.txt`
- `next-commands.txt`

Last collected on 2026-06-06:

- evidence directory: `build/evidence/apple-signing-2026-06-06-current`;
- `summary.txt`: `result=blocked`, `blocker_count=6`, `testflight_ready=false`;
- blockers:
  - missing `VKTurnProxy/AppStoreConnect.env`;
  - missing Apple Distribution signing identity;
  - no provisioning profile matches `com.vkturnproxy.app`;
  - no provisioning profile matches `com.vkturnproxy.app.tunnel`;
  - no provisioning profile matches `com.vkturnproxy.mac`;
  - no provisioning profile matches `com.vkturnproxy.mac.tunnel`;
- keychain also contains one revoked Apple Development identity, so remove it before signing.

If only external setup remains and you want a local gate without failing on
missing credentials:

```bash
ALLOW_EXTERNAL_BLOCKERS=1 scripts/preflight-testflight.sh v1.0-build156
```

## Release

After the working tree is committed or stashed, the tag exists locally, App
Store Connect env is configured, and Apple Distribution signing is valid:

```bash
./release.sh v1.0-build156 all
```

`all` uploads iOS and macOS to TestFlight and attaches Android, Windows, server,
and checksum artifacts to the GitHub Release.

## Smoke Evidence

After a real iPhone TestFlight Network Extension smoke, export the in-app VPN
log or save a screenshot/transcript, then collect evidence:

```bash
scripts/collect-apple-smoke-evidence.sh \
  iphone \
  build/evidence/iphone-testflight-<date> \
  --file /absolute/path/to/vpn-export.log \
  --note "iPhone TestFlight tunnel connected and disconnected cleanly"
```

After a signed macOS Packet Tunnel smoke, collect local macOS logs and App Group
`vpn.log` / `vpn.log.1` when present:

```bash
scripts/collect-apple-smoke-evidence.sh \
  macos \
  build/evidence/macos-testflight-<date> \
  --last 30m \
  --note "macOS TestFlight Packet Tunnel connected and disconnected cleanly"
```

Use those directories as `IPHONE_TESTFLIGHT_SMOKE_EVIDENCE` and
`MACOS_TESTFLIGHT_SMOKE_EVIDENCE` for `scripts/final-release-readiness.sh`.
Each directory must contain at least one supporting file besides `summary.txt`.
If you need to write a summary manually after copying supporting files, use
`scripts/write-smoke-evidence-summary.sh` with
`iphone_testflight_network_extension` or `macos_testflight_packet_tunnel`.
