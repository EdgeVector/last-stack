#!/usr/bin/env bash
# A deterministic clock proves that sample order can change the gate verdict.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
# shellcheck source=skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh
. "$ROOT/skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh"
# shellcheck source=skills/lastdb-safe-upgrade/scripts/latency-paired-samples.sh
. "$ROOT/skills/lastdb-safe-upgrade/scripts/latency-paired-samples.sh"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-latency-pairs.XXXXXX")"
clock_file="$scratch/clock"
count_file="$scratch/count"
order_file="$scratch/order"
LAT_SAMPLES=6
LAT_OP_TIMEOUT_SECS=120
only_case="${1:-all}"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
warn() { printf '%s\n' "$*" >&2; }
now_ms() { cat "$clock_file"; }
median_of() {
  printf '%s\n' "$@" | sort -n | awk '{a[NR]=$1} END {if (NR%2) print a[(NR+1)/2]; else print int((a[NR/2]+a[NR/2+1])/2)}'
}
run_op_with_deadline() {
  # Every operation succeeds. The virtual clock assigns the current load to
  # this call, independent of which daemon the caller names.
  local n now delta
  n="$(cat "$count_file")"
  n=$((n + 1))
  printf '%s\n' "$n" >"$count_file"
  now="$(cat "$clock_file")"
  case "$LAT_FIXTURE_MODE" in
    drift) if [ "$n" -le 6 ]; then delta=1000; else delta=500; fi ;;
    first) if [ $((n % 2)) -eq 1 ]; then delta=1000; else delta=500; fi ;;
    regress) if [ "$3" = candidate ]; then delta=1000; else delta=500; fi ;;
    gate-open|gate-flat) delta=100 ;;
    *) fail "unknown fixture mode $LAT_FIXTURE_MODE" ;;
  esac
  printf '%s\n' "$((now + delta))" >"$clock_file"
  printf '%s' "$3" >>"$order_file"
}
reset_clock() {
  printf '0\n' >"$clock_file"
  printf '0\n' >"$count_file"
  : >"$order_file"
}

# The old driver ran all six candidate samples, then all six baseline samples.
# A shared six-call busy period alone made the candidate look 2x slower.
if [ "$only_case" = all ] || [ "$only_case" = drift ]; then
LAT_FIXTURE_MODE=drift
reset_clock
cand_vals=""
base_vals=""
for i in $(seq 1 "$LAT_SAMPLES"); do
  lat_paired_sample_once fake candidate "hot write" "$i" candidate
  cand_vals="${cand_vals:+$cand_vals }$LAT_PAIRED_SAMPLE_MS"
done
for i in $(seq 1 "$LAT_SAMPLES"); do
  lat_paired_sample_once fake baseline "hot write" "$i" baseline
  base_vals="${base_vals:+$base_vals }$LAT_PAIRED_SAMPLE_MS"
done
# Intentional split: both strings contain only six integer clock values.
# shellcheck disable=SC2086
old_cand="$(median_of $cand_vals)"
# shellcheck disable=SC2086
old_base="$(median_of $base_vals)"
[ "$old_cand/$old_base" = "1000/500" ] || fail "sequential fixture did not create the false regression"
if lat_correlated_within_bar -1 -1 "$old_cand" "$old_base" "$old_cand" "$old_base" >/dev/null; then
  fail "sequential order must turn the busy period into a RED gate"
fi

reset_clock
lat_measure_paired_medians_ms fake candidate baseline "hot write"
[ "$LAT_PAIR_CAND_MS/$LAT_PAIR_BASE_MS" = "750/750" ] || fail "paired drift medians differ"
[ "$(cat "$order_file")" = "candidatebaselinebaselinecandidatecandidatebaselinebaselinecandidatecandidatebaselinebaselinecandidate" ] \
  || fail "paired order did not alternate"
lat_correlated_within_bar -1 -1 "$LAT_PAIR_CAND_MS" "$LAT_PAIR_BASE_MS" \
  "$LAT_PAIR_CAND_MS" "$LAT_PAIR_BASE_MS" >/dev/null \
  || fail "balanced drift must leave the unchanged 1.5x gate GREEN"
fi

# Each first call is slow. A candidate-first pair would still charge every
# slow call to the candidate. Alternating first position shares that cost.
if [ "$only_case" = all ] || [ "$only_case" = first ]; then
LAT_FIXTURE_MODE=first
reset_clock
lat_measure_paired_medians_ms fake candidate baseline "hot scan"
[ "$LAT_PAIR_CAND_MS/$LAT_PAIR_BASE_MS" = "750/750" ] || fail "first-call bias survived alternation"
fi

if [ "$only_case" = all ] || [ "$only_case" = regress ]; then
LAT_FIXTURE_MODE=regress
reset_clock
lat_measure_paired_medians_ms fake candidate baseline "hot write"
[ "$LAT_PAIR_CAND_MS/$LAT_PAIR_BASE_MS" = "1000/500" ] || fail "true regression was hidden"
if lat_correlated_within_bar -1 -1 "$LAT_PAIR_CAND_MS" "$LAT_PAIR_BASE_MS" \
  "$LAT_PAIR_CAND_MS" "$LAT_PAIR_BASE_MS" >/dev/null; then
  fail "the unchanged 1.5x gate must RED a true 2x regression"
fi
fi

if [ "$only_case" = all ] || [ "$only_case" = odd ]; then
LAT_SAMPLES=3
LAT_FIXTURE_MODE=first
reset_clock
if lat_measure_paired_medians_ms fake candidate baseline "hot write" >/dev/null 2>&1; then
  fail "an odd sample count must fail before any operation"
fi
[ "$(cat "$count_file")" = "0" ] || fail "invalid sample count ran an operation"
fi

# LAT_HOT_FILE_GATE=1 drops a paired sample whose file-open counter rises.
# A flat counter stays a time. The flag stays unset for the cases above.
hold_pair_sockets() {
  local cand_sock="$1" base_sock="$2"
  mkdir -p "$(dirname "$cand_sock")" "$(dirname "$base_sock")"
  python3 - "$cand_sock" "$base_sock" <<'PY' &
import os, socket, sys, time
socks = []
for path in sys.argv[1:]:
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.bind(path)
    sock.listen(1)
    socks.append(sock)
time.sleep(60)
PY
  PAIR_SOCK_PID=$!
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if [ -S "$cand_sock" ] && [ -S "$base_sock" ]; then
      return 0
    fi
    sleep 0.1
  done
  return 1
}

if [ "$only_case" = all ] || [ "$only_case" = gate-open ]; then
LAT_FIXTURE_MODE=gate-open
LAT_HOT_FILE_GATE=1
LAT_SAMPLES=6
reset_clock
# macOS rejects a unix socket path longer than 104 bytes.
sock_root="$(mktemp -d /tmp/lg.XXXXXX)"
hold_pair_sockets "$sock_root/c.sock" "$sock_root/b.sock" \
  || fail "gate-open sockets did not appear"
shard_loads_of() {
  local n
  n="$(cat "$scratch/loadcount")"
  printf '%s\n' "$((n + 1))" >"$scratch/loadcount"
  printf '%s\n' "$n"
}
printf '0\n' >"$scratch/loadcount"
lat_measure_paired_medians_ms fake "$sock_root/c.sock" "$sock_root/b.sock" "hot batch-read"
[ "$LAT_PAIR_CAND_MS/$LAT_PAIR_BASE_MS" = "nothot/nothot" ] \
  || fail "a paired sample that opens files is not a hot test"
kill "$PAIR_SOCK_PID" >/dev/null 2>&1 || true
LAT_HOT_FILE_GATE=""
fi

if [ "$only_case" = all ] || [ "$only_case" = gate-flat ]; then
LAT_FIXTURE_MODE=gate-flat
LAT_HOT_FILE_GATE=1
LAT_SAMPLES=6
reset_clock
sock_root="$(mktemp -d /tmp/lg.XXXXXX)"
hold_pair_sockets "$sock_root/c.sock" "$sock_root/b.sock" \
  || fail "gate-flat sockets did not appear"
shard_loads_of() { printf '7\n'; }
lat_measure_paired_medians_ms fake "$sock_root/c.sock" "$sock_root/b.sock" "hot batch-read"
[ "$LAT_PAIR_CAND_MS/$LAT_PAIR_BASE_MS" = "100/100" ] \
  || fail "a later paired sample that opens no file must stay hot"
kill "$PAIR_SOCK_PID" >/dev/null 2>&1 || true
LAT_HOT_FILE_GATE=""
fi

# The driver patterns are literal shell source, including dollar signs.
# shellcheck disable=SC2016
if [ "$only_case" = all ] || [ "$only_case" = wiring ]; then
grep -Fq '. "$_SCRIPT_DIR/latency-paired-samples.sh"' "$DRIVER" \
  || fail "driver does not source the paired sampler"
grep -Fq 'lat_measure_paired_medians_ms op_lat_point "$c_sock" "$b_sock" "hot point-read"' "$DRIVER" \
  || fail "driver does not pair hot point reads"
grep -Fq 'lat_measure_paired_medians_ms op_lat_batch "$c_sock" "$b_sock" "hot batch-read"' "$DRIVER" \
  || fail "driver does not pair hot batch reads"
grep -Fq 'lat_measure_paired_medians_ms op_lat_write "$c_copy" "$b_copy" "hot write"' "$DRIVER" \
  || fail "driver does not pair hot writes"
fi

printf 'OK: six balanced pairs remove order bias and retain the regression gate\n'
