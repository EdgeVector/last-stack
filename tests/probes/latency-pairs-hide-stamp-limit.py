#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = "; copy-only conflict stamp requested, completion not asserted"
assert source.count(old) == 1, "expected one copy-only stamp limit log"
path.write_text(source.replace(old, "", 1))
