#!/usr/bin/env python3
"""Remove all path-link checks to prove the fixture rejects live links."""

from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh")
source = path.read_text()
anchors = (
    ("  probe_receipt_chain_is_safe \"$source\" apps search inbox 'done' || return 2\n",
     "  : # mutation: source path-link check removed\n"),
    ('      [ ! -L "$entry" ] || return 2\n',
     '      : # mutation: recursive path-link check removed\n'),
    ("  probe_receipt_chain_is_safe \"$destination\" apps search inbox 'done' || return 2\n",
     "  : # mutation: copied path-link check removed\n"),
)
for old, new in anchors:
    assert source.count(old) == 1, f"path-link anchor changed: {old!r}"
    source = source.replace(old, new, 1)
path.write_text(source)
