#!/usr/bin/env python3
"""A first call must not count as a hot test."""
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/latency-bar-checks.sh")
source = path.read_text()
old = '[ "$prior" = "1" ] || return 1'
new = '[ "$prior" != "1" ] || return 1'
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
