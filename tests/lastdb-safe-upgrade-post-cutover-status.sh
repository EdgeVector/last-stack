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
jq '.status.sync.enabled = false' "$scratch/healthy.json" > "$scratch/off.json"
post_cutover_status_check "$scratch/off.json" 100 0 1000 >/dev/null
if post_cutover_status_check "$scratch/off.json" 100 1 1000 >/dev/null; then
  echo 'FAIL: cloud-off primary passed a cloud-required bar' >&2
  exit 1
fi
soak_line="$(rg -n '^POST_CUTOVER_WRITE_S=' "$root/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh" | cut -d: -f1)"
release_line="$(rg -n '^release_rollback_point$' "$root/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh" | tail -n 1 | cut -d: -f1)"
if [ "$soak_line" -ge "$release_line" ]; then
  echo 'FAIL: rollback point released before the live soak' >&2
  exit 1
fi
echo 'PASS: post-cutover status checks'
