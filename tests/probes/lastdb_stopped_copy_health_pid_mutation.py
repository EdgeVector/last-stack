#!/usr/bin/env python3
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/live-socket-health.sh")
source = path.read_text()
old = '  pid="${instance_id%%-*}"\n'
assert source.count(old) == 1, "health PID parse anchor changed"
path.write_text(source.replace(old, '  pid="999999"\n', 1))
