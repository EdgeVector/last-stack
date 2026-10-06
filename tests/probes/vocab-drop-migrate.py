#!/usr/bin/env python3
"""Mutation probe: setup no longer keeps an older harness word list."""
from pathlib import Path

path = Path("setup")
source = path.read_text()
old = '  "$SOURCE_ROOT/bin/last-stack-vocab" migrate --from "$file"'
new = "  : # migrate disabled"
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
