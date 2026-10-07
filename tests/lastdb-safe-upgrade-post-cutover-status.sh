#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/post-cutover-status.sh
. "$root/skills/lastdb-safe-upgrade/scripts/post-cutover-status.sh"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-postcheck.XXXXXX")"

cat > "$scratch/healthy.json" <<'EOF'
{
  "ok": true,
  "status": {
    "resident": {"persist_lane_failures": 0, "deferred_persist_failed": 0},
    "sync": {
      "enabled": true, "recording_local_changes": true,
      "mutation_log_capture_registered": true, "sync_degraded": false,
      "local_writable": true, "mutation_log_frontier_f": 200,
      "capture": {"automatic_compactions": {"keep_small": {"allocated_bytes": 100}}}
    }
  }
}
EOF

# The helper checks a fresh frontier and both persist failure counters.
post_cutover_status_check "$scratch/healthy.json" 100 1 1000 >/dev/null
if post_cutover_status_check "$scratch/healthy.json" 200 1 1000 >/dev/null; then
  echo 'FAIL: unchanged cloud frontier passed' >&2
  exit 1
fi
if post_cutover_status_check "$scratch/healthy.json" 100 1 50 >/dev/null; then
  echo 'FAIL: oversized meter plane passed' >&2
  exit 1
fi

jq '.status.resident.persist_lane_failures = 1' "$scratch/healthy.json" > "$scratch/lane.json"
if post_cutover_status_check "$scratch/lane.json" 100 1 1000 >/dev/null; then
  echo 'FAIL: failed persist lane passed' >&2
  exit 1
fi
jq '.status.sync.mutation_log_capture_registered = false' "$scratch/healthy.json" > "$scratch/capture.json"
if post_cutover_status_check "$scratch/capture.json" 100 1 1000 >/dev/null; then
  echo 'FAIL: absent capture passed' >&2
  exit 1
fi
for temporary in cloud-capture-unregistered cloud-degraded cloud-frontier-stale; do
  post_cutover_status_retryable "POST_CUTOVER_STATUS=$temporary" || {
    echo "FAIL: $temporary did not allow the bounded soak" >&2
    exit 1
  }
done
for terminal in persist-lane-failure deferred-persist-failure writes-disabled meter-group-over-cap cloud-disabled status-invalid; do
  if post_cutover_status_retryable "POST_CUTOVER_STATUS=$terminal"; then
    echo "FAIL: $terminal allowed the bounded soak" >&2
    exit 1
  fi
done
post_cutover_soak_green_in_bounds 300 300 3600 1 || {
  echo 'FAIL: GREEN at the minimum soak time was rejected' >&2
  exit 1
}
post_cutover_soak_green_in_bounds 0 0 3600 1 || {
  echo 'FAIL: explicit zero-minute GREEN was rejected' >&2
  exit 1
}
if post_cutover_soak_green_in_bounds 0 0 3600 0; then
  echo 'FAIL: zero-minute cutover released rollback without a GREEN status' >&2
  exit 1
fi
post_cutover_soak_green_in_bounds 3600 300 3600 1 || {
  echo 'FAIL: GREEN at the soak deadline was rejected' >&2
  exit 1
}
for late_or_unready in '299 1' '3601 1' '300 0'; do
  read -r elapsed confirmed <<< "$late_or_unready"
  if post_cutover_soak_green_in_bounds "$elapsed" 300 3600 "$confirmed"; then
    echo "FAIL: invalid GREEN accepted at elapsed=$elapsed confirmed=$confirmed" >&2
    exit 1
  fi
done
jq '.status.sync.sync_degraded = true' "$scratch/healthy.json" > "$scratch/degraded.json"
if post_cutover_status_check "$scratch/degraded.json" 100 1 1000 >/dev/null; then
  echo 'FAIL: degraded cloud passed' >&2
  exit 1
fi
if [ "$(post_cutover_status_check "$scratch/degraded.json" 100 1 1000 || true)" != 'POST_CUTOVER_STATUS=cloud-degraded' ]; then
  echo 'FAIL: degraded cloud did not return the expected verdict' >&2
  exit 1
fi
jq '.status.sync.enabled = false' "$scratch/healthy.json" > "$scratch/off.json"
post_cutover_status_check "$scratch/off.json" 100 0 1000 >/dev/null
if post_cutover_status_check "$scratch/off.json" 100 1 1000 >/dev/null; then
  echo 'FAIL: cloud-off primary passed a cloud-required bar' >&2
  exit 1
fi
driver="$root/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
rg -q '^SOAK_MIN_SECS=300$' "$driver" \
  || { echo 'FAIL: default five-minute soak changed' >&2; exit 1; }
rg -q '^    SOAK_MIN_SECS=0$' "$driver" \
  || { echo 'FAIL: explicit zero-live-soak cannot remove the minimum' >&2; exit 1; }
last_write_line="$(rg -n '^durability_write_sentinels$' "$driver" | tail -n 1 | cut -d: -f1)"
last_verify_line="$(rg -n '^durability_verify_after_cutover$' "$driver" | tail -n 1 | cut -d: -f1)"
soak_line="$(rg -n '^POST_CUTOVER_WRITE_DONE_S=' "$driver" | cut -d: -f1)"
release_line="$(rg -n '^release_rollback_point$' "$root/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh" | tail -n 1 | cut -d: -f1)"
if [ "$last_write_line" -ge "$last_verify_line" ] || [ "$last_verify_line" -ge "$soak_line" ]; then
  echo 'FAIL: cloud frontier floor was set before the last canary write and read-back' >&2
  exit 1
fi
if ! rg -q 'POST_CUTOVER_WRITE_DONE_S \+ 1' "$driver"; then
  echo 'FAIL: cloud frontier floor does not use the post-write second' >&2
  exit 1
fi
if [ "$soak_line" -ge "$release_line" ]; then
  echo 'FAIL: rollback point released before the live soak' >&2
  exit 1
fi
echo 'PASS: post-cutover status checks'
