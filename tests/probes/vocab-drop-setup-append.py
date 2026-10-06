#!/usr/bin/env python3
"""Mutation probe: setup no longer appends the user word list."""
from pathlib import Path

path = Path("setup")
source = path.read_text()
old = '  append_managed_md_block "$file" "$vocab_src" "$UV_START" "$UV_END"'
new = "  : # vocab append disabled"
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
