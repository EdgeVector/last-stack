#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="$ROOT/bin/last-stack-kanban-done-when-eval"

tmp_home="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-done-when-home.XXXXXX")"
trap 'rm -rf "$tmp_home"' EXIT

proof="$tmp_home/.last-stack/feature-proofs/feature-portable-same-key-at-rest.md"
mkdir -p "$(dirname "$proof")"
printf 'PASS portable proof\n' >"$proof"

tilde_out="$(
  HOME="$tmp_home" "$BIN" \
    --kind validation \
    --predicate 'file ~/.last-stack/feature-proofs/feature-portable-same-key-at-rest.md matches /^PASS/'
)"
printf '%s\n' "$tilde_out" | grep -F "satisfied: file $proof matches /^PASS/"

home_out="$(
  HOME="$tmp_home" "$BIN" \
    --kind validation \
    --predicate 'file $HOME/.last-stack/feature-proofs/feature-portable-same-key-at-rest.md matches /^PASS/'
)"
printf '%s\n' "$home_out" | grep -F "satisfied: file $proof matches /^PASS/"

set +e
missing_out="$(
  HOME="$tmp_home" "$BIN" \
    --kind validation \
    --predicate 'file ~/.last-stack/feature-proofs/missing.md matches /^PASS/' \
    2>&1
)"
missing_rc=$?
set -e

test "$missing_rc" -eq 1
printf '%s\n' "$missing_out" | grep -F "pending: file $tmp_home/.last-stack/feature-proofs/missing.md does not exist"
if printf '%s\n' "$missing_out" | grep -F "$tmp_home/~/" >/dev/null; then
  echo "tilde path was incorrectly expanded under HOME/~" >&2
  exit 1
fi

echo ok
