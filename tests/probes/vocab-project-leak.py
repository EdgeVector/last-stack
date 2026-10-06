#!/usr/bin/env python3
"""Mutation probe: a project word is copied into the user harness."""
from pathlib import Path

path = Path("bin/last-stack-vocab")
source = path.read_text()
old = "    write_project_file(path, updated)  # project scope stops here"
new = """    write_project_file(path, updated)  # project scope stops here
    user_updated = upsert_row(ensure_tables(), section, word, meaning)
    write_user_tables(user_updated)
    sync_harnesses()"""
assert source.count(old) == 1, source.count(old)
path.write_text(source.replace(old, new, 1))
