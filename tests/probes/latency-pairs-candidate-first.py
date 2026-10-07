#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/latency-paired-samples.sh")
source = path.read_text()
old = 'if [ $((i % 2)) -eq 1 ]; then'
assert source.count(old) == 1, "expected one order branch"
path.write_text(source.replace(old, 'if true; then', 1))
