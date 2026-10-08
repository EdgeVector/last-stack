#!/usr/bin/env python3
"""Remove the pre-delete path guard for a focused mutation probe."""

from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/write-path-cow-probe.sh")
source = path.read_text()
old = """if ! probe_copy_is_not_primary "$copy" "$PRIMARY_HOME"; then
  fail_red "refusing to remove a probe path that aliases or is inside the primary home: $copy"
fi
"""
assert source.count(old) == 1, "pre-delete path guard anchor changed"
path.write_text(source.replace(old, "", 1))
