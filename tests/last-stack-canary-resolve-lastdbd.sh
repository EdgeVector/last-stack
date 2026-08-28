#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-canary-resolve-lastdbd"
chmod +x "$CLI"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Hermetic fold "mirror" with one commit on main
mirror="$tmp/fold.git"
git init --bare "$mirror" >/dev/null
work="$tmp/fold-src"
git clone "$mirror" "$work" >/dev/null 2>&1
(
  cd "$work"
  git checkout -b main >/dev/null 2>&1
  echo tip > README
  git add README
  git -c user.email=t@example.com -c user.name=t commit -m 'main tip' >/dev/null
  git push origin main >/dev/null 2>&1
)
MAIN_OID="$(git -C "$mirror" rev-parse refs/heads/main)"
SHORT="${MAIN_OID:0:9}"

builds="$tmp/canary-builds"
staged="$tmp/smoke-staged"
current_dir="$tmp/current"
mkdir -p "$builds" "$staged" "$current_dir"

export LAST_STACK_CANARY_FOLD_MIRROR="$mirror"
export LAST_STACK_CANARY_BUILDS_DIR="$builds"
export LAST_STACK_SMOKE_STAGED_DIR="$staged"
export LAST_STACK_CANARY_FETCH_MAIN=0
export LAST_STACK_CANARY_MAIN_OID="$MAIN_OID"
export LASTDB_CURRENT_BIN="$current_dir/lastdbd"

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- no binaries: need_build ---
set +e
out="$("$CLI" --json 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "empty resolve rc=$rc out=$out"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "need_build" ] || fail "empty status: $out"
[ "$(printf '%s\n' "$out" | jq -r .wanted_oid)" = "$MAIN_OID" ] || fail "wanted oid: $out"

# --- exact canary-builds stage ---
mkdir -p "$builds/$MAIN_OID"
printf '#!/bin/sh\necho lastdbd staged\n' >"$builds/$MAIN_OID/lastdbd"
printf '#!/bin/sh\necho lastdb staged\n' >"$builds/$MAIN_OID/lastdb"
printf '#!/bin/sh\necho restore probe staged\n' >"$builds/$MAIN_OID/lastdb_restore_probe"
chmod +x "$builds/$MAIN_OID/lastdbd" "$builds/$MAIN_OID/lastdb" "$builds/$MAIN_OID/lastdb_restore_probe"

out="$("$CLI" --json)"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "ok" ] || fail "exact stage: $out"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds" ] || fail "exact source: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$builds/$MAIN_OID/lastdbd" ] || fail "exact lastdbd: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdb)" = "$builds/$MAIN_OID/lastdb" ] || fail "exact lastdb: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdb_restore_probe)" = "$builds/$MAIN_OID/lastdb_restore_probe" ] || fail "exact probe: $out"
[ "$(printf '%s\n' "$out" | jq -r .sha_drift)" = "false" ] || fail "exact drift: $out"

# --- smoke-staged wins over canary-builds ---
printf '#!/bin/sh\necho lastdbd smoke\n' >"$staged/lastdbd-smoke-staged-$SHORT"
chmod +x "$staged/lastdbd-smoke-staged-$SHORT"
out="$("$CLI" --json)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds" ] || fail "strict resolve accepted daemon-only smoke stage: $out"
out="$("$CLI" --json --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "smoke-staged" ] || fail "smoke-staged win: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$staged/lastdbd-smoke-staged-$SHORT" ] || fail "smoke path: $out"

# --- newest fallback when exact SHA missing ---
rm -f "$staged/lastdbd-smoke-staged-$SHORT"
rm -rf "$builds/$MAIN_OID"
other="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
mkdir -p "$builds/$other"
printf '#!/bin/sh\necho lastdbd old\n' >"$builds/$other/lastdbd"
chmod +x "$builds/$other/lastdbd"

set +e
out="$("$CLI" --json 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "no-fallback should need_build: $out"

out="$("$CLI" --json --allow-newest --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .status)" = "ok" ] || fail "newest status: $out"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "canary-builds-newest" ] || fail "newest source: $out"
[ "$(printf '%s\n' "$out" | jq -r .sha_drift)" = "true" ] || fail "newest drift: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$builds/$other/lastdbd" ] || fail "newest path: $out"

# --- primary current last resort ---
rm -rf "$builds/$other"
printf '#!/bin/sh\necho lastdbd current\n' >"$current_dir/lastdbd"
chmod +x "$current_dir/lastdbd"

set +e
out="$("$CLI" --json --allow-newest 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "newest-empty should need_build: $out"

out="$("$CLI" --json --allow-newest --allow-current --allow-daemon-only)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "primary-current" ] || fail "current source: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdbd)" = "$current_dir/lastdbd" ] || fail "current path: $out"
[ "$(printf '%s\n' "$out" | jq -r .sha_drift)" = "true" ] || fail "current drift: $out"

# --- backup restore contract requires all three current executables ---
set +e
out="$("$CLI" --json --allow-newest --allow-current 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 2 ] || fail "incomplete current stage must need_build: $out"

printf '#!/bin/sh\necho lastdb current\n' >"$current_dir/lastdb"
printf '#!/bin/sh\necho restore probe current\n' >"$current_dir/lastdb_restore_probe"
chmod +x "$current_dir/lastdb" "$current_dir/lastdb_restore_probe"
out="$("$CLI" --json --allow-newest --allow-current)"
[ "$(printf '%s\n' "$out" | jq -r .source)" = "primary-current" ] || fail "complete current source: $out"
[ "$(printf '%s\n' "$out" | jq -r .lastdb_restore_probe)" = "$current_dir/lastdb_restore_probe" ] || fail "complete current probe: $out"

# --- never cargo: helper has no cargo invocation ---
if grep -n 'cargo ' "$CLI" | grep -v 'Never compiles' >/dev/null; then
  fail "resolver must not invoke cargo"
fi

echo "ok last-stack-canary-resolve-lastdbd"
