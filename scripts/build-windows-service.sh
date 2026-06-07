#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/windows"
OUT="$OUT_DIR/vk-turn-proxy-windows-service.exe"

sha256_file() {
  local file="$1"
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v certutil.exe >/dev/null 2>&1; then
    certutil.exe -hashfile "$(cygpath -w "$file" 2>/dev/null || printf '%s' "$file")" SHA256 |
      awk 'NR == 2 { gsub(/[^0-9A-Fa-f]/, ""); print tolower($0) }'
  elif command -v pwsh >/dev/null 2>&1; then
    pwsh -NoProfile -NonInteractive -Command "(Get-FileHash -Algorithm SHA256 -Path '$file').Hash.ToLowerInvariant()"
  else
    echo "shasum, sha256sum, certutil.exe, or pwsh is required to hash $file" >&2
    return 1
  fi
}

mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"

GOOS=windows GOARCH=amd64 go build -trimpath -o "$OUT" ./cmd/vk-turn-proxy-windows-service

sha256="$(sha256_file "$OUT")"
printf 'binary=%s\n' "$OUT"
printf 'sha256=%s\n' "$sha256"
