"""Strict RunV2 stop with the accepted executable-consumer safeguard."""

from pathlib import Path
import time

from native_upgrade import helper, job_pid, service, unloaded
from native_upgrade_common import require, run, session, sha, stopped
from native_v2_stop import consumers, restore_hold
from native_run_v2_primary import live, record, selected_session


def stop(approval, state, path, identity, expected_program, phase):
    require(phase in ("stop", "rollback-stop"), "Unknown RunV2 stop policy")
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
    # Recovery must be able to stop an unhealthy candidate. It retains every
    # identity guard; only the initial baseline stop requires health admission.
    observed = (selected_session(approval, state, True) if phase == "rollback-stop"
                else live(approval, state, False)["session"])
    require(observed == identity
            and run(["/bin/ps", "-p", str(identity["pid"]), "-o", "lstart="]).stdout.strip() == expected_start,
            "The stop session changed after consumer inventory")
    require(state.get("effect_started_at") or 0 <= time.time() - approval["approved_at"] <= 86400,
            "The candidate approval expired before the first stop")
    timing = {} if state.get("effect_started_at") else {"effect_started_at": int(time.time())}
    record(path, state, phase + "-requested", executable_consumers=proof,
           stop_program={**expected_program, "inode": inode}, stopping_session=identity, **timing)
    try:
        output = helper("launchd-job-checks.sh", "lastdb_launchd_graceful_prestop",
                        "/bin/launchctl", target, program, "300", "150", "1", timeout=510).stdout
        require("LASTDB_LAUNCHD_PRESTOP=ok " in output and "forced_kill=0" in output,
                "Strict stop did not prove a complete unforced shutdown")
        result = stopped(home, identity)
        unloaded(target)
    finally:
        restore_hold(program, inode, expected_program["sha256"])
    record(path, state, phase + "ped", stop_proof=result, last_stopped_session=identity)
    return result
