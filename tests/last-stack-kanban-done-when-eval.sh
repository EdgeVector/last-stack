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

# Compound form: every side satisfied -> 0.
and_out="$(
  HOME="$tmp_home" "$BIN" \
    --kind validation \
    --predicate 'file ~/.last-stack/feature-proofs/feature-portable-same-key-at-rest.md matches /^PASS/ AND date >= 2000-01-01'
)"
printf '%s\n' "$and_out" | grep -F "satisfied: every side of the compound DONE-WHEN is satisfied"

# One side pending -> 1.
set +e
HOME="$tmp_home" "$BIN" --kind validation \
  --predicate 'date >= 2000-01-01 AND file ~/.last-stack/feature-proofs/missing.md matches /^PASS/' >/dev/null
and_pending_rc=$?
# One side unsupported -> 2, and the message lists the supported forms.
unsupported_out="$(
  HOME="$tmp_home" "$BIN" --kind validation \
    --predicate 'date >= 2000-01-01 AND kanban groom board-cards-heal exits 0 in under 10s'
)"
unsupported_rc=$?
set -e
test "$and_pending_rc" -eq 1
test "$unsupported_rc" -eq 2
printf '%s\n' "$unsupported_out" | grep -F "malformed: compound DONE-WHEN has an unsupported side"
printf '%s\n' "$unsupported_out" | grep -F "supported: brain <slug> exists"

echo ok
