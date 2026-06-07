#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "$ROOT_DIR/build/test-apple-signing-evidence.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

run_collector() {
  local env_file="$1"
  local evidence="$2"
  TESTFLIGHT_ENV_FILE="$env_file" \
    TESTFLIGHT_PROFILE_DIR="$TMP_DIR/profiles" \
    "$ROOT_DIR/scripts/collect-apple-signing-evidence.sh" "$evidence" > "$evidence.log"
}

mkdir -p "$TMP_DIR/profiles"

invalid_key="$TMP_DIR/not-a-private-key.p8"
printf 'not a private key\n' > "$invalid_key"
invalid_env="$TMP_DIR/AppStoreConnect.invalid.env"
cat > "$invalid_env" <<EOF
APPSTORE_KEY_ID=bad
APPSTORE_ISSUER_ID=not-a-uuid
APPSTORE_KEY_PATH=$invalid_key
EOF
chmod 644 "$invalid_env"

invalid_evidence="$TMP_DIR/invalid-evidence"
run_collector "$invalid_env" "$invalid_evidence"
grep -q '^result=blocked$' "$invalid_evidence/summary.txt"
grep -q 'APPSTORE_KEY_ID must be a 10-character App Store Connect key id' "$invalid_evidence/blockers.txt"
grep -q 'APPSTORE_ISSUER_ID must be a UUID' "$invalid_evidence/blockers.txt"
grep -q 'APPSTORE_KEY_PATH does not look like an App Store Connect .p8 private key' "$invalid_evidence/blockers.txt"
grep -q 'must have file mode 600' "$invalid_evidence/blockers.txt"

valid_key="$TMP_DIR/AuthKey_ABCDE12345.p8"
cat > "$valid_key" <<'EOF'
-----BEGIN PRIVATE KEY-----
placeholder
-----END PRIVATE KEY-----
EOF
valid_env="$TMP_DIR/AppStoreConnect.valid.env"
cat > "$valid_env" <<EOF
APPSTORE_KEY_ID=ABCDE12345
APPSTORE_ISSUER_ID=00000000-0000-0000-0000-000000000000
APPSTORE_KEY_PATH=$valid_key
EOF
chmod 600 "$valid_env"

valid_evidence="$TMP_DIR/valid-evidence"
run_collector "$valid_env" "$valid_evidence"
grep -q '^result=blocked$' "$valid_evidence/summary.txt"
grep -q '^FILE_MODE=600$' "$valid_evidence/appstore-connect-env.txt"
if grep -q 'APPSTORE_KEY_ID must be\|APPSTORE_ISSUER_ID must be\|APPSTORE_KEY_PATH does not look\|must have file mode 600' "$valid_evidence/blockers.txt"; then
  echo "Valid-format App Store Connect env produced env-format blockers." >&2
  cat "$valid_evidence/blockers.txt" >&2
  exit 1
fi

printf 'apple signing evidence contract ok\n'
