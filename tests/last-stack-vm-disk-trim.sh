#!/usr/bin/env bash
# Regression cover for last-stack-vm-disk-trim, the owned reclaim path for
# sparse VM disk overhang (79.6 GiB found untrimmed on 2026-08-23).
#
# Two failure shapes drive this fixture:
#   1. A guard that fails OPEN. This helper runs `docker run --privileged
#      --pid=host` — it must stay a clean noop when docker is missing or the
#      daemon is unreachable, which is the normal state inside the scheduled
#      routine sandbox.
#   2. An unattended image pull. `docker run` pulls a missing image by default,
#      which would download megabytes on a disk-pressure path. Every protect
#      assertion below carries the vacuity companion: the eligible run in the
#      same fixture must actually invoke fstrim.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$ROOT/bin/last-stack-vm-disk-trim"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/vm-disk-trim-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

H="$tmp/home"
mkdir -p "$H"
stub="$tmp/stub"
mkdir -p "$stub"
argv_log="$tmp/docker-argv.log"

# A docker stub that records every invocation. DOCKER_MODE selects the shape:
#   ok            — daemon up, image local, fstrim succeeds
#   down          — daemon unreachable (`docker info` fails)
#   no-image      — daemon up, image NOT local
#   fstrim-fails  — daemon up, image local, the run fails
cat >"$stub/docker" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${DOCKER_ARGV_LOG:?}"
case "$1" in
  info) [ "${DOCKER_MODE:-ok}" = down ] && exit 1; exit 0 ;;
  image) [ "${DOCKER_MODE:-ok}" = no-image ] && exit 1; exit 0 ;;
  run) [ "${DOCKER_MODE:-ok}" = fstrim-fails ] && exit 1; exit 0 ;;
esac
exit 0
STUB
chmod +x "$stub/docker"

# A df stub: the helper reads host free space before and after the trim, and
# reports the delta. FREE_KIB_SEQ feeds one value per call.
cat >"$stub/df" <<'STUB'
#!/usr/bin/env bash
seq_file="${FREE_KIB_SEQ:?}"
value="$(sed -n '1p' "$seq_file")"
sed -i.bak '1d' "$seq_file" 2>/dev/null || true
rm -f "$seq_file.bak" 2>/dev/null || true
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/disk3s5 100000000 1 %s 1%%%% /\n' "${value:-1048576}"
STUB
chmod +x "$stub/df"

seq_file="$tmp/free.seq"
run() {
  : >"$argv_log"
  env HOME="$H" PATH="$stub:$PATH" \
    DOCKER_ARGV_LOG="$argv_log" FREE_KIB_SEQ="$seq_file" \
    DOCKER_MODE="${DOCKER_MODE:-ok}" \
    bash "$bin" "$@"
}
set_free() { printf '%s\n' "$@" >"$seq_file"; }
clear_stamp() { rm -f "$H/.local/state/last-stack/vm-disk-trim/last-run"; }

# --- Guard: no docker CLI is a clean noop, not an error --------------------
set_free 1048576 1048576
nodocker="$tmp/nodocker"
mkdir -p "$nodocker"
cp "$stub/df" "$nodocker/df"
out="$(env HOME="$H" PATH="$nodocker:/usr/bin:/bin" FREE_KIB_SEQ="$seq_file" bash "$bin")" \
  || fail "missing docker must exit 0; got exit $?"
printf '%s\n' "$out" | grep -q 'vm_trim_skipped=no-docker' \
  || fail "expected vm_trim_skipped=no-docker; got: $out"
printf '%s\n' "$out" | grep -q 'vm_trimmed_gb=0' \
  || fail "no-docker run must report vm_trimmed_gb=0; got: $out"

# --- Guard: unreachable daemon (the routine sandbox) is a clean noop -------
clear_stamp; set_free 1048576 1048576
out="$(DOCKER_MODE=down run)" || fail "unreachable daemon must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_skipped=docker-unreachable' \
  || fail "expected vm_trim_skipped=docker-unreachable; got: $out"
grep -q '^run ' "$argv_log" && fail "docker run was invoked with the daemon down"

# --- Guard: a non-local image is skipped and NEVER pulled -----------------
clear_stamp; set_free 1048576 1048576
out="$(DOCKER_MODE=no-image run)" || fail "missing image must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_skipped=image-not-local' \
  || fail "expected vm_trim_skipped=image-not-local; got: $out"
grep -qE '^(pull|run) ' "$argv_log" \
  && fail "helper pulled or ran with a non-local image: $(cat "$argv_log")"

# --- Vacuity companion: the eligible run really trims ---------------------
# before = 1 GiB free, after = 11 GiB free -> 10.0 GiB reported.
clear_stamp; set_free 1048576 11534336
out="$(run)" || fail "eligible run must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_status=trimmed' \
  || fail "expected vm_trim_status=trimmed; got: $out"
printf '%s\n' "$out" | grep -q 'vm_trimmed_gb=10.0' \
  || fail "expected vm_trimmed_gb=10.0 from the df delta; got: $out"
grep -q 'fstrim -a' "$argv_log" || fail "fstrim was never invoked: $(cat "$argv_log")"
grep -q 'pull=never' "$argv_log" || fail "docker run must pass --pull=never"
grep -q 'privileged' "$argv_log" || fail "docker run must be privileged to reach the VM"
[ -f "$H/.local/state/last-stack/vm-disk-trim/last-run" ] || fail "throttle stamp not written"

# --- Throttle: a second run inside the interval does nothing --------------
set_free 1048576 1048576
out="$(run)" || fail "throttled run must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_skipped=throttled' \
  || fail "expected vm_trim_skipped=throttled; got: $out"
grep -q '^run ' "$argv_log" && fail "throttled run still invoked docker run"

# --- --force overrides the throttle ---------------------------------------
set_free 1048576 1048576
out="$(run --force)" || fail "forced run must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_status=trimmed' \
  || fail "--force must bypass the throttle; got: $out"

# --- Free ceiling: skip while the host has plenty of room -----------------
clear_stamp; set_free 209715200 209715200   # 200 GiB free
out="$(run --free-below-gib 100)" || fail "ceiling skip must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_skipped=free-above-ceiling' \
  || fail "expected vm_trim_skipped=free-above-ceiling; got: $out"
grep -q '^run ' "$argv_log" && fail "docker run invoked above the free ceiling"

# --- Free ceiling companion: under the ceiling it does trim ---------------
clear_stamp; set_free 52428800 62914560     # 50 GiB -> 60 GiB
out="$(run --free-below-gib 100)" || fail "under-ceiling run must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_status=trimmed' \
  || fail "under the ceiling the helper must trim; got: $out"

# --- Dry run touches nothing ----------------------------------------------
clear_stamp; set_free 1048576 1048576
out="$(run --dry-run)" || fail "dry run must exit 0"
printf '%s\n' "$out" | grep -q 'vm_trim_status=dry-run' \
  || fail "expected vm_trim_status=dry-run; got: $out"
grep -q '^run ' "$argv_log" && fail "dry run invoked docker run"
[ -f "$H/.local/state/last-stack/vm-disk-trim/last-run" ] \
  && fail "dry run wrote the throttle stamp"

# --- A failed fstrim is an error, never a silent trimmed=0 ----------------
clear_stamp; set_free 1048576 1048576
set +e
out="$(DOCKER_MODE=fstrim-fails run)"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "a failed fstrim must exit 1; got exit $rc"
printf '%s\n' "$out" | grep -q 'vm_trim_error=fstrim-failed' \
  || fail "expected vm_trim_error=fstrim-failed; got: $out"
[ -f "$H/.local/state/last-stack/vm-disk-trim/last-run" ] \
  && fail "a failed trim must not stamp the throttle"

echo "PASS last-stack-vm-disk-trim"
