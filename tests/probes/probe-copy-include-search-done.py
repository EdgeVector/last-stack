#!/usr/bin/env python3
"""Remove the Search receipt exclusion for a focused mutation probe."""

from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh")
source = path.read_text()
old = """        # The last path component is apps/search/inbox/done. Skip it before cp.
        continue
"""
new = """        # The last path component is apps/search/inbox/done. Skip it before cp.
        probe_clone_entry "$entry" "$destination/" || return 1
        continue
"""
assert source.count(old) == 1, "Search receipt skip anchor changed"
path.write_text(source.replace(old, new, 1))
