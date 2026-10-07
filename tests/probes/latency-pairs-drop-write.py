#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh")
source = path.read_text()
old = 'lat_measure_paired_medians_ms op_lat_write "$c_copy" "$b_copy" "hot write"'
assert source.count(old) == 1, "expected one paired hot write call"
path.write_text(source.replace(old, 'lat_measure_paired_medians_ms_DISABLED op_lat_write "$c_copy" "$b_copy" "hot write"', 1))
