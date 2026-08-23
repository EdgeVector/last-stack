#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  /bin/rm -rf "$tmp"
}
trap cleanup EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/sccache" <<'EOF'
#!/bin/sh
if [ -n "${FAKE_COMPILATIONS:-}" ]; then
  printf '{"cache_size":%s,"max_cache_size":%s,"stats":{"cache_write_errors":%s,"compilations":%s}}\n' \
    "${FAKE_CACHE_SIZE:?}" "${FAKE_MAX_CACHE_SIZE:?}" \
    "${FAKE_WRITE_ERRORS:?}" "${FAKE_COMPILATIONS}"
else
  printf '{"cache_size":%s,"max_cache_size":%s}\n' \
    "${FAKE_CACHE_SIZE:?}" "${FAKE_MAX_CACHE_SIZE:?}"
fi
EOF
chmod +x "$fake_bin/sccache"

cat >"$fake_bin/cargo" <<'EOF'
#!/bin/sh
printf 'wrapper=<%s> args=<%s>\n' "${RUSTC_WRAPPER-unset}" "$*"
EOF
chmod +x "$fake_bin/cargo"

export PATH="$fake_bin:/usr/bin:/bin"
export SCCACHE_BIN="$fake_bin/sccache"
export FAKE_CACHE_SIZE=999
export FAKE_MAX_CACHE_SIZE=1000

unset RUSTC_WRAPPER
set +e
full_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
full_rc=$?
set -e
test "$full_rc" -eq 10
printf '%s\n' "$full_json" | grep -q '"state":"full"'
printf '%s\n' "$full_json" | grep -q '"bypass_active":false'

RUSTC_WRAPPER=
export RUSTC_WRAPPER
bypassed_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
printf '%s\n' "$bypassed_json" | grep -q '"state":"bypassed"'
printf '%s\n' "$bypassed_json" | grep -q '"bypass_active":true'

unset RUSTC_WRAPPER
export FAKE_CACHE_SIZE=500
healthy_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
printf '%s\n' "$healthy_json" | grep -q '"state":"healthy"'

# A cache far below the full threshold whose stores all fail is the state the
# fullness check alone reads as healthy. Measured live on the fleet host
# 2026-08-23: 22.54% full, 9411 compilations, 9411 cache write errors, zero
# cache hits. The wrapper cost every build and returned nothing.
export FAKE_CACHE_SIZE=225
export FAKE_MAX_CACHE_SIZE=1000
export FAKE_WRITE_ERRORS=9411
export FAKE_COMPILATIONS=9411
set +e
degraded_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
degraded_rc=$?
set -e
test "$degraded_rc" -eq 10
printf '%s\n' "$degraded_json" | grep -q '"state":"degraded"'
printf '%s\n' "$degraded_json" | grep -q '"error_percent":"100.00"'
printf '%s\n' "$degraded_json" | grep -q '"write_errors":9411'

# An explicit bypass answers a degraded cache the same way it answers a full one.
degraded_bypassed="$(RUSTC_WRAPPER= "$ROOT/bin/last-stack-sccache-health" --json)"
printf '%s\n' "$degraded_bypassed" | grep -q '"state":"bypassed"'
printf '%s\n' "$degraded_bypassed" | grep -q '"detail":"degraded-cache-wrapper-bypassed"'

# A cold cache misses everything without failing a single store. That is normal
# warm-up, not a defect, so it must stay healthy.
export FAKE_WRITE_ERRORS=0
export FAKE_COMPILATIONS=9411
cold_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
printf '%s\n' "$cold_json" | grep -q '"state":"healthy"'

# Too few compiles to judge: a handful of early store failures must not flip an
# otherwise fine cache to degraded.
export FAKE_WRITE_ERRORS=3
export FAKE_COMPILATIONS=3
small_sample_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
printf '%s\n' "$small_sample_json" | grep -q '"state":"healthy"'

# A full cache outranks the store-failure check; the caller sees the older,
# more specific verdict.
export FAKE_CACHE_SIZE=999
export FAKE_WRITE_ERRORS=9411
export FAKE_COMPILATIONS=9411
set +e
full_first_json="$("$ROOT/bin/last-stack-sccache-health" --json)"
full_first_rc=$?
set -e
test "$full_first_rc" -eq 10
printf '%s\n' "$full_first_json" | grep -q '"state":"full"'

unset FAKE_WRITE_ERRORS FAKE_COMPILATIONS
export FAKE_CACHE_SIZE=500

unset LAST_STACK_RUSTC_WRAPPER
test "$("$ROOT/bin/last-stack-cargo" test --locked)" = 'wrapper=<> args=<test --locked>'
custom_output="$(LAST_STACK_RUSTC_WRAPPER=custom-wrapper \
  "$ROOT/bin/last-stack-cargo" check)"
test "$custom_output" = 'wrapper=<custom-wrapper> args=<check>'

echo ok
