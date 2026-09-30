#!/usr/bin/env bash
# SMOKE_BREW_PLIST_NAME names the brew service plist the smoke checks. Unset, it
# stays homebrew.mxcl.lastdb.plist (Tom's Mac, Homebrew 7). The CI workflow sets
# sh.brew.lastdb.plist (GitHub runner, Homebrew 6.0.22). A value with a slash or
# an empty value falls back to the default, so the override cannot point the
# check at another directory. The check after the lookup is not changed.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
RUN="$ROOT/skills/llms-txt-install-smoke/run.sh"
WF="$ROOT/.github/workflows/registry-proof.yml"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
tmp="$(mktemp -d "${TMPDIR:-/tmp}/smoke-plist-name.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

sed -n '/^# brew-plist-name-begin$/,/^# brew-plist-name-end$/p' "$RUN" > "$tmp/block.sh"
[ -s "$tmp/block.sh" ] || fail "markers missing in run.sh"

name_for() { # <env assignment or empty>
  if [ -n "$1" ]; then
    env -u SMOKE_BREW_PLIST_NAME "$1" bash -c '. "$1"; printf "%s" "$SMOKE_BREW_PLIST_FILE"' _ "$tmp/block.sh"
  else
    env -u SMOKE_BREW_PLIST_NAME bash -c '. "$1"; printf "%s" "$SMOKE_BREW_PLIST_FILE"' _ "$tmp/block.sh"
  fi
}
[ "$(name_for "")" = homebrew.mxcl.lastdb.plist ] || fail "default changed: $(name_for "")"
[ "$(name_for SMOKE_BREW_PLIST_NAME=sh.brew.lastdb.plist)" = sh.brew.lastdb.plist ] || fail "override ignored"
[ "$(name_for SMOKE_BREW_PLIST_NAME=)" = homebrew.mxcl.lastdb.plist ] || fail "empty override must fall back"
[ "$(name_for SMOKE_BREW_PLIST_NAME=../x.plist)" = homebrew.mxcl.lastdb.plist ] || fail "a path must fall back"

# the check reads the variable, not a literal name
grep -q 'plist="$brew_prefix/$SMOKE_BREW_PLIST_FILE"' "$RUN" || fail "check does not use SMOKE_BREW_PLIST_FILE"
[ "$(grep -c 'homebrew.mxcl.lastdb.plist' "$RUN")" -le 4 ] || fail "literal plist name spread through run.sh"
# only the CI workflow sets the override
grep -q 'SMOKE_BREW_PLIST_NAME=sh.brew.lastdb.plist' "$WF" || fail "workflow does not set the override"
if grep -rn 'SMOKE_BREW_PLIST_NAME' "$ROOT/skills" "$ROOT/bin" 2>/dev/null | grep -v 'run.sh' | grep -q .; then
  fail "a Mac-side caller sets SMOKE_BREW_PLIST_NAME"
fi
printf 'ok llms-txt-smoke-brew-plist-name\n'
