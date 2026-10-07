#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = 'SMOKE_STAMP_ENV="$(probe_stamp_env_for_label smoke)"'
assert source.count(old) == 1, "expected one smoke copy stamp assignment"
path.write_text(source.replace(old, 'SMOKE_STAMP_ENV=""', 1))
