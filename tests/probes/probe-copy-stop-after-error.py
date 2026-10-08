#!/usr/bin/env python3
"""Restore the early abort that loses entries after a copy error."""

from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh")
source = path.read_text()
anchors = (
    ('            rc=1\n', '            return 1\n'),
    ('    probe_clone_entry "$entry" "$destination/" || rc=1\n',
     '    probe_clone_entry "$entry" "$destination/" || return 1\n'),
)
for old, new in anchors:
    assert source.count(old) == 1, f"copy-error anchor changed: {old!r}"
    source = source.replace(old, new, 1)
path.write_text(source)
