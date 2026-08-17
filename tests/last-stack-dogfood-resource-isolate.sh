#!/usr/bin/env bash
# Deterministic tests for last-stack-dogfood-resource-isolate fail-closed
# preflight and isolation proof. No live cargo bench; no primary mutation.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
ISOLATE="$ROOT/bin/last-stack-dogfood-resource-isolate"
MOLECULE="$ROOT/bin/last-stack-dogfood-molecule-per-key-reads"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -x "$ISOLATE" ] || chmod +x "$ISOLATE"
[ -x "$MOLECULE" ] || chmod +x "$MOLECULE"
bash -n "$ISOLATE"
bash -n "$MOLECULE"

# --- 1) free-memory gate fails closed ---
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=999999999 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  "$ISOLATE" --preflight-only 2>/dev/null || true
)"
printf '%s\n' "$out" | grep -q $'result=blocker' \
  || fail "expected blocker when free memory is below absurd min; got: $out"
printf '%s\n' "$out" | grep -q 'free_mib=' \
  || fail "expected free_mib field in blocker output"

# --- 2) load gate fails closed ---
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=0.000001 \
  "$ISOLATE" --preflight-only 2>/dev/null || true
)"
printf '%s\n' "$out" | grep -q $'result=blocker' \
  || fail "expected blocker when load cap is near zero; got: $out"
printf '%s\n' "$out" | grep -q 'load1=' \
  || fail "expected load1 field"

# --- 3) healthy off-host preflight (skip primary, generous thresholds) ---
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  LAST_STACK_DOGFOOD_OFFHOST_CMD=true \
  "$ISOLATE" --preflight-only
)"
printf '%s\n' "$out" | grep -q $'result=ok' \
  || fail "expected ok preflight under generous thresholds; got: $out"
printf '%s\n' "$out" | grep -q 'isolation_proven=1' \
  || fail "expected isolation_proven=1; got: $out"
printf '%s\n' "$out" | grep -q 'isolation_backend=' \
  || fail "expected isolation_backend field"

# --- 4) limited exec runs command when preflight ok ---
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  LAST_STACK_DOGFOOD_ALLOW_UNISOLATED=1 \
  "$ISOLATE" -- /bin/echo isolate-exec-ok
)"
printf '%s\n' "$out" | grep -q 'isolate-exec-ok' \
  || fail "expected child stdout; got: $out"
printf '%s\n' "$out" | grep -q 'cmd_rc=0' \
  || fail "expected cmd_rc=0; got: $out"
printf '%s\n' "$out" | grep -q 'primary_unchanged=1' \
  || fail "expected primary_unchanged=1; got: $out"

# --- 5) child failure propagates ---
set +e
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  LAST_STACK_DOGFOOD_ALLOW_UNISOLATED=1 \
  "$ISOLATE" -- /bin/sh -c 'exit 17'
)"
rc=$?
set -e
[ "$rc" -eq 17 ] || fail "expected exit 17, got $rc"
printf '%s\n' "$out" | grep -q 'cmd_rc=17' \
  || fail "expected cmd_rc=17; got: $out"

# --- 6) JSON mode ---
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  LAST_STACK_DOGFOOD_OFFHOST_CMD=true \
  "$ISOLATE" --preflight-only --json
)"
printf '%s\n' "$out" | grep -q '"result":"ok"' \
  || fail "expected JSON result ok; got: $out"

# --- 7) Darwin must not mistake a load/memory snapshot for hard isolation ---
if [ "$(uname -s)" = "Darwin" ]; then
  set +e
  out="$(
    LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
    LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
    LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
    "$ISOLATE" --preflight-only 2>/dev/null
  )"
  rc=$?
  set -e
  [ "$rc" -eq 1 ] || fail "Darwin local preflight must fail closed without off-host isolation, rc=$rc"
  printf '%s\n' "$out" | grep -q 'isolation-unproven' \
    || fail "expected isolation-unproven Darwin blocker; got: $out"
fi

# --- 8) molecule recipe: preflight-only respects isolation gate ---
set +e
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=999999999 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  "$MOLECULE" --preflight-only 2>/dev/null
)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "molecule preflight should fail closed on low free mem, rc=$rc"
printf '%s\n' "$out" | grep -q 'resource-isolation-preflight\|result=blocker' \
  || fail "expected molecule blocker; got: $out"

# --- 9) molecule recipe: skip-bench path documents cardinalities + groups ---
# Provide a tiny fake git fold checkout so resolve does not need network.
git -c init.defaultBranch=main init "$tmp/fold" >/dev/null
git -C "$tmp/fold" config user.email test@example.com
git -C "$tmp/fold" config user.name Test
printf 'x\n' > "$tmp/fold/README"
git -C "$tmp/fold" add README
git -C "$tmp/fold" commit -m init >/dev/null

# Disable target-checkout manage so we stay on the provided path without
# needing a remote; the recipe falls back to the candidate when helper
# cannot select a managed target.
out="$(
  LAST_STACK_DOGFOOD_MIN_FREE_MIB=0 \
  LAST_STACK_DOGFOOD_SKIP_PRIMARY_CHECK=1 \
  LAST_STACK_DOGFOOD_MAX_LOAD_PER_CPU=999 \
  LAST_STACK_DOGFOOD_OFFHOST_CMD=true \
  LAST_STACK_MOLECULE_ALLOW_SOURCE_FALLBACK=1 \
  "$MOLECULE" --fold-checkout "$tmp/fold" --skip-bench 2>/dev/null
)"
printf '%s\n' "$out" | grep -q 'phase=resolved-skip-bench' \
  || fail "expected resolved-skip-bench; got: $out"
printf '%s\n' "$out" | grep -q 'cardinalities=1000,10000,50000,100000' \
  || fail "expected four cardinalities; got: $out"
printf '%s\n' "$out" | grep -q 'indexed_point_lookup' \
  || fail "expected indexed_point_lookup group; got: $out"
printf '%s\n' "$out" | grep -q 'indexed_full_read' \
  || fail "expected indexed_full_read group; got: $out"

printf 'ok last-stack-dogfood-resource-isolate tests passed\n'
