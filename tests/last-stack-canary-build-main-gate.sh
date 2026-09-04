#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-build-main-gate"
chmod +x "$BIN"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-build-main-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

export LAST_STACK_CANARY_BUILDS_DIR="$tmp/canary-builds"

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

# --- stale but no gate_head: skip (exit 0) ---
export LAST_STACK_CANARY_BUILD_GATE_STATUS_CMD="cat <<'JSON'
{\"stale\": true, \"host_head\": \"aaa111\", \"gate_head\": \"\"}
JSON"
set +e
out="$("$BIN" 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ]
grep -q 'not-stale' <<<"$out"

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
