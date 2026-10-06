#!/usr/bin/env python3
"""Drop the last-stack-vocab PATH link."""
from pathlib import Path

path = Path("config/host-track/apps.json")
old = """        {
          "source": "bin/last-stack-vocab",
          "target": "$HOME/.local/bin/last-stack-vocab"
        },
"""
file = path.read_text()
count = file.count(old)
assert count == 1, count
path.write_text(file.replace(old, "", 1))
