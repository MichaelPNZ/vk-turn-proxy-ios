# Android Release Signing

## Current Local Signing State

Local release signing is configured on this workstation.

- Signing config file: `androidApp/signing.properties`
- Keystore file: `androidApp/keystore/vk-turn-proxy-release.jks`
- Keystore format: PKCS12
- Key alias: `vk-turn-proxy-release`
- Certificate SHA-256 fingerprint: `8E:C1:C3:75:88:CF:0F:A8:38:B9:13:99:9E:03:D1:D8:AA:FF:A9:2E:92:D9:53:B3:CD:2A:BB:CB:6B:5A:C8:0E`

The signing properties and keystore are local secrets and are intentionally ignored by Git.

## Build

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  ./gradlew :androidApp:assembleRelease :androidApp:bundleRelease
```

Artifacts:

- `androidApp/build/outputs/apk/release/androidApp-release.apk`
- `androidApp/build/outputs/bundle/release/androidApp-release.aab`

Current artifact SHA-256 values after the stability-default rebuild:

- APK: `9bf653de3fbac32c360852d6fa2e710a7db77cfe9addd4d9f80fbf96d3afba1b`
- AAB: `09a1643cd19c2de9c2badf2a6022074df46a6ef471f1161c8fcd0e867f3bd190`

## Verification

```bash
ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  scripts/preflight-android-release.sh

/Users/mihailpozalov/Library/Android/sdk/build-tools/36.0.0/apksigner \
  verify --print-certs androidApp/build/outputs/apk/release/androidApp-release.apk

jarsigner -verify -certs -verbose \
  androidApp/build/outputs/bundle/release/androidApp-release.aab
```

Expected state:

- Android release preflight has `0 failure(s), 0 warning(s)`.
- APK signer certificate matches the SHA-256 fingerprint above.
- AAB entries are signed by `CN=VK Turn Proxy, OU=Mobile, O=VK Turn Proxy, L=Moscow, ST=Moscow, C=RU`.

## Physical Device Smoke

Run the signed release imported-profile smoke on an attached Android device:

```bash
SERIAL=<adb-device-id> \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  REQUIRE_PHYSICAL_DEVICE=1 \
  PROFILE_FILE=/absolute/path/to/full-backup-or-connection.json \
  scripts/smoke-android-release-imported-profile.sh
```

To test through the temporary VPS public second port before promoting
production `56004`, use the orchestrator instead:

```bash
SERIAL=<adb-device-id> \
  ANDROID_HOME=/Users/mihailpozalov/Library/Android/sdk \
  REQUIRE_PHYSICAL_DEVICE=1 \
  PROFILE_FILE=/absolute/path/to/full-backup-or-connection.json \
  scripts/smoke-android-release-with-public-server.sh \
  build/evidence/android-physical-public-server-$(date +%Y%m%d-%H%M%S)
```

When using `PROFILE_FILE` or `IMPORT_LINK`, make sure that payload points at the
temporary server, for example `142.252.220.91:56014`. The smoke scripts rewrite
`peerAddress` in JSON profile files and `vkturnproxy://import?data=...` links
when `PEER_ADDRESS` is set; the public-server orchestrator sets it to the
temporary VPS public port automatically. The orchestrator prints
`ANDROID_PHYSICAL_SMOKE_EVIDENCE=<dir>/android`; use that nested Android evidence
directory for final readiness.

The smoke prints `evidence_dir=...` on success. Use that directory as
`ANDROID_PHYSICAL_SMOKE_EVIDENCE` for `scripts/final-release-readiness.sh`.
The summary must contain `result=passed`, `evidence_type=android_physical_smoke`,
`require_physical_device=1`, `device_qemu=0`, `attachment_count > 0`, and
`wireguard_attached_observed=1`, `vpn_network_observed=1`,
`vpn_stop_cleaned=1`. This prevents an emulator run or a partial smoke from
satisfying the physical-device release gate.
Final readiness also requires the runtime evidence files written by the smoke:
`device-qemu.txt`, `running-connectivity.txt`, `stopped-connectivity.txt`, and
`final-logcat-filtered.txt`.

The external smoke kit also writes a physical-device wrapper:

```bash
scripts/prepare-external-smoke-kit.sh v1.0-build163
PROFILE_FILE=/absolute/path/to/full-backup-or-connection.json \
  build/external-smoke-kit/v1.0-build163/commands/android-physical-smoke.sh
```

The wrapper prints `ANDROID_PHYSICAL_SMOKE_EVIDENCE=<dir>` when the smoke
passes. By default it uses the temporary public VPS server; set
`USE_PUBLIC_SERVER=0` only when intentionally testing an already-promoted
production endpoint.

Supported profile inputs:

- `IMPORT_LINK=vkturnproxy://import?data=...`
- `PROFILE_FILE=/path/to/full-backup.json`
- `PROFILE_FILE=/path/to/connection.json`
- fallback to the local macOS iOS preferences plist through `PREF=...`

Check the import payload without installing or starting the app:

```bash
PREPARE_IMPORT_ONLY=1 \
  BUILD_RELEASE=0 \
  EVIDENCE_DIR=build/android-release-smoke/prepare-test \
  PROFILE_FILE=/absolute/path/to/full-backup-or-connection.json \
  scripts/smoke-android-release-imported-profile.sh
```

## Operational Notes

- Back up `androidApp/keystore/vk-turn-proxy-release.jks` and `androidApp/signing.properties` securely before using this key for any store upload.
- If Google Play App Signing is used, keep this key stable after the first upload unless Play Console key rotation is intentionally planned.
- Do not commit `androidApp/signing.properties`, `.jks`, `.keystore`, or `.p12` files.
