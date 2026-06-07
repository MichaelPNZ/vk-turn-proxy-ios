#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

promote_err="$(mktemp)"
rollback_err="$(mktemp)"
dry_err="$(mktemp)"
trap 'rm -f "$promote_err" "$rollback_err" "$dry_err"' EXIT

set +e
MODE=promote HOST=142.252.220.91 SSH_USER=root "$ROOT_DIR/scripts/deploy-server-vps.sh" >/dev/null 2>"$promote_err"
promote_code=$?
MODE=rollback HOST=142.252.220.91 SSH_USER=root "$ROOT_DIR/scripts/deploy-server-vps.sh" >/dev/null 2>"$rollback_err"
rollback_code=$?
MODE=dry-run DRY_LISTEN=0.0.0.0:56004 "$ROOT_DIR/scripts/deploy-server-vps.sh" >/dev/null 2>"$dry_err"
dry_code=$?
set -e

if [[ "$promote_code" != 64 ]]; then
  echo "Expected unconfirmed promote to exit 64, got $promote_code" >&2
  cat "$promote_err" >&2
  exit 1
fi
if ! grep -q 'CONFIRM_PRODUCTION_PROMOTE=142.252.220.91:56004' "$promote_err"; then
  echo "Promote guard did not print required confirmation." >&2
  cat "$promote_err" >&2
  exit 1
fi

if [[ "$rollback_code" != 64 ]]; then
  echo "Expected unconfirmed rollback to exit 64, got $rollback_code" >&2
  cat "$rollback_err" >&2
  exit 1
fi
if ! grep -q 'CONFIRM_PRODUCTION_ROLLBACK=142.252.220.91:56004' "$rollback_err"; then
  echo "Rollback guard did not print required confirmation." >&2
  cat "$rollback_err" >&2
  exit 1
fi

if [[ "$dry_code" != 64 ]]; then
  echo "Expected dry-run on production port to exit 64, got $dry_code" >&2
  cat "$dry_err" >&2
  exit 1
fi
if ! grep -q 'refusing dry-run on production port 56004' "$dry_err"; then
  echo "Dry-run production-port guard did not print expected refusal." >&2
  cat "$dry_err" >&2
  exit 1
fi

if ! grep -q 'automatically rolls back if post-promote health fails' "$ROOT_DIR/scripts/deploy-server-vps.sh"; then
  echo "Promote mode usage does not document automatic rollback." >&2
  exit 1
fi
if ! grep -q 'post-promote health failed; rolling back' "$ROOT_DIR/scripts/deploy-server-vps.sh"; then
  echo "Promote path does not include post-promote health auto-rollback." >&2
  exit 1
fi
if ! grep -q 'after-auto-rollback' "$ROOT_DIR/scripts/deploy-server-vps.sh"; then
  echo "Promote path does not write after-auto-rollback evidence." >&2
  exit 1
fi

printf 'server deploy safety ok\n'
