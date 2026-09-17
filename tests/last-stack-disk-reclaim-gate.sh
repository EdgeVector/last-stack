#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/bin/last-stack-disk-reclaim-gate"
chmod +x "$GATE"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/disk-reclaim-gate.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/last-stack/bin"
cat >"$tmp/last-stack/bin/last-stack-brain-append-heartbeat" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/last-stack/bin/last-stack-brain-append-heartbeat" "$GATE"

export LAST_STACK_ROOT="$tmp/last-stack"
export LAST_STACK_HEARTBEATS_FILE="$tmp/heartbeats.log"
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=80

run_case() {
  local name="$1"
  local expected_rc="$2"
  local expected_text="$3"
  set +e
  out="$("$GATE" 2>&1)"
  rc=$?
  set -e
  if [ "$rc" -ne "$expected_rc" ]; then
    echo "$name: expected rc=$expected_rc, got rc=$rc" >&2
    echo "$out" >&2
    exit 1
  fi
  if ! printf '%s\n' "$out" | grep -q "$expected_text"; then
    echo "$name: missing $expected_text" >&2
    echo "$out" >&2
    exit 1
  fi
}

# 200 GiB free (200 * 1024 * 1024 KiB) ≥ 80 → skip
export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/disk 1 1 209715200 1% /'"
run_case above-floor 0 'above-floor'

# 10 GiB free < 80 → proceed
export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted' '/dev/disk 1 1 10485760 1% /'"
run_case under-floor 10 'under-floor'

export LAST_STACK_DISK_RECLAIM_DF_CMD="false"
run_case df-failed 10 'df-failed'

export LAST_STACK_DISK_RECLAIM_DF_CMD="printf '%s\n' 'not a df table'"
run_case df-parse-failed 10 'df-parse-failed'

echo "ok last-stack-disk-reclaim-gate"
