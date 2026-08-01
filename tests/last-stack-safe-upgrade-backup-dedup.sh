#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
driver="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"

bash -n "$driver"

grep -q '^find_reusable_backup()' "$driver" || {
  echo "FAIL: safe-upgrade must define reusable backup lookup" >&2
  exit 1
}
grep -q 'pre-"\$cand_ver"-from-"\$current_ver"-\*' "$driver" || {
  echo "FAIL: reusable backup lookup must match candidate/current version backups" >&2
  exit 1
}
grep -q 'backup_essentials_ok "\$candidate" && backup_data_is_not_live "\$candidate"' "$driver" || {
  echo "FAIL: reusable backups must pass essentials and live-alias guards" >&2
  exit 1
}
grep -q 'if \[ "\$PROBE_ONLY" -eq 1 \]; then' "$driver" || {
  echo "FAIL: same-version backup reuse must be limited to probe-only runs" >&2
  exit 1
}
grep -q 'reusing valid same-version probe backup' "$driver" || {
  echo "FAIL: safe-upgrade should log same-version backup reuse" >&2
  exit 1
}

reuse_line="$(grep -n 'REUSABLE_BACKUP="$(find_reusable_backup' "$driver" | cut -d: -f1)"
copy_line="$(grep -n 'cp -cR "\$PRIMARY_HOME" "\$BACKUP"' "$driver" | cut -d: -f1)"
[ -n "$reuse_line" ] && [ -n "$copy_line" ] || {
  echo "FAIL: expected reusable lookup and backup copy lines" >&2
  exit 1
}
[ "$reuse_line" -lt "$copy_line" ] || {
  echo "FAIL: same-version reusable backup lookup must happen before cloning primary" >&2
  exit 1
}

echo "PASS last-stack-safe-upgrade-backup-dedup"
