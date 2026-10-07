#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = '  ${SMOKE_STAMP_ENV:+"$SMOKE_STAMP_ENV"} \\\n'
new = '  LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=0 \\\n'
assert source.count(old) == 1, "expected one smoke copy env argument"
path.write_text(source.replace(old, new, 1))
