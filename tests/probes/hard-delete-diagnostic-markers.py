#!/usr/bin/env python3
"""Change one hard-delete diagnostic so its fixture must fail."""

import sys
from pathlib import Path

path = Path("skills/lastdb-safe-upgrade/scripts/hard-delete-bar-checks.sh")
source = path.read_text()
anchors = {
    "start": '    log "hard-delete bar: stage=rm start_unix_s=$del_at deadline_s=$HARD_DELETE_KANBAN_DEADLINE_SECS"\n',
    "result": '    hd_log_step rm "$rm_rc" "$del_at" "$dir/rm.out" "$dir/rm.err"\n',
    "deadline": '      warn "hard-delete bar: stage=rm deadline_result=124 deadline_s=$HARD_DELETE_KANBAN_DEADLINE_SECS; the CLI may still have an active request on the candidate copy"\n',
    "show_after": '      hd_log_step show-after "$show_rc" "$step_started" "$dir/show-after.out" "$dir/show-after.err"\n',
    "leak": '  log "hard-delete bar: stage=$stage rc=$rc elapsed_s=$elapsed stdout_bytes=$stdout_bytes stderr_bytes=$stderr_bytes"\n',
}
assert len(sys.argv) == 2 and sys.argv[1] in anchors, "name one diagnostic"
old = anchors[sys.argv[1]]
assert source.count(old) == 1, "expected one diagnostic anchor"
new = old + '  cat "$stderr"\n' if sys.argv[1] == "leak" else "  : # diagnostic marker removed by probe\n"
path.write_text(source.replace(old, new))
