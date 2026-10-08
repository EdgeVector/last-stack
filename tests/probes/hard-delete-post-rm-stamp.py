#!/usr/bin/env python3
"""Make the compaction check use the pre-rm time again."""

from pathlib import Path


path = Path("skills/lastdb-safe-upgrade/scripts/hard-delete-bar-checks.sh")
source = path.read_text()
old = '      del_at="$(date +%s)"\n'
new = '      del_at="$rm_started"\n'
assert source.count(old) == 1, "expected one post-rm timestamp"
path.write_text(source.replace(old, new))
