#!/usr/bin/env python3
"""Mutation probe: uninstall no longer removes the user word list."""
from pathlib import Path

path = Path("bin/last-stack-uninstall")
source = path.read_text()
old = '  remove_managed_instruction_block "$1" "$2" "user-vocabulary"'
new = "  : # user-vocabulary uninstall disabled"
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
