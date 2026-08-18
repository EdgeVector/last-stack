#!/usr/bin/env bash
# Historical filename retained for CI compatibility. The old reusable durable
# backup behavior is forbidden: every run gets one fresh CoW rollback point.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
bash -n "$driver"

if grep -q '^find_reusable_backup()\|REUSABLE_BACKUP\|rsync -a.*PRIMARY_HOME' "$driver"; then
  echo "FAIL: durable backup reuse/full-copy fallback survived" >&2
  exit 1
fi
grep -q 'cp -cR "\$PRIMARY_HOME" "\$BACKUP"' "$driver"
grep -q 'refusing full-copy fallback' "$driver"
grep -q 'ROLLBACK_READY=1' "$driver"
grep -q '\[ -n "\$PROBE_ROOT" \] || PROBE_ROOT="\$WORK/probes"' "$driver"
grep -q 'LASTDB_PROBE_ROOT="\$PROBE_ROOT/smoke"' "$driver"
grep -q 'LASTDB_SMOKE_FAIL_LOG_DIR="\$BACKUP/.safe-upgrade"' "$driver"

echo "PASS last-stack-safe-upgrade-backup-dedup"
