#!/usr/bin/env python3
"""Drop the Grok skill uninstall line."""
from pathlib import Path

path = Path("bin/last-stack-uninstall")
old = 'remove_from "$HOME/.grok/skills"            "grok"\n'
new = ': # grok skill removal disabled\n'
file = path.read_text()
count = file.count(old)
assert count == 1, count
path.write_text(file.replace(old, new, 1))
