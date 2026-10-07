#!/usr/bin/env python3
import sys
from pathlib import Path

case = sys.argv[1]
path = Path("skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh")
source = path.read_text()

patches = {
    "dead_pid": [
        ('  ! kill -0 "$pid" 2>/dev/null \\\n', '  true \\\n'),
    ],
    "supervisor": [
        ('  ! kill -0 "$pid" 2>/dev/null \\\n'
         '    && ! lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service" \\\n',
         '  ! kill -0 "$pid" 2>/dev/null \\\n'
         '    && true \\\n'),
    ],
    "listeners": [
        ('    && ! live_unix_socket_has_listener "$home/data/folddb.sock" \\\n', '    && true \\\n'),
        ('    && ! live_unix_socket_has_listener "$home/data/folddb-full.sock" \\\n', '    && true \\\n'),
    ],
    "ledger_once": [
        ('      ($matches | length) == 1 and $matches[0].exit == "clean"\n',
         '      $matches[0].exit == "clean"\n'),
    ],
    "ledger_clean": [
        ('      ($matches | length) == 1 and $matches[0].exit == "clean"\n',
         '      ($matches | length) == 1 and $matches[0].exit != ""\n'),
    ],
    "ledger_shape": [
        ('    all(.[]; type == "object" and (.pid | type) == "number"\n'
         '      and (.start_ts | type) == "number")\n',
         '    true\n'),
    ],
    "marker_once": [
        ('    length == 1 and (.[0] | type) == "object"\n',
         '    (.[0] | type) == "object"\n'),
    ],
    "marker_pid": [
        ('    and .[0].pid == $pid and .[0].start_ts == $start_ts\n',
         '    and .[0].start_ts == $start_ts\n'),
    ],
    "staged_bytes": [
        ('      && [ "$(shasum -a 256 "$copy/current-session.json" | awk \'{print $1}\')" = "$session_sha" ] \\\n',
         '      && true \\\n'),
        ('      && cmp -s "$home/current-session.json" "$copy/current-session.json" \\\n',
         '      && true \\\n'),
    ],
    "source_preserve": [
        ('    unlink "$copy/current-session.json" \\\n',
         '    unlink "$home/current-session.json" \\\n'),
    ],
}

for old, new in patches[case]:
    assert source.count(old) == 1, f"{case}: anchor count {source.count(old)}"
    source = source.replace(old, new, 1)
path.write_text(source)
