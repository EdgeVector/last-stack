#!/usr/bin/env python3
"""A paired sample that opens files must not stay a hot time."""
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/latency-paired-samples.sh")
source = path.read_text()
old = 'if ! lat_sample_is_hot 1 "$before" "$after"; then'
new = 'if lat_sample_is_hot 1 "$before" "$after"; then'
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
