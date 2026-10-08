#!/usr/bin/env python3
"""Change one hard-delete deadline so case 12 must fail."""

import sys
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/hard-delete-bar-checks.sh")
source = path.read_text()
anchors = {
    "rm": ("HARD_DELETE_RM_DEADLINE_SECS=180", "HARD_DELETE_RM_DEADLINE_SECS=90"),
    "other": ("HARD_DELETE_KANBAN_DEADLINE_SECS=90", "HARD_DELETE_KANBAN_DEADLINE_SECS=180"),
}
assert len(sys.argv) == 2 and sys.argv[1] in anchors, "name one deadline"
old, new = anchors[sys.argv[1]]
assert source.count(old) == 1, "expected one deadline anchor"
path.write_text(source.replace(old, new))
