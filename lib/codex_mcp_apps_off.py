#!/usr/bin/env python3
"""Disable existing off-policy MCP entries without replacing unrelated config."""
import os
from pathlib import Path
import re
import stat
import sys
import tempfile


def main():
    path = Path(sys.argv[1]).resolve()
    original = path.read_text()
    headers = re.compile(r'^\s*\[([^\n]+)\][ \t]*(?:#.*)?$', re.MULTILINE)
    server = re.compile(r'''mcp_servers\.(?:([\w-]+)|"([^"\n]+)"|'([^'\n]+)')''')
    matches = list(headers.finditer(original))
    replacements = []
    for index, header in enumerate(matches):
        match = server.fullmatch(header[1].strip())
        if not match:
            continue
        name = next(value for value in match.groups() if value is not None)
        if name not in ('kanban', 'situations'):
            continue
        end = matches[index + 1].start() if index + 1 < len(matches) else len(original)
        body = original[header.end():end]
        setting = re.compile(r'^[ \t]*enabled[ \t]*=[ \t]*(?:true|false)[ \t]*(?:#.*)?$', re.MULTILINE)
        if setting.search(body):
            updated = setting.sub('enabled = false', body)
        else:
            updated = '\nenabled = false' + body
        replacements.append((header.end(), end, updated))
    updated = original
    for start, end, body in reversed(replacements):
        updated = updated[:start] + body + updated[end:]
    if updated != original:
        with tempfile.NamedTemporaryFile(mode='w', dir=path.parent, delete=False) as temporary:
            temporary.write(updated)
            temporary.flush()
            os.fsync(temporary.fileno())
            temporary_path = Path(temporary.name)
        try:
            temporary_path.chmod(stat.S_IMODE(path.stat().st_mode))
            temporary_path.replace(path)
        finally:
            temporary_path.unlink(missing_ok=True)
    print('Codex MCP: existing Kanban and Situations entries disabled by host policy')


if __name__ == '__main__':
    main()
