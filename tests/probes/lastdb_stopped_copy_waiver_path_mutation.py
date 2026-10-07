#!/usr/bin/env python3
"""Remove the durable waiver path so its focused test must fail."""

from pathlib import Path


TARGET = Path("skills/lastdb-safe-upgrade/scripts/claim-stopped-copy-waiver.py")
OLD = "    is_durable = parent == durable_parent\n"
NEW = "    is_durable = False\n"

source = TARGET.read_text()
assert source.count(OLD) == 1, "durable waiver path anchor changed"
TARGET.write_text(source.replace(OLD, NEW, 1))
