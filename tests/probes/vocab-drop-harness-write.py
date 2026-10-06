#!/usr/bin/env python3
"""Mutation probe: a new word does not reach the harness file."""
from pathlib import Path

path = Path("bin/last-stack-vocab")
source = path.read_text()
old = '    path.write_text(text, encoding="utf-8")  # harness copy'
new = "    return  # harness copy disabled"
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
