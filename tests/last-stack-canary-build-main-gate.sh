#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-build-main-gate"
chmod +x "$BIN"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-build-main-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

export LAST_STACK_CANARY_BUILDS_DIR="$tmp/canary-builds"

# The gate script heartbeats on every branch. Without this the appender falls
# back to the install root's logs/ and these fixture SHAs land in the PRODUCTION
# fleet log. Set here too, not only in .lastgit/ci.sh, because this test is also
# run directly.
export LAST_STACK_HEARTBEATS_FILE="$tmp/routine-heartbeats.log"

# --- not stale: skip (exit 0) ---
export LAST_STACK_CANARY_BUILD_GATE_STATUS_CMD="cat <<'JSON'
{\"stale\": false, \"host_head\": \"aaa111\", \"gate_head\": \"aaa111\"}
JSON"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ]
grep -q 'outcome=noop' <<<"$out"
grep -q 'not-stale' <<<"$out"

# --- stale but no gate_head: skip (exit 0), reported as its own condition ---
# host-track answers stale=true gate_head=null when the publish lane is broken
# ("published gate head is unavailable"). Skipping is right, but the gate must
# not call that "not-stale" — this host ran that way for days while
# lastdb-local-smoke-test reported sha_drift=true and the gate said the host
# was up to date.
export LAST_STACK_CANARY_BUILD_GATE_STATUS_CMD="cat <<'JSON'
{\"stale\": true, \"host_head\": \"aaa111\", \"gate_head\": \"\"}
JSON"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ]
grep -q 'gate-head-unavailable' <<<"$out"
grep -q 'outcome=noop' <<<"$out"
grep -q 'not-stale' <<<"$out" && { echo "FAIL: missing gate_head must not report not-stale: $out" >&2; exit 1; }

# --- null gate_head (JSON null, as host-track really emits it) ---
export LAST_STACK_CANARY_BUILD_GATE_STATUS_CMD="cat <<'JSON'
{\"stale\": true, \"host_head\": \"aaa111\", \"gate_head\": null}
JSON"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ]
grep -q 'gate-head-unavailable' <<<"$out"

# --- stale, gate_head differs, no staged candidate: proceed (exit 10) ---
export LAST_STACK_CANARY_BUILD_GATE_STATUS_CMD="cat <<'JSON'
{\"stale\": true, \"host_head\": \"aaa111\", \"gate_head\": \"bbb222\"}
JSON"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 10 ]
grep -q 'CANARY_BUILD_MAIN_GATE proceed gate_head=bbb222' <<<"$out"

# --- stale, gate_head differs, candidate already staged: skip (exit 0) ---
mkdir -p "$LAST_STACK_CANARY_BUILDS_DIR/bbb222"
printf '#!/bin/sh\n' >"$LAST_STACK_CANARY_BUILDS_DIR/bbb222/lastdbd"
chmod +x "$LAST_STACK_CANARY_BUILDS_DIR/bbb222/lastdbd"
printf '{}' >"$LAST_STACK_CANARY_BUILDS_DIR/bbb222/manifest.json"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ]
grep -q 'already-staged' <<<"$out"

# --- status command unavailable: skip (exit 0), not an error ---
export LAST_STACK_CANARY_BUILD_GATE_STATUS_CMD="false"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ]
grep -q 'status-unavailable' <<<"$out"

echo "ok"
