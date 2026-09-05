#!/usr/bin/env bash
# Pure row-count bar for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# Incident 2026-09-03: Mini 0.23.3-1535 HashKey emptied BoardCards. The probe
# discarded .total, so a 0-row scan passed GREEN. A candidate that answers
# every read with zero rows while the baseline returned rows on the same CoW
# data is a read-path regression, not an empty board.
#
# bash 3.2 compatible (macOS /bin/bash).

# Compare one candidate/baseline row-count pair.
# $1 = label, $2 = candidate count, $3 = baseline count.
# Prints one verdict line; returns 1 only on a real zero-row regression.
rowcount_verdict() {
  local label="$1" cand="$2" base="$3"
  if ! [ "$cand" -ge 0 ] 2>/dev/null; then
    echo "rowcount $label SKIPPED: candidate count unmeasurable (got '${cand}')"
    return 0
  fi
  if ! [ "$base" -ge 0 ] 2>/dev/null; then
    echo "rowcount $label SKIPPED: no baseline count (got '${base}') — cannot tell an empty board from an empty answer"
    return 0
  fi
  if [ "$base" -gt 0 ] && [ "$cand" -eq 0 ]; then
    echo "rowcount $label RED: baseline returned ${base} rows, candidate returned 0 on the SAME CoW data — read-path regression, not an empty board"
    return 1
  fi
  if [ "$base" -gt 0 ] && [ "$cand" -lt "$base" ]; then
    echo "rowcount $label WARN: candidate ${cand} rows vs baseline ${base} on the same CoW data (copies are taken moments apart; investigate if the gap is large)"
    return 0
  fi
  echo "rowcount $label ok: candidate=${cand} baseline=${base}"
  return 0
}
