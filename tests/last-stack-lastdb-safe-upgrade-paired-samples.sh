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

# The driver patterns are literal shell source, including dollar signs.
# shellcheck disable=SC2016
if [ "$only_case" = all ] || [ "$only_case" = wiring ]; then
grep -Fq '. "$_SCRIPT_DIR/latency-paired-samples.sh"' "$DRIVER" \
  || fail "driver does not source the paired sampler"
grep -Fq 'lat_measure_paired_medians_ms op_lat_point "$c_sock" "$b_sock" "hot point-read"' "$DRIVER" \
  || fail "driver does not pair hot point reads"
grep -Fq 'lat_measure_paired_medians_ms op_lat_scan "$c_copy" "$b_copy" "hot scan"' "$DRIVER" \
  || fail "driver does not pair hot scans"
grep -Fq 'lat_measure_paired_medians_ms op_lat_write "$c_copy" "$b_copy" "hot write"' "$DRIVER" \
  || fail "driver does not pair hot writes"
fi

printf 'OK: six balanced pairs remove order bias and retain the regression gate\n'
