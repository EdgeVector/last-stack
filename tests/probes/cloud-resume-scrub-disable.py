#!/usr/bin/env python3
"""Mutation probe: omit the ready marker from both scrub passes."""
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh")
source = path.read_text()
old = '"$copy"/.cloud_resume_ready; do'
new = '"$copy"/.cloud_resume_ready_DISABLED; do'
assert source.count(old) == 2, "probe anchor count changed"
path.write_text(source.replace(old, new))
