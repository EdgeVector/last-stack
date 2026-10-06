#!/usr/bin/env python3
"""Drop the Grok skill register line."""
from pathlib import Path

path = Path("setup")
old = '[ "$INSTALL_GROK"     -eq 1 ] && register_into "$HOME/.grok/skills"           "grok"\n'
new = ': # grok skills disabled\n'
file = path.read_text()
count = file.count(old)
assert count == 1, count
path.write_text(file.replace(old, new, 1))
