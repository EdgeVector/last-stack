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
printf '{"cache_size":%s,"max_cache_size":%s}\n' \
  "${FAKE_CACHE_SIZE:?}" "${FAKE_MAX_CACHE_SIZE:?}"
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

unset LAST_STACK_RUSTC_WRAPPER
test "$("$ROOT/bin/last-stack-cargo" test --locked)" = 'wrapper=<> args=<test --locked>'
custom_output="$(LAST_STACK_RUSTC_WRAPPER=custom-wrapper \
  "$ROOT/bin/last-stack-cargo" check)"
test "$custom_output" = 'wrapper=<custom-wrapper> args=<check>'

echo ok
