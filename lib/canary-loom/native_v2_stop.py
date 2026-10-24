"""Reuse strict supervised stop only after exact shared-executable consumer checks."""

import os
from itertools import islice
from pathlib import Path

from native_upgrade import check_old_session_health, helper, job_pid, service, unloaded
from native_upgrade_common import regular, require, run, session, sha, stopped, sync_dir
from native_v2_primary import record
from native_v2_plist import read_agent
from native_v2_source import accepted


def consumers(program, primary_target, pid):
    directory = Path.home() / "Library/LaunchAgents"
    require(directory.is_dir() and directory.resolve() == directory, "User LaunchAgents root differs")
    entries = list(islice(directory.iterdir(), 513))  # walk-ok: one named directory; at most 513 entries
    require(len(entries) <= 512, "User LaunchAgent inventory exceeds its bound")
    found = []
    for path in entries:
        if path.suffix != ".plist":
            continue
        value, plist_sha256 = read_agent(path)
        args = value.get("ProgramArguments", [])
        require(isinstance(args, list) and all(isinstance(v, str) for v in args),
                "LaunchAgent ProgramArguments must contain only strings")
        require("Program" not in value or isinstance(value["Program"], str),
                "LaunchAgent Program must be a string")
        executable = value.get("Program", args[0] if args else "")
        refs = [str(v) for v in args if isinstance(v, str)] + [str(executable)]
        direct = bool(executable) and Path(executable).is_absolute() and Path(executable).resolve() == program
        literal = any(str(program) in value or str(Path.home() / ".lastdb/current/lastdbd") == value for value in refs)
        if not direct and not literal:
            continue
        label = value.get("Label")
        require(isinstance(label, str) and label and "/" not in label, "Consumer LaunchAgent label differs")
        target = "gui/" + str(os.getuid()) + "/" + label
        observed = run(["/bin/launchctl", "print", target], check=False)
        if target == primary_target:
            require(observed.returncode == 0 and job_pid(target) == pid, "The exact primary consumer changed")
        else:
            require(observed.returncode == 113, "Another shared-executable consumer is loaded or unknown")
        found.append({"label": label, "plist_sha256": plist_sha256, "primary": target == primary_target})
    require(sum(v["primary"] for v in found) == 1, "The primary executable consumer is not uniquely inventoried")
    opened = run(["/usr/sbin/lsof", "-nP", "-t", str(program)], check=False)
    require(opened.returncode == 0 and set(opened.stdout.split()) == {str(pid)},
            "The executable has another or unknown open consumer")
    return found


def restore_hold(program, expected_inode, expected_sha):
    hold = Path(str(program) + ".prestop-hold")
    if hold.exists() or hold.is_symlink():
        regular(hold)
        require(not program.exists() and not program.is_symlink()
                and hold.stat().st_ino == expected_inode and sha(hold) == expected_sha,
                "Interrupted executable hold identity differs")
        os.replace(hold, program)
        sync_dir(program.parent)
    regular(program)
    require(program.stat().st_ino == expected_inode and sha(program) == expected_sha,
            "The original executable inode or bytes were not restored")


def stop(approval, state, path, identity, expected_program, phase):
    home, _, _, program, target = service(approval)
    require(program == Path(expected_program["path"]) and sha(program) == expected_program["sha256"],
            "The stop executable is not the exact bound program")
    require(job_pid(target) == identity["pid"] and session(home) == identity,
            "The exact supervised stop session changed")
    expected_start = (state["baseline"]["process_start"] if identity == state["baseline"]["session"]
                      else state["starting_process_start"])
    require(run(["/bin/ps", "-p", str(identity["pid"]), "-o", "lstart="]).stdout.strip() == expected_start,
            "The exact supervised process identity changed")
    require(not (home / ".shutdown_flush_ready").exists(), "A stale shutdown receipt exists before stop")
    inode = program.stat().st_ino
    proof = consumers(program, target, identity["pid"])
    require(job_pid(target) == identity["pid"] and session(home) == identity,
            "The stop session changed after consumer inventory")
    if identity == state["baseline"]["session"]:
        check_old_session_health(home, state["baseline"])
        accepted(approval, state["live_recovery_report"], approval["recovery"]["live_request_id"])
    record(path, state, phase + "-requested", executable_consumers=proof,
           stop_program={**expected_program, "inode": inode}, stopping_session=identity)
    try:
        output = helper("launchd-job-checks.sh", "lastdb_launchd_graceful_prestop",
                        "/bin/launchctl", target, program, "300", "150", "1", timeout=510).stdout
        require("LASTDB_LAUNCHD_PRESTOP=ok " in output and "forced_kill=0" in output,
                "Strict stop did not prove a complete unforced shutdown")
        result = stopped(home, identity)
        unloaded(target)
    finally:
        # Restore the exact inode even when the strict helper was interrupted.
        # The selected primary pair is not installed into this shared directory.
        restore_hold(program, inode, expected_program["sha256"])
    record(path, state, phase + "ped", stop_proof=result, last_stopped_session=identity)
    return result
