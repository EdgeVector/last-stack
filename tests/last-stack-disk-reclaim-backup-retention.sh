#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
routine="$ROOT/routines/disk-reclaim.md"

grep -q 'backup_retention_blocked=off_machine_unverified' "$routine" || {
  echo "FAIL: disk-reclaim must block local backup pruning when off-machine backup is unverified" >&2
  exit 1
}
grep -q 'newest 3 retained' "$routine" || {
  echo "FAIL: lsof checks must be scoped to the retained backup set" >&2
  exit 1
}
grep -q 'newer than 2 days' "$routine" || {
  echo "FAIL: lsof-inconclusive grace window should be explicit" >&2
  exit 1
}
grep -q 'backup_lsof_inconclusive_pruned=<n>' "$routine" || {
  echo "FAIL: disk-reclaim should report old inconclusive candidates it prunes" >&2
  exit 1
}

echo "PASS last-stack-disk-reclaim-backup-retention"
