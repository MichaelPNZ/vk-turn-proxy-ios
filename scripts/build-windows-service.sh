#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="$ROOT_DIR/build/windows"
OUT="$OUT_DIR/vk-turn-proxy-windows-service.exe"

mkdir -p "$OUT_DIR"

cd "$ROOT_DIR"

GOOS=windows GOARCH=amd64 go build -trimpath -o "$OUT" ./cmd/vk-turn-proxy-windows-service

sha256="$(shasum -a 256 "$OUT" | awk '{print $1}')"
printf 'binary=%s\n' "$OUT"
printf 'sha256=%s\n' "$sha256"
