#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh")
source = path.read_text()
old = "smoke) printf '%s\\n' 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1' ;;"
new = "key-cap|smoke) printf '%s\\n' 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1' ;;"
assert source.count(old) == 1, "expected one smoke copy flag rule"
path.write_text(source.replace(old, new, 1))
