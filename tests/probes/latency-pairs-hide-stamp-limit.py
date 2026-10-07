#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = "real-data smoke copy: conflict stamp requested, completion not asserted"
assert source.count(old) == 1, "expected one smoke copy stamp limit log"
path.write_text(source.replace(old, "", 1))
