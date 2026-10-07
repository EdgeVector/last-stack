#!/usr/bin/env python3
"""Remove one waiver path rule for a named mutation probe."""

import argparse
from pathlib import Path


MUTATIONS = {
    "canonical": (
        "if not parent.is_dir() or parent.is_symlink() or parent.resolve() != parent:",
        "if not parent.is_dir() or parent.is_symlink():",
    ),
    "approved": (
        "if not is_temp and not is_durable:",
        "if False:",
    ),
    "owner": (
        "parent_stat.st_uid != os.getuid()",
        "False",
    ),
    "mode": (
        "stat.S_IMODE(parent_stat.st_mode) != 0o700",
        "False",
    ),
    "under_home": (
        "if parent == home_real or home_real in parent.parents:",
        "if False:",
    ),
    "device": (
        "if parent.stat().st_dev != home.stat().st_dev:",
        "if False:",
    ),
    "existing": (
        "if not release and (copy_path.exists() or copy_path.is_symlink()):",
        "if False:",
    ),
}

parser = argparse.ArgumentParser()
parser.add_argument("case", choices=MUTATIONS)
case = parser.parse_args().case
target = Path("skills/lastdb-safe-upgrade/scripts/claim-stopped-copy-waiver.py")
old, new = MUTATIONS[case]
source = target.read_text()
assert source.count(old) == 1, f"{case} waiver path anchor changed"
target.write_text(source.replace(old, new, 1))
