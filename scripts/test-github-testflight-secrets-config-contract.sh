#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-github-testflight-secrets.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

cert="$TMP_DIR/cert.p12"
key="$TMP_DIR/AuthKey_ABCDE12345.p8"
profile="$TMP_DIR/profile.mobileprovision"
touch "$cert" "$key" "$profile"

if DRY_RUN=1 "$ROOT_DIR/scripts/configure-github-testflight-secrets.sh" \
  --cert-p12 "$cert" \
  --cert-password password \
  --profile "$profile" \
  --profile "$profile" \
  --profile "$profile" \
  --profile "$profile" \
  --appstore-key-id BAD \
  --appstore-issuer-id 00000000-0000-0000-0000-000000000000 \
  --appstore-key-p8 "$key" > "$TMP_DIR/bad-key-id.out" 2>&1; then
  echo "Invalid App Store key id must fail." >&2
  exit 1
fi
grep -q -- '--appstore-key-id must be a 10-character key id' "$TMP_DIR/bad-key-id.out"

printf 'not a private key\n' > "$key"
if DRY_RUN=1 "$ROOT_DIR/scripts/configure-github-testflight-secrets.sh" \
  --cert-p12 "$cert" \
  --cert-password password \
  --profile "$profile" \
  --profile "$profile" \
  --profile "$profile" \
  --profile "$profile" \
  --appstore-key-id ABCDE12345 \
  --appstore-issuer-id 00000000-0000-0000-0000-000000000000 \
  --appstore-key-p8 "$key" > "$TMP_DIR/bad-p8.out" 2>&1; then
  echo "Invalid .p8 must fail before GitHub secrets are written." >&2
  exit 1
fi
grep -q 'does not look like a private key' "$TMP_DIR/bad-p8.out"

cat > "$key" <<'EOF'
-----BEGIN PRIVATE KEY-----
fixture
-----END PRIVATE KEY-----
EOF
if DRY_RUN=1 "$ROOT_DIR/scripts/configure-github-testflight-secrets.sh" \
  --cert-p12 "$cert" \
  --cert-password password \
  --profile "$profile" \
  --profile "$profile" \
  --profile "$profile" \
  --profile "$profile" \
  --appstore-key-id ABCDE12345 \
  --appstore-issuer-id 00000000-0000-0000-0000-000000000000 \
  --appstore-key-p8 "$key" > "$TMP_DIR/bad-p12.out" 2>&1; then
  echo "Invalid .p12 must fail before GitHub secrets are written." >&2
  exit 1
fi
grep -q 'Apple Distribution .p12 could not be opened' "$TMP_DIR/bad-p12.out"

printf 'github testflight secrets config contract ok\n'
