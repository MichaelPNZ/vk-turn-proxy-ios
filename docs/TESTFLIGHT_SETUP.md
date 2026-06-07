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
`scripts/preflight-testflight.sh` and
`scripts/collect-apple-signing-evidence.sh` require:

- `APPSTORE_KEY_ID`: 10 uppercase alphanumeric characters.
- `APPSTORE_ISSUER_ID`: UUID.
- `APPSTORE_KEY_PATH`: absolute path to an existing `.p8` file.
- `.p8` file content contains `-----BEGIN PRIVATE KEY-----`.
- `VKTurnProxy/AppStoreConnect.env` file mode is `600`.

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
scripts/preflight-testflight.sh v1.0-build160
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
ALLOW_EXTERNAL_BLOCKERS=1 scripts/preflight-testflight.sh v1.0-build160
```

## Release

After the working tree is committed or stashed, the tag exists locally, App
Store Connect env is configured, and Apple Distribution signing is valid:

```bash
./release.sh v1.0-build160 all
```

`all` uploads iOS and macOS to TestFlight and attaches Android, Windows, server,
and checksum artifacts to the GitHub Release.

## GitHub Actions TestFlight Upload

The repository also has a manual/tag workflow:

- `.github/workflows/testflight-release.yml`
- `scripts/install-apple-signing-assets.sh`

Add these GitHub repository secrets before running it:

- `APPLE_DISTRIBUTION_CERT_P12_BASE64`
- `APPLE_DISTRIBUTION_CERT_PASSWORD`
- `APPLE_PROVISIONING_PROFILES_BASE64`
- `APPSTORE_KEY_ID`
- `APPSTORE_ISSUER_ID`
- `APPSTORE_CONNECT_API_KEY_P8_BASE64`

The safer one-command path is:

```bash
scripts/configure-github-testflight-secrets.sh \
  --cert-p12 /absolute/path/AppleDistribution.p12 \
  --cert-password '<p12 password>' \
  --profile /absolute/path/com.vkturnproxy.app.mobileprovision \
  --profile /absolute/path/com.vkturnproxy.app.tunnel.mobileprovision \
  --profile /absolute/path/com.vkturnproxy.mac.provisionprofile \
  --profile /absolute/path/com.vkturnproxy.mac.tunnel.provisionprofile \
  --appstore-key-id ABCDE12345 \
  --appstore-issuer-id 00000000-0000-0000-0000-000000000000 \
  --appstore-key-p8 /absolute/path/AuthKey_ABCDE12345.p8
```

If `VKTurnProxy/AppStoreConnect.env` already exists and the distribution
provisioning profiles are installed locally, use the shorter path:

```bash
scripts/configure-github-testflight-secrets.sh \
  --cert-p12 /absolute/path/AppleDistribution.p12 \
  --cert-password '<p12 password>' \
  --profiles-from-installed \
  --appstore-env VKTurnProxy/AppStoreConnect.env
```

`--appstore-env` reads `APPSTORE_KEY_ID`, `APPSTORE_ISSUER_ID`, and
`APPSTORE_KEY_PATH`. `--profiles-from-installed` scans
`~/Library/MobileDevice/Provisioning Profiles` and selects App Store
distribution profiles that match every bundle id in `VKTurnProxy/project.yml`.

The script validates the `.p8`, `.p12` password, provisioning profile decode,
bundle-id coverage, and App Store distribution profile type before writing any
GitHub secrets.

The helper validates inputs, creates temporary base64 payload files, writes the
six GitHub secrets with `gh secret set`, and removes the temporary payloads. It
does not print secret values. Use `DRY_RUN=1` to validate inputs and print only
secret names/sizes without writing repository secrets.

Manual setup is also possible:

Encode the signing assets without printing secret contents:

```bash
base64 -i /absolute/path/AppleDistribution.p12 | pbcopy
```

Create one zip that contains all four App Store/TestFlight distribution
profiles, then encode it:

```bash
zip -j /tmp/vk-turn-proxy-profiles.zip \
  /absolute/path/com.vkturnproxy.app.mobileprovision \
  /absolute/path/com.vkturnproxy.app.tunnel.mobileprovision \
  /absolute/path/com.vkturnproxy.mac.provisionprofile \
  /absolute/path/com.vkturnproxy.mac.tunnel.provisionprofile

base64 -i /tmp/vk-turn-proxy-profiles.zip | pbcopy
```

Encode the App Store Connect API key:

```bash
base64 -i /absolute/path/AuthKey_<APPSTORE_KEY_ID>.p8 | pbcopy
```

Run the workflow from GitHub Actions:

- workflow: `TestFlight Release`
- tag: `v1.0-build160`
- target: `all`, `ios`, or `macos`

Tag pushes matching `v*build*` also trigger the workflow. The workflow installs
Apple signing assets into a temporary keychain, writes ignored
`VKTurnProxy/AppStoreConnect.env`, runs `scripts/preflight-testflight.sh`, and
then runs `./release.sh <tag> <target>`.

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
