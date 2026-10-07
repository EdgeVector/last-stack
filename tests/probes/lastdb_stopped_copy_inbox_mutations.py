#!/usr/bin/env python3
"""Named defects for the stopped-copy Search inbox guard."""

from pathlib import Path
import sys

target = Path("skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh")
source = target.read_text()

if len(sys.argv) != 2:
    raise SystemExit("usage: lastdb_stopped_copy_inbox_mutations.py parser|data-parity")

if sys.argv[1] == "parser":
    old = "transient_search_inbox_cp_error_count() {\n"
    new = old + "  printf '1\\n'; return 0\n"
elif sys.argv[1] == "data-parity":
    old = '''    drift="$("$timeout_bin" -s TERM 120 rsync --dry-run --recursive \\
      --itemize-changes --size-only --delete "$home/data/" "$copy/data/")" \\
      || { fail stopped-copy-data-compare-failed; return 1; }
'''
    new = '    drift=""\n'
else:
    raise SystemExit("unknown mutation")

assert source.count(old) == 1, f"expected one anchor, found {source.count(old)}"
target.write_text(source.replace(old, new, 1))
