#!/usr/bin/env bash
# lib/loom-drive-workers.sh
#
# One helper, shared by every wrapper that re-attaches to a loom execution
# after loom's own drive deadline fires (last-stack-whats-wrong-loom,
# last-stack-why-stopped-loom). Sourced, never executed.

# Stop the `loom ... drive-detached <exec>` workers this wrapper already gave
# up on, before it reaps and re-attaches.
#
# MEASURED 2026-09-07 (run 2026-09-07T07-23-11-776Z, routine-app-owner):
# `loom run --key` starts a NEW detached driver on every re-attach and leaves
# the previous one alive. The five attempts of that one hour left five live
# drivers on lx-20260907T072339.095-20055-1 and eleven on its child, sixteen
# processes, ages 18-47 min, host load average 42. Their start times line up
# 1:1 with the wrapper's own attempt log (remaining=1357s -> 07:41,
# remaining=1020s -> 07:46, remaining=697s -> 07:52), so the herd is this
# retry loop, not loom fan-out.
#
# The herd is also why the reap below answered `reaped` while nothing moved:
# `loom reap` recovers only a LEASE-LESS execution, and those live drivers
# still held the lease. Every attempt then added one more writer to the same
# LoomExecution row. On the same node `lastdb ops` read 5,025 of 12,695 loom
# LoomExecution mutations rejected 409 (CAS precondition), so the row could
# not settle and the execution sat at GATHER until a human killed the workers.
#
# So stop them first, which is what "re-attach" already claims to do. This is
# narrow on purpose:
#   - only processes whose command is `drive-detached <this exec id>`,
#   - plus a `drive-detached` child of one of those (loom drives a sub
#     execution from the parent worker; killing only the parent reparents the
#     child to PID 1 and it survives forever),
#   - only after this wrapper has already spent its whole drive deadline on
#     them, which is the only branch that calls this,
#   - SIGTERM first, then SIGKILL for a survivor.
# It never touches a driver for another execution, and never the node.
#
# Prints one word: stopped=<n>, none, or unreadable (a sandbox that denies
# `ps` — see papercut-routine-process-inspection-sandbox-denied). Always
# returns 0: this is best effort and the reap plus retry run either way.
stop_abandoned_drive_workers() {
  stop_id="$1"
  if [ -z "$stop_id" ] || [ "$stop_id" = "unknown" ]; then
    printf 'none\n'
    return 0
  fi
  STOP_ID="$stop_id" python3 -c '
import os, signal, subprocess, sys, time

exec_id = os.environ["STOP_ID"]
MARKER = "drive-detached"


def table():
    """(pid, ppid, command) for every process, or None when ps is denied."""
    try:
        out = subprocess.run(
            ["ps", "-Ao", "pid=,ppid=,command="],
            capture_output=True, text=True, timeout=20,
        )
    except Exception:
        return None
    if out.returncode != 0 or not out.stdout.strip():
        return None
    rows = []
    for line in out.stdout.splitlines():
        parts = line.split(None, 2)
        if len(parts) < 3:
            continue
        try:
            rows.append((int(parts[0]), int(parts[1]), parts[2]))
        except ValueError:
            continue
    return rows


def is_loom_driver(cmd):
    """True only for `.../loom ... drive-detached ...`.

    The marker alone is not enough. A routine harness carries its whole
    prompt on its command line, so a `claude -p` dispatch that merely
    QUOTES this text matches a substring search -- four of them did on
    2026-09-07. Signalling one of those would kill the routine that is
    running this wrapper. Require argv[0] to be the loom binary.
    """
    if MARKER not in cmd:
        return False
    argv0 = cmd.split(None, 1)[0] if cmd.split() else ""
    return os.path.basename(argv0) == "loom"


def drives(rows, wanted):
    """Drivers for `wanted`, plus their drive-detached children."""
    mine = set()
    for pid, _ppid, cmd in rows:
        if is_loom_driver(cmd) and wanted in cmd:
            mine.add(pid)
    kids = set()
    for pid, ppid, cmd in rows:
        if pid not in mine and ppid in mine and is_loom_driver(cmd):
            kids.add(pid)
    return mine | kids


rows = table()
if rows is None:
    print("unreadable")
    raise SystemExit(0)

targets = drives(rows, exec_id)
if not targets:
    print("none")
    raise SystemExit(0)

for pid in sorted(targets):
    try:
        os.kill(pid, signal.SIGTERM)
    except OSError:
        pass

def still_alive(pid):
    """signal 0 asks the kernel, so this needs no second `ps`."""
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


# A short bounded wait, then SIGKILL whatever is still holding the lease.
deadline = time.time() + 10
alive = set(targets)
while alive and time.time() < deadline:
    time.sleep(0.5)
    alive = {pid for pid in alive if still_alive(pid)}

for pid in sorted(alive):
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass

print("stopped=%d" % len(targets))
'
  return 0
}
