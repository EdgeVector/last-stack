#!/usr/bin/env python3
"""Mutation probe: disable the real-primary process comparison."""
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = 'if [ "$SMOKE_PRIMARY_PID_BEFORE" != "$SMOKE_PRIMARY_PID_AFTER" ]; then'
new = 'if false; then'
assert source.count(old) == 1, "probe anchor count changed"
path.write_text(source.replace(old, new))
