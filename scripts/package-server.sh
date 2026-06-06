#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT_DIR="${OUT_DIR:-"$ROOT_DIR/build/server"}"
VERSION="${VERSION:-$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo dev)}"
BINARY="$OUT_DIR/vk-turn-proxy-server-linux-amd64"
PACKAGE="$OUT_DIR/vk-turn-proxy-server-$VERSION-linux-amd64.tar.gz"

mkdir -p "$OUT_DIR"

echo "==> Building Linux amd64 server binary"
(
  cd "$ROOT_DIR"
  CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
    go build -trimpath -ldflags="-s -w" \
    -o "$BINARY" \
    ./cmd/vk-turn-proxy-server
)

SHA256="$(shasum -a 256 "$BINARY" | awk '{print $1}')"
printf '%s  %s\n' "$SHA256" "$(basename "$BINARY")" > "$BINARY.sha256"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
mkdir -p "$tmpdir/vk-turn-proxy-server"
cp -X "$BINARY" "$tmpdir/vk-turn-proxy-server/vk-turn-proxy-server"
cp -X "$BINARY.sha256" "$tmpdir/vk-turn-proxy-server/vk-turn-proxy-server.sha256"
cp -X "$ROOT_DIR/deploy/server/vk-turn-proxy-ios.service" "$tmpdir/vk-turn-proxy-server/"
cp -X "$ROOT_DIR/deploy/server/vk-turn-proxy-ios.env.example" "$tmpdir/vk-turn-proxy-server/"
cp -X "$ROOT_DIR/deploy/server/vk-turn-proxy-ios.logrotate" "$tmpdir/vk-turn-proxy-server/"

xattr -cr "$tmpdir/vk-turn-proxy-server" 2>/dev/null || true
tar_args=(--format ustar -C "$tmpdir" -czf "$PACKAGE")
if tar --help 2>&1 | grep -q -- '--no-xattrs'; then
  tar_args=(--no-xattrs "${tar_args[@]}")
fi
COPYFILE_DISABLE=1 tar "${tar_args[@]}" vk-turn-proxy-server

echo "binary=$BINARY"
echo "sha256=$SHA256"
echo "package=$PACKAGE"
