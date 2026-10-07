#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/latency-paired-samples.sh")
source = path.read_text()
old = '''  [ "$LAT_SAMPLES" -ge 2 ] && [ $((LAT_SAMPLES % 2)) -eq 0 ]'''
assert source.count(old) == 1, "expected one even-count check"
path.write_text(source.replace(old, '  [ "$LAT_SAMPLES" -ge 2 ]', 1))
