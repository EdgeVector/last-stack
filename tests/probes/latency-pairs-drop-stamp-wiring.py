#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = 'stamp_env="$(probe_stamp_env_for_label "$label")"'
assert source.count(old) == 1, "expected one label-based stamp assignment"
path.write_text(source.replace(old, 'stamp_env=""', 1))
