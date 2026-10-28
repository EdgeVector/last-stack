#!/usr/bin/env python3
"""Candidate-bound native in-place upgrade, through Loom local recovery only."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import signal
import sys
import time
import uuid

sys.dont_write_bytecode = True

from native_upgrade_common import (alive, baseline_health, health,
    load, memory, pair, private_dir, regular, require, run, save, session, sha, stopped, sync_dir, wait_health)
from native_upgrade_probe import probe

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "skills/lastdb-safe-upgrade/scripts"
MODE = "native-inplace-cloud-off"
IMMUTABLE = ("candidate", "candidate_cli", "version", "lastdbd_version", "lastdb_version",
             "lastdbd_sha256", "lastdb_sha256", "source_git_oid", "candidate_artifact_digest",
             "safe_upgrade_protocol_version", "native_approval", "native_approval_sha256", "upgrade_mode", "native_reopen")
STABLE = ("identity.key", ".bootstrap_done", "data/.device_id", "cloud_sync.json",
          "cloud_sync.json.paused", "org_sync_registration.json")


def helper(name, function, *args, timeout=30):
    return run(["/bin/bash", "-c", 'set -euo pipefail; . "$1"; shift; "$@"',
                "native-safe-upgrade", SCRIPTS / name, function, *args], timeout=timeout)


class Owner:
    def __init__(self, candidate):
        self.path = f"/tmp/lastdb-safe-upgrade-owner-{os.getuid()}.lock.d"
        self.token = str(os.getpid()) + "." + uuid.uuid4().hex
        self.candidate = candidate

    def __enter__(self):
        helper("owner-lock.sh", "safe_upgrade_owner_lock_acquire", self.path, self.token,
               str(os.getpid()), self.candidate, MODE)
        return self

    def __exit__(self, *unused):
        helper("owner-lock.sh", "safe_upgrade_owner_lock_release", self.path, self.token, "1")


def context():
    ctx = json.loads(os.environ.get("LOOM_INPUT", "{}"))
    item = ctx.get("item", {})
    require(isinstance(ctx, dict) and isinstance(item, dict), "Invalid Loom input")
    require(not any(k in item and k in ctx and item[k] != ctx[k] for k in IMMUTABLE),
            "Immutable Loom item/context conflict")
    ctx = {**item, **{k: v for k, v in ctx.items() if k != "item"}}
    require(ctx.get("upgrade_mode") == MODE and ctx.get("safe_upgrade_protocol_version") == "8",
            "Native upgrade protocol differs")
    require(not ctx.get("zero_live_soak") and not ctx.get("accept_stale_recovery_point"),
            "Native mode does not accept legacy gate exceptions")
    require(type(ctx.get("native_reopen")) is bool and type(ctx.get("native_probe_only")) is bool,
            "Native reopen and probe-only must be booleans")
    return ctx


def binding(ctx):
    candidate = pair(Path(ctx["candidate"]).parent)
    require(candidate["lastdbd"]["path"] == ctx["candidate"]
            and candidate["lastdb"]["path"] == ctx["candidate_cli"], "Pair paths differ")
    for name, prefix in (("lastdbd", "lastdbd"), ("lastdb", "lastdb")):
        require(candidate[name]["sha256"] == ctx[prefix + "_sha256"]
                and candidate[name]["version"] == ctx[prefix + "_version"], "Candidate bytes differ")
    digest = hashlib.sha256("\0".join(str(ctx[k]) for k in (
        "source_git_oid", "candidate", "candidate_cli", "lastdbd_sha256", "lastdb_sha256",
        "lastdbd_version", "lastdb_version")).encode()).hexdigest()
    require(digest == ctx["candidate_artifact_digest"], "Candidate artifact digest differs")
    require(sha(ctx["native_approval"]) == ctx["native_approval_sha256"], "Approval file changed")
    approval = load(ctx["native_approval"], maximum=16384)
    require(approval.get("schema") == "lastdb.native-upgrade-approval.v1"
            and approval.get("approved_by") == "Tom" and bool(approval.get("quote"))
            and approval.get("mode") == MODE and approval.get("cloud_off") is True
            and approval.get("primary_data_copy") is False,
            "An explicit candidate-bound native Cloud-Off approval is required")
    require(approval["source_git_oid"] == ctx["source_git_oid"] and approval["candidate"] == candidate,
            "Approval and exact candidate differ")
    require(re.fullmatch(r"[0-9a-f]{40}", ctx["source_git_oid"]) is not None, "Invalid full source OID")
    return candidate, approval


def approval_fresh(approval, at=None):
    now = int(time.time()) if at is None else at
    require(type(approval.get("approved_at")) is int and
            0 <= now - approval["approved_at"] <= 86400, "Native approval is outside its 24-hour window")


def emit(values):
    print("LOOM_CONTEXT_PATCH:" + json.dumps(values, separators=(",", ":")), flush=True)
    print("PASS", flush=True)


def service(approval):
    path = Path(approval["launchd_plist"])
    regular(path, maximum=1024 * 1024)
    with path.open("rb") as stream:
        plist = plistlib.load(stream)
    label = plist["Label"]
    require(isinstance(label, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", label), "Invalid LaunchAgent label")
    require(path == Path.home() / "Library/LaunchAgents" / (label + ".plist"),
            "Expected the exact primary user LaunchAgent")
    home = Path(approval["primary_home"])
    require(home.is_absolute() and home.resolve() == home and home.is_dir()
            and home.stat().st_uid == os.getuid(), "The primary home is unsafe")
    require(home == Path.home() / ".lastdb", "This route supports only the named primary home")
    arguments = plist["ProgramArguments"]
    require(isinstance(arguments, list) and len(arguments) > 0, "LaunchAgent arguments are absent")
    program = Path(arguments[0])
    if approval.get("mode") == "native-run-v2-ci" and program == home / "current" / "lastdbd":
        require((home / "current").is_symlink(), "The ordinary RunV2 stable program pointer is absent")
        program = program.resolve(strict=True)
    require(program.is_absolute() and program.name == "lastdbd" and program.resolve() == program
            and program.parent == (home / "current").resolve(), "Primary pair path differs from current")
    configured_home = plist.get("EnvironmentVariables", {}).get("LASTDB_HOME", str(Path.home() / ".lastdb"))
    if "--data-dir" in arguments:
        configured_home = arguments[arguments.index("--data-dir") + 1]
    require(Path(configured_home).expanduser().resolve() == home, "LaunchAgent home differs")
    require("--socket-path" not in arguments and "--full-socket-path" not in arguments,
            "A proxy worker needs its own supported upgrade route")
    require(plist.get("KeepAlive") is True or isinstance(plist.get("KeepAlive"), dict),
            "Primary LaunchAgent must supervise the daemon")
    return home, path, plist, program, "gui/" + str(os.getuid()) + "/" + label


def job_pid(target):
    result = run(["/bin/launchctl", "print", target], check=False)
    match = re.search(r"^\s*pid = (\d+)\s*$", result.stdout, re.M)
    return int(match.group(1)) if result.returncode == 0 and match else None


def unloaded(target):
    require(run(["/bin/launchctl", "print", target], check=False).returncode != 0,
            "The primary LaunchAgent is still loaded")


def memory_limit(plist):
    # Use the existing guard ceiling, with no live config change or limit raise.
    values = [plist.get("EnvironmentVariables", {}).get("LASTDBD_RSS_LIMIT_MB")]
    guard = Path.home() / "Library/LaunchAgents" / (plist["Label"].split(".lastdbd")[0] + ".lastdbd-memory-guard.plist")
    if guard.exists():
        regular(guard, maximum=1024 * 1024)
        with guard.open("rb") as stream:
            values.append(plistlib.load(stream).get("EnvironmentVariables", {}).get("LASTDBD_RSS_LIMIT_MB"))
    limits = []
    for value in values:
        if value is not None:
            require(str(value).isdigit() and 128 <= int(value) <= 1048576, "Invalid existing memory guard limit")
            limits.append(int(value))
    return min(limits or [16384])


def stable(home):
    values = {}
    for name in STABLE:
        path = home / name
        if path.exists() or path.is_symlink():
            regular(path, maximum=1024 * 1024)
            values[name] = sha(path)
        else:
            values[name] = None
    require(values["identity.key"] is not None and values["cloud_sync.json"] is None,
            "The existing identity and Cloud-Off state are required")
    data = home / "data"
    native = data / "disk-pack"
    require(native.is_dir() and native.resolve() == native, "Primary native disk home is absent")
    return {"files": values, "home_inode": home.stat().st_ino, "data_inode": data.stat().st_ino,
            "native_inode": native.stat().st_ino}


def check_environment(pid, plist):
    # Keep process values in memory only. Never persist or print this output.
    rendered = run(["/bin/ps", "eww", "-p", str(pid), "-o", "command="]).stdout
    for name, value in plist.get("EnvironmentVariables", {}).items():
        require(re.search(r"(?:^|\s)" + re.escape(name + "=" + str(value)) + r"(?:\s|$)", rendered),
                "The supervised process configuration differs at key: " + name)


def snapshot(approval):
    return _snapshot(approval)


def baseline_snapshot(approval, baseline=None):
    require(approval.get("mode") in (MODE, "native-v2-ci"),
            "Baseline history is only for the reviewed native upgrade policies")
    return _snapshot(approval, baseline, baseline_history=True)


def _snapshot(approval, baseline=None, *, baseline_history=False):
    home, plist_path, plist, program, target = service(approval)
    pid = job_pid(target)
    require(pid is not None, "The primary LaunchAgent is not active")
    identity = session(home)
    require(identity["pid"] == pid, "Primary session differs from supervision")
    check_environment(pid, plist)
    programs = pair(program.parent)
    require(baseline is None or identity == baseline["session"], "The baseline session changed")
    if baseline_history:
        current = (baseline_health(home / "data/folddb.sock", programs["lastdbd"]["version"], identity)
                   if baseline is None else check_old_session_health(home, baseline))
    else:
        current = health(home / "data/folddb.sock", programs["lastdbd"]["version"], pid)
    require(session(home) == identity, "The baseline session changed during its health check")
    ceiling = memory_limit(plist)
    current["memory_bytes"] = memory(pid, ceiling)
    require(not (home / ".shutdown_flush_ready").exists(), "A stale shutdown receipt exists")
    return {"stable": stable(home), "plist_sha256": sha(plist_path), "pair": programs,
            "memory_limit_mb": ceiling,
            "session": identity, "health": current,
            "process_start": run(["/bin/ps", "-p", str(pid), "-o", "lstart="]).stdout.strip()}


def check_old_session_health(home, baseline):
    identity = baseline["session"]
    require(session(home) == identity, "The old primary session changed")
    value = baseline_health(home / "data/folddb.sock", baseline["pair"]["lastdbd"]["version"], identity)
    current, original = value["maintenance_history"], baseline["health"]["maintenance_history"]
    require(isinstance(original, dict) and set(original) == set(current)
            and all(type(original.get(name)) is int and original[name] >= 0
                    for name in ("maintenance_failures", "reclaim_failures", "maintenance_runs")),
            "The saved baseline maintenance history is invalid")
    require(all(current[name] == original[name]
                for name in ("session", "maintenance_failures", "reclaim_failures")),
            "The baseline maintenance failure counters or session changed")
    require(current["maintenance_runs"] >= original["maintenance_runs"],
            "The baseline maintenance publication count decreased")
    require(session(home) == identity, "The old primary session changed during its health check")
    return value


def freshness(candidate, baseline, source):
    result = run([sys.executable, Path(__file__).with_name("lastdb-candidate-freshness.py"),
                  "--candidate", candidate["lastdbd"]["path"],
                  "--candidate-version", candidate["lastdbd"]["version"],
                  "--candidate-source-oid", source,
                  "--current-bin", baseline["lastdbd"]["path"]])
    value = json.loads(result.stdout)
    require(value.get("ok") is True and value.get("relation") in ("forward", "current"),
            "Candidate source ancestry is unproved")
    return value


def state_path(ctx):
    root = private_dir(Path.home() / ".local/state/last-stack/lastdb-safe-upgrade/native")
    key = hashlib.sha256((ctx["candidate_artifact_digest"] + ctx["native_approval_sha256"]
                          + str(ctx["native_reopen"])).encode()).hexdigest()
    return private_dir(root / key) / "state.json"


def read_state(path, ctx):
    state = load(path)
    require(state.get("schema") == "lastdb.native-upgrade.v1"
            and state.get("binding") == {key: ctx[key] for key in IMMUTABLE}, "Upgrade state binding differs")
    return state


def record(path, state, phase, **extra):
    state.update(extra, phase=phase, updated_at=int(time.time()))
    save(path, state)


def assert_preserved(approval, state):
    home, plist_path, _, _, _ = service(approval)
    require(stable(home) == state["baseline"]["stable"], "Primary identity, data home, or cloud config changed")
    require(sha(plist_path) == state["baseline"]["plist_sha256"], "Primary LaunchAgent config changed")


def prepare_pair(candidate, program, path, state):
    backup = private_dir(path.parent / "programs-before")
    stage = private_dir(program.parent / (".native-upgrade-" + path.parent.name[:16]))
    for name in ("lastdbd", "lastdb"):
        old = program.parent / name
        saved = backup / name
        staged = stage / name
        expected = state["baseline"]["pair"][name]["sha256"]
        if not saved.exists():
            require(sha(old) == expected, "Old program changed before the recovery pair was saved")
            shutil.copy2(old, saved)
        regular(saved)
        require(sha(saved) == expected, "Saved recovery program differs")
        if not staged.exists():
            shutil.copy2(candidate[name]["path"], staged)
        regular(staged)
        require(sha(staged) == candidate[name]["sha256"], "Staged candidate differs")
        for file in (saved, staged):
            with file.open("rb") as stream:
                os.fsync(stream.fileno())
    sync_dir(backup)
    sync_dir(stage)
    sync_dir(program.parent)
    require(pair(stage) == {k: {**v, "path": str(stage / k)} for k, v in candidate.items()},
            "The staged pair differs")
    save(path.parent / "program-recovery.json", {"baseline": state["baseline"]["pair"],
         "saved_directory": str(backup), "data_copy": False})
    return stage


def strict_stop(approval, state, path):
    return _strict_stop(approval, state, path)


def baseline_strict_stop(approval, state, path):
    require(approval.get("mode") == MODE, "Baseline history is only for native in-place upgrades")
    return _strict_stop(approval, state, path, baseline_history=True)


def _strict_stop(approval, state, path, *, baseline_history=False):
    home, _, _, program, target = service(approval)
    identity = state["baseline"]["session"]
    require(job_pid(target) == identity["pid"] and session(home) == identity,
            "Primary session changed before the strict stop")
    require(run(["/bin/ps", "-p", str(identity["pid"]), "-o", "lstart="]).stdout.strip()
            == state["baseline"]["process_start"], "Primary PID identity changed")
    require(not (home / ".shutdown_flush_ready").exists(), "A stale shutdown receipt exists before stop")
    if baseline_history:
        check_old_session_health(home, state["baseline"])
    else:
        health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], identity["pid"])
    record(path, state, "stop-requested", effect_started_at=int(time.time()))
    output = helper("launchd-job-checks.sh", "lastdb_launchd_graceful_prestop",
                    "/bin/launchctl", target, program, "300", "150", "1", timeout=510).stdout
    require("LASTDB_LAUNCHD_PRESTOP=ok " in output and "forced_kill=0" in output,
            "The strict supervised stop did not succeed")
    proof = stopped(home, identity)
    require(run(["/bin/launchctl", "print", target], check=False).returncode != 0,
            "The old LaunchAgent remains loaded")
    for sock in (home / "data/folddb.sock", home / "data/folddb-full.sock"):
        result = run(["/usr/sbin/lsof", "-nP", "-t", str(sock)], check=False)
        require(not result.stdout.strip(), "The stopped socket still has an owner")
    record(path, state, "stopped", stop_proof=proof)


def bootstrap(approval):
    _, plist_path, _, _, target = service(approval)
    # Never call the generic reload helper: a live bootout could force a stop.
    require(job_pid(target) is None, "Refuse bootstrap while a supervised process exists")
    domain = target.rsplit("/", 1)[0]
    for delay in (0, 2, 5, 15, 30):
        if delay:
            time.sleep(delay)
        run(["/bin/launchctl", "bootstrap", domain, plist_path], check=False)
        if job_pid(target) is not None:
            return
    raise RuntimeError("The primary LaunchAgent did not start; retain the recovery state")


def live_gate(approval, state, candidate, verify_pair=True):
    assert_preserved(approval, state)
    home, _, plist, program, target = service(approval)
    if verify_pair:
        require(pair(program.parent) == candidate_at(candidate, program.parent), "Installed candidate pair differs")
    pid = job_pid(target)
    require(pid is not None and pid != state["baseline"]["session"]["pid"], "The supervised candidate is absent")
    identity = session(home)
    require(identity["pid"] == pid, "Candidate session differs from launchd")
    check_environment(pid, plist)
    value = health(home / "data/folddb.sock", candidate["lastdbd"]["version"], pid)
    return {"session": identity, "health": value,
            "memory_bytes": memory(pid, state["baseline"]["memory_limit_mb"])}


def candidate_at(candidate, directory):
    return {name: {**value, "path": str(directory / name)} for name, value in candidate.items()}


def recover(ctx, approval, candidate, path, state):
    """Restore the saved program pair only, with a proved clean stopped home."""
    if not state.get("effect_started_at") or state["phase"] in ("rolled-back", "old-retained"):
        return
    approval_fresh(approval, state["effect_started_at"])
    assert_preserved(approval, state)
    require(state["probe"].get("passed") is True
            and bool(state["probe"].get("baseline_reopen_read")),
            "Recovery requires the exact generated backward-compatibility proof")
    home, _, plist, program, target = service(approval)
    old = state["baseline"]["session"]
    hold = Path(str(program) + ".prestop-hold")
    if alive(old["pid"]):
        require(job_pid(target) == old["pid"] and session(home) == old,
                "The old primary PID identity changed during recovery")
        if hold.exists():
            require(not program.exists() and sha(hold) == state["baseline"]["pair"]["lastdbd"]["sha256"],
                    "The held old program differs")
            os.replace(hold, program)
            sync_dir(program.parent)
        require(pair(program.parent) == state["baseline"]["pair"], "The still-active old pair differs")
        # Do not send a second stop to an old process that still drains. Its
        # health can fail here; the recovery record then stays incomplete.
        check_old_session_health(home, state["baseline"])
        record(path, state, "old-retained", recovery={"old_pid_untouched": old["pid"]})
        return

    pid = job_pid(target)
    if state["phase"] == "recovery-start-requested" and pid is not None:
        require(pair(program.parent) == state["baseline"]["pair"] and session(home)["pid"] == pid,
                "The resumed recovered process differs")
        result = health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], pid)
        check_environment(pid, plist)
        memory(pid, state["baseline"]["memory_limit_mb"])
        record(path, state, "rolled-back", recovery={"health": result, "session": session(home),
                                                    "data_copy": False, "cloud_off": True})
        return
    if pid is not None:
        require(pid != old["pid"] and session(home)["pid"] == pid,
                "Recovery found an unbound supervised session")
        require(not state.get("live") or session(home) == state["live"]["session"],
                "Recovery refuses an unexpected replacement session")
        require(program.exists() and sha(program) == candidate["lastdbd"]["sha256"],
                "Recovery refuses to stop an unknown program")
        identity = session(home)
        record(path, state, "recovery-stop-requested", recovery_session=identity)
        output = helper("launchd-job-checks.sh", "lastdb_launchd_graceful_prestop",
                        "/bin/launchctl", target, program, "300", "150", "1", timeout=510).stdout
        require("LASTDB_LAUNCHD_PRESTOP=ok " in output and "forced_kill=0" in output,
                "Recovery cannot prove a strict candidate stop")
        proof = stopped(home, identity)
        unloaded(target)
        record(path, state, "recovery-stopped", recovery_stop_proof=proof)
    else:
        identity = state.get("recovery_session") or session(home)
        # A failed boot without a clean flush is not permission to downgrade
        # native data. Retain the exact pair and state for repair in that case.
        proof = stopped(home, identity)
        if hold.exists():
            require(not program.exists() and sha(hold) in
                    (candidate["lastdbd"]["sha256"], state["baseline"]["pair"]["lastdbd"]["sha256"]),
                    "The interrupted recovery program hold differs")
            require(job_pid(target) is None, "A process appeared during recovery")
            run(["/bin/launchctl", "bootout", target], check=False)
            unloaded(target)
            os.replace(hold, program)
            sync_dir(program.parent)
        unloaded(target)
        record(path, state, "recovery-stopped", recovery_stop_proof=proof)

    backup = path.parent / "programs-before"
    restore_stage = private_dir(program.parent / (".native-recovery-" + path.parent.name[:16]))
    for name in ("lastdbd", "lastdb"):
        saved, staged = backup / name, restore_stage / name
        regular(saved)
        require(sha(saved) == state["baseline"]["pair"][name]["sha256"], "Saved recovery pair hash differs")
        require(not staged.exists() or sha(staged) == sha(saved), "Recovery staging path has other bytes")
        if not staged.exists():
            shutil.copy2(saved, staged)
        with staged.open("rb") as stream:
            os.fsync(stream.fileno())
    sync_dir(restore_stage)
    sync_dir(program.parent)
    require(pair(restore_stage) == candidate_at(state["baseline"]["pair"], restore_stage),
            "The staged recovery pair differs")
    record(path, state, "recovery-install-requested")
    for name in ("lastdbd", "lastdb"):
        unloaded(target)
        target_file = program.parent / name
        require(sha(target_file) in (candidate[name]["sha256"], state["baseline"]["pair"][name]["sha256"]),
                "An installed recovery target has unknown bytes")
        os.replace(restore_stage / name, target_file)
        sync_dir(program.parent)
    require(pair(program.parent) == state["baseline"]["pair"], "Restored program pair differs")
    save(home / "restart-intent.json", {"cause": "upgrade", "previous_pid": identity["pid"],
                                       "created_at": int(time.time())})
    record(path, state, "recovery-start-requested")
    bootstrap(approval)
    result = wait_health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], job_pid(target))
    assert_preserved(approval, state)
    check_environment(job_pid(target), plist)
    memory(job_pid(target), state["baseline"]["memory_limit_mb"])
    record(path, state, "rolled-back", recovery={"health": result, "session": session(home),
                                                "data_copy": False, "cloud_off": True})


def cutover(ctx, approval, candidate, path, state):
    require(ctx["native_probe_only"] is False, "A probe-only execution cannot cut over")
    require(state["probe"]["passed"] is True, "The synthetic operational check did not pass")
    require(state["probe"]["candidate"] == candidate
            and state["probe"]["baseline"] == state["baseline"]["pair"], "Probe binding differs")
    home, _, _, program, target = service(approval)
    if not state.get("effect_started_at"):
        approval_fresh(approval)
        require(0 <= int(time.time()) - state["probe"]["completed_at"] <= 3600,
                "The exact-candidate operational check is older than one hour")
        current = baseline_snapshot(approval, state["baseline"])
        require(all(current[key] == state["baseline"][key] for key in
                    ("stable", "plist_sha256", "pair", "session", "process_start")),
                "The primary changed after the synthetic check")
        freshness(candidate, current["pair"], ctx["source_git_oid"])
        stage = prepare_pair(candidate, program, path, state)
        record(path, state, "prepared", stage_directory=str(stage))
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"native-inplace-cloud-off"}', flush=True)
        baseline_strict_stop(approval, state, path)
    else:
        # A retry can resume this exact transaction. It cannot invent a stop
        # receipt, choose another pair, or act on another primary session.
        approval_fresh(approval, state["effect_started_at"])
        assert_preserved(approval, state)
        if state["phase"] == "stop-requested":
            require(not alive(state["baseline"]["session"]["pid"]),
                    "The prior strict stop is incomplete; no force is permitted")
            proof = stopped(home, state["baseline"]["session"])
            hold = Path(str(program) + ".prestop-hold")
            if hold.exists():
                require(not program.exists() and sha(hold) == state["baseline"]["pair"]["lastdbd"]["sha256"],
                        "The interrupted program hold differs")
                require(job_pid(target) is None, "A process appeared during stop recovery")
                run(["/bin/launchctl", "bootout", target], check=False)
                unloaded(target)
                os.replace(hold, program)
                sync_dir(program.parent)
            unloaded(target)
            record(path, state, "stopped", stop_proof=proof)

    if state["phase"] in ("stopped", "install-requested"):
        stopped(home, state["baseline"]["session"])
        unloaded(target)
        stage = Path(state["stage_directory"])
        record(path, state, "install-requested")
        for name in ("lastdbd", "lastdb"):
            target_file = program.parent / name
            if sha(target_file) != candidate[name]["sha256"]:
                require(sha(target_file) == state["baseline"]["pair"][name]["sha256"],
                        "An installed program has an unknown hash")
                regular(stage / name)
                require(sha(stage / name) == candidate[name]["sha256"], "The staged program hash changed")
                unloaded(target)
                os.replace(stage / name, target_file)
                sync_dir(program.parent)
        require(pair(program.parent) == candidate_at(candidate, program.parent), "Installed pair verification failed")
        record(path, state, "installed")

    if state["phase"] == "installed":
        # This small marker is part of the supported daemon session protocol.
        save(home / "restart-intent.json", {"cause": "upgrade",
            "previous_pid": state["baseline"]["session"]["pid"], "created_at": int(time.time())})
        record(path, state, "start-requested")
    if state["phase"] == "start-requested":
        if job_pid(target) is None:
            bootstrap(approval)
        wait_health(home / "data/folddb.sock", candidate["lastdbd"]["version"], job_pid(target))
        record(path, state, "active", live=live_gate(approval, state, candidate))
    require(state["phase"] in ("active", "soak", "complete"), "Unsupported native recovery phase")
    live = live_gate(approval, state, candidate)
    record(path, state, "soak", live=live, soak_started_at=int(time.time()))
    # The full five-minute minimum remains. No latency benchmark runs here.
    deadline = time.monotonic() + 300
    while True:
        observed = live_gate(approval, state, candidate, verify_pair=False)
        require(observed["session"] == live["session"], "The candidate restarted during the soak")
        if time.monotonic() >= deadline:
            break
        time.sleep(min(15, max(0, deadline - time.monotonic())))
    observed = live_gate(approval, state, candidate)
    record(path, state, "complete", live=observed, completed_at=int(time.time()))
    print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"native-inplace-cloud-off"}', flush=True)
    emit({"cutover": "native-inplace-cloud-off", "native_state": str(path), "verdict": "green"})


def check(ctx):
    candidate, approval = binding(ctx)
    state = read_state(state_path(ctx), ctx)
    require(state["phase"] == "complete", "The native cutover is not complete")
    live = live_gate(approval, state, candidate)
    require(live["session"] == state["live"]["session"], "The accepted candidate session changed")
    return state


def step_main(step):
    ctx = context()
    require(os.environ.get("LOOM_LIVE") == "1" and bool(os.environ.get("LOOM_EXEC_ID")),
            "Native upgrade requires the live Loom local-recovery graph")
    candidate, approval = binding(ctx)
    with Owner(ctx["candidate"]):
        path = state_path(ctx)
        if step == "PROBE":
            if path.exists():
                state = read_state(path, ctx)
                if state.get("effect_started_at"):
                    require(ctx["native_probe_only"] is False,
                            "A probe-only run cannot resume a live transaction")
                    emit({"verdict": "green", "native_state": str(path)})
                    return
                require(state["phase"] == "probed", "A failed probe needs a new approval and generated home")
                approval_fresh(approval)
                emit({"verdict": "probed" if ctx["native_probe_only"] else "green", "native_state": str(path)})
                return
            approval_fresh(approval)
            baseline = baseline_snapshot(approval)
            relation = freshness(candidate, baseline["pair"], ctx["source_git_oid"])
            require(relation["relation"] == ("current" if ctx["native_reopen"] else "forward"),
                    "Native source relation differs from upgrade or reopen mode")
            if ctx["native_reopen"]:
                require(baseline["pair"] == candidate_at(candidate, Path(baseline["pair"]["lastdbd"]["path"]).parent),
                        "A native reopen requires the exact installed candidate pair")
            state = {"schema": "lastdb.native-upgrade.v1", "binding": {k: ctx[k] for k in IMMUTABLE},
                     "baseline": baseline, "execution": os.environ["LOOM_EXEC_ID"]}
            record(path, state, "probe-requested")
            for name in ("lastdbd", "lastdb"):
                require("-dirty" not in candidate[name]["version"]
                        and "/target/debug/" not in candidate[name]["path"]
                        and Path(candidate[name]["path"]).stat().st_size <=
                        Path(baseline["pair"][name]["path"]).stat().st_size * 1.5,
                        "Candidate release-class bar failed")
            _, plist_path, _, _, _ = service(approval)
            # Reuse the existing live tuning selector; omit unsafe home,
            # account, endpoint, and cloud controls from the generated node.
            tuning = {}
            for line in helper("live-lastdb-env.sh", "live_lastdb_env_pairs", plist_path).stdout.splitlines():
                name, value = line.split("=", 1)
                if not re.search(r"HOME|PATH|DIR|CLOUD|KEY|TOKEN|SECRET|URL|ENDPOINT|ISOLATED|BOOTSTRAP", name):
                    tuning[name] = value
            result = probe(baseline["pair"], candidate, path.parent / "generated-proof",
                           baseline["memory_limit_mb"], tuning)
            record(path, state, "probed", probe=result)
            emit({"verdict": "probed" if ctx["native_probe_only"] else "green", "native_state": str(path)})
        elif step == "CUTOVER":
            state = read_state(path, ctx)
            try:
                cutover(ctx, approval, candidate, path, state)
            except Exception:
                recover(ctx, approval, candidate, path, state)
                raise
        elif step == "RECOVER":
            print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"native-program-recovery"}', flush=True)
            if path.exists():
                recover(ctx, approval, candidate, path, read_state(path, ctx))
            print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"native-program-recovery"}', flush=True)
            emit({"verdict": "red", "native_state": str(path)})
        elif step == "RECOVERY_CHECK":
            state = read_state(path, ctx)
            require(state["phase"] in ("rolled-back", "old-retained"), "Recovery is incomplete")
            home, _, plist, program, target = service(approval)
            assert_preserved(approval, state)
            require(pair(program.parent) == state["baseline"]["pair"], "The recovered pair differs")
            identity = state.get("recovery", {}).get("session") or state["baseline"]["session"]
            require(session(home) == identity and job_pid(target) == identity["pid"], "Recovery session differs")
            if state["phase"] == "old-retained":
                require(identity == state["baseline"]["session"], "The retained old session differs")
                check_old_session_health(home, state["baseline"])
            else:
                health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], identity["pid"])
            check_environment(identity["pid"], plist)
        elif step == "VERIFY":
            state = check(ctx)
            emit({"verdict": "green", "native_state": str(path), "primary_session": state["live"]["session"]})
        elif step == "CHECK":
            check(ctx)
        else:
            raise RuntimeError("Unknown native upgrade step")


def approve(args):
    require(re.fullmatch(r"[0-9a-f]{40}", args.source) is not None, "Use a full source OID")
    candidate = pair(Path(args.candidate).expanduser().resolve().parent)
    require(args.source.startswith(re.search(r"-g([0-9a-f]+)", candidate["lastdbd"]["version"])[1]),
            "Candidate source version differs")
    output = Path(args.output).expanduser()
    require(not output.exists(), "Approval output already exists")
    approval = {"schema": "lastdb.native-upgrade-approval.v1", "approved_by": "Tom",
                "quote": args.quote, "approved_at": int(time.time()), "mode": MODE,
                "cloud_off": True, "primary_data_copy": False, "source_git_oid": args.source,
                "candidate": candidate, "ci_run": args.ci_run,
                "primary_home": str(Path.home() / ".lastdb"),
                "launchd_plist": str(Path(args.plist).expanduser()),
                "recovery": "Saved program pair and existing native files; no new cloud recovery point"}
    service(approval)
    save(output, approval)
    print("Candidate-bound approval recorded: " + str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=("PROBE", "CUTOVER", "VERIFY", "CHECK", "RECOVER", "RECOVERY_CHECK", "approve"))
    parser.add_argument("--candidate")
    parser.add_argument("--source")
    parser.add_argument("--quote")
    parser.add_argument("--plist")
    parser.add_argument("--ci-run")
    parser.add_argument("--output")
    args = parser.parse_args()
    if args.step == "approve":
        require(all(getattr(args, k) for k in ("candidate", "source", "quote", "plist", "ci_run", "output")),
                "Approval needs the candidate, source, quote, plist, CI run, and output")
        approve(args)
    else:
        # Graceful cancellation preserves the durable transaction phase. A
        # later exact-pair retry reconciles that phase; it never forces a stop.
        def cancelled(signum, unused):
            raise RuntimeError("Native upgrade interrupted; retain the local recovery state")
        signal.signal(signal.SIGTERM, cancelled)
        signal.signal(signal.SIGINT, cancelled)
        step_main(args.step)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        # No subprocess output, primary fields, or config values enter stdout.
        print("Native safe upgrade refused: " + str(error), file=sys.stderr)
        sys.exit(1)
