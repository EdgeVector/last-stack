#!/usr/bin/env python3
"""Run the cleanup fixture with one explicit safe-upgrade owner-lock state."""

import os
from pathlib import Path
import runpy
import sys


if len(sys.argv) < 2 or sys.argv[1] not in ("absent", "present"):
    raise SystemExit("usage: fixture_entry.py absent|present <cleanup args>")
lock_state = sys.argv.pop(1)
helper = Path(__file__).resolve().parents[2] / "skills/lastdb-safe-upgrade/scripts/cleanup-stopped-copy.py"
owner_lock = f"/tmp/lastdb-safe-upgrade-owner-{os.getuid()}.lock.d"
real_lexists = os.path.lexists


def fixture_lexists(path) -> bool:
    if os.fspath(path) == owner_lock:
        return lock_state == "present"
    return real_lexists(path)


os.path.lexists = fixture_lexists
sys.argv[0] = str(helper)
runpy.run_path(str(helper), run_name="__main__")
