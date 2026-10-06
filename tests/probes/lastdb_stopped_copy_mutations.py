#!/usr/bin/env python3
"""Mutate one stopped-copy safety rule for a focused test."""

from pathlib import Path
import sys


MUTATIONS = {
    "preflight": (
        '    | jq -e \'.ok == true and (.blocks | type) == "array" and (.blocks | length) == 0\' >/dev/null',
        '    | jq -e \'(.blocks | type) == "array"\' >/dev/null',
    ),
    "receipt": (
        "    and .version == 1 and .pid == $pid and .start_ts == $start_ts",
        "    and .version == 1 and .pid == $pid",
    ),
    "receipt_arg": (
        '  local home="$1" pid="$2" start_ts="$3" path\n  path="$home/.shutdown_flush_ready"',
        '  local home="$1" pid="$2" start_ts="$3" path="$home/.shutdown_flush_ready"',
    ),
    "live_copy_marker": (
        '  [ ! -e "$home/.cloud_backup_source_copy" ] && [ ! -L "$home/.cloud_backup_source_copy" ]',
        '  true',
    ),
    "plain_tree": (
        '  [ -z "$special" ] || { fail data-special-path-present; return 1; }',
        '  : # accept a linked data path',
    ),
    "healthy_recovery": (
        '    if primary_is_supervised_and_healthy "gui/$(id -u)" "$LAUNCHD_LABEL" "$PRIMARY_HOME/data/folddb.sock"; then',
        '    if false && primary_is_supervised_and_healthy "gui/$(id -u)" "$LAUNCHD_LABEL" "$PRIMARY_HOME/data/folddb.sock"; then',
    ),
    "booting_recovery": (
        '    elif lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "gui/$(id -u)/$LAUNCHD_LABEL"; then',
        '    elif false && lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "gui/$(id -u)/$LAUNCHD_LABEL"; then',
    ),
    "direct_bootstrap": (
        '    && ! lastdb_launchd_job_loaded "$LAUNCHCTL_BIN" "$service"',
        '    && true',
    ),
    "strict_stop": (
        '  if [ "$strict" = 0 ] && [ -n "$loaded" ] && [ "$loaded" -ge "$want" ] 2>/dev/null; then',
        '  if [ -n "$loaded" ] && [ "$loaded" -ge "$want" ] 2>/dev/null; then',
    ),
    "existing_hold": (
        '  if [ "$strict" = 1 ] && { [ -e "$hold" ] || [ -L "$hold" ]; }; then',
        '  if false && { [ -e "$hold" ] || [ -L "$hold" ]; }; then',
    ),
    "forced_kill": (
        '  if [ "$strict" = 1 ] && [ "$forced" = 1 ]; then',
        '  if false && [ "$strict" = 1 ] && [ "$forced" = 1 ]; then',
    ),
    "copy_marker_receipt": (
        '    if receipt != {"version": 1, "pid": pid, "start_ts": start_ts, "flush_ok": True}:',
        '    if False and receipt != {"version": 1, "pid": pid, "start_ts": start_ts, "flush_ok": True}:',
    ),
    "waiver_decision": (
        "    if decision_slug != DECISION or pid <= 0 or start_ts <= 0:",
        "    if pid <= 0 or start_ts <= 0:",
    ),
    "waiver_once": (
        '    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)',
        '    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0)',
    ),
    "waiver_marker_session": (
        "        if claim != {",
        "        if False and claim != {",
    ),
    "waiver_copy_session": (
        '[ ! -e "$copy/current-session.json" ] && [ ! -L "$copy/current-session.json" ]',
        'true',
    ),
    "waiver_live_sync": (
        '.status.sync.enabled == false',
        '.status.sync.enabled == true',
    ),
    "waiver_marker_copy_path": (
        '            "copy_path": str(copy),',
        '            "copy_path": claim.get("copy_path"),',
    ),
    "waiver_claim_before_stop": (
        '  STOP_STARTED=1\n  stop_out=',
        '  python3 "$SCRIPT_DIR/claim-stopped-copy-waiver.py" --home "$PRIMARY_HOME" --pid "$OLD_PID" --start-ts "$start_ts" --copy-path "$COPY_DIR" --decision-slug "$ACCEPT_UNPROVED_FLUSH"\n  STOP_STARTED=1\n  stop_out=',
    ),
}


def main() -> None:
    if len(sys.argv) != 3 or sys.argv[1] not in MUTATIONS:
        raise SystemExit("usage: script <mutation> <target>")
    path = Path(sys.argv[2])
    data = path.read_text()
    old, new = MUTATIONS[sys.argv[1]]
    assert data.count(old) == 1, f"expected one anchor for {sys.argv[1]}"
    path.write_text(data.replace(old, new, 1))


if __name__ == "__main__":
    main()
