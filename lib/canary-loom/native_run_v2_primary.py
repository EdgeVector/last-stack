"""Primary-only Run V2 pair selection with the exact selected backup policy."""

import os
from pathlib import Path
import plistlib
import shutil
import time

from native_upgrade import (bootstrap, candidate_at, check_environment, job_pid,
                            memory_limit, service, unloaded)
from native_upgrade_common import (memory, pair, private_dir, regular, require,
                                   run, save, session, sha, stopped, sync_dir)
from native_v2_primary import bytes_save, record
from native_run_v2_health import health, wait_health
from native_run_v2_profiles import automatic, closed_route, final_stopped, modern_stopped
from native_run_v2_routes import markers, stopped_marker
from native_run_v2_state import bounded_file, stable, stopped_pair


def baseline_snapshot(approval, baseline=None):
    require(approval.get("mode") == "native-run-v2-ci", "Run V2 primary policy differs")
    home, plist_path, plist, program, target = service(approval)
    pid = job_pid(target)
    require(pid is not None, "The Run V2 primary LaunchAgent is not active")
    identity = session(home)
    require(identity["pid"] == pid and (baseline is None or identity == baseline["session"]),
            "The Run V2 primary session differs")
    check_environment(pid, plist)
    programs = pair(program.parent)
    checked = health(home / "data/folddb.sock", programs["lastdbd"]["version"], pid,
                     automatic=automatic(approval))
    if automatic(approval):
        from native_run_v2_auto_policy import observe
        checked["automatic_backup"] = observe(approval)
    elif modern_stopped(approval):
        from native_run_v2_auto_final_policy import observe_off
        checked["automatic_pause"] = observe_off(approval)
    require(session(home) == identity, "The Run V2 baseline session changed during its health check")
    ceiling = memory_limit(plist)
    checked["memory_bytes"] = memory(pid, ceiling)
    require(not (home / ".shutdown_flush_ready").exists(), "A stale shutdown receipt exists")
    from native_v2_read import observe
    return {"keyed_read": observe(approval), "stable": stable(home, (stopped_marker(approval),)),
            "plist_sha256": sha(plist_path), "pair": programs,
            "memory_limit_mb": ceiling, "session": identity, "health": checked,
            "process_start": run(["/bin/ps", "-p", str(pid), "-o", "lstart="]).stdout.strip()}


def initial(approval, candidate, path):
    baseline = baseline_snapshot(approval)
    require({k: v["sha256"] for k, v in baseline["pair"].items()} == approval["baseline_programs_sha256"],
            "The approved baseline program pair differs")
    home, plist_path, plist, _, _ = service(approval)
    route = closed_route(approval)
    if automatic(approval):
        from native_run_v2_auto_writer_policy import initial as writer_policy
        writer_policy(approval, baseline, plist)
    elif route is not None:
        from native_run_v2_route_writer import initial as writer_policy
        writer_policy(approval, baseline, plist)
    elif modern_stopped(approval):
        from native_run_v2_stopped_writer import initial as writer_policy
        writer_policy(approval, baseline, plist)
    require("Program" not in plist, "An explicit LaunchAgent Program needs a separately reviewed selection change")
    pointer = home / "current"
    require(pointer.is_symlink(), "The primary current path must be its existing program-pair pointer")
    target = home / "native-run-v2-programs" / approval["source_git_oid"]
    require(str(target) == approval["target_program_dir"] and target.resolve() == target,
            "Candidate program directory is not the exact primary-only target")
    if route is not None and route["kind"] == "activation":
        # The offline activation keeps the exact pair that the primary runs.
        require(pointer.resolve() == target and os.readlink(pointer) == str(target)
                and all(Path(value["path"]).parent == target for value in baseline["pair"].values()),
                "The activation must keep the exact selected primary-only pair")
    else:
        require(target != pointer.resolve() and target.parent != pointer.resolve(),
                "Candidate staging must not use the shared baseline directory")
    original = path.parent / "primary-original.plist"
    if not original.exists():
        bytes_save(original, bounded_file(plist_path))
    require(sha(original) == baseline["plist_sha256"], "Original primary configuration record differs")
    inodes = {name: Path(value["path"]).stat().st_ino for name, value in baseline["pair"].items()}
    aliases = {}
    for name in ("lastdb", "lastdbd"):
        alias = Path.home() / ".local/bin" / name
        require(alias.is_symlink(), "The stable program path is not a current-pair symlink")
        link = os.readlink(alias)
        resolved_link = Path(os.path.normpath(str(alias.parent / link))) if not Path(link).is_absolute() else Path(link)
        require(resolved_link == home / "current" / name, "A stable program bypasses the primary current pointer")
        aliases[name] = {"target": link, "inode": alias.lstat().st_ino}
    return {"baseline": baseline, "original_plist": str(original),
            "original_current_target": os.readlink(pointer), "original_program_inodes": inodes,
            "candidate_directory": str(target), "candidate": candidate, "stable_program_aliases": aliases}


def preserved(approval, state):
    home = Path(approval["primary_home"])
    observed = stable(home, markers(approval))
    if final_stopped(approval):
        from native_run_v2_final_links import normalize
        observed = normalize(approval, state, observed)
    expected = state["baseline"]["stable"]
    if closed_route(approval) is not None:
        from native_run_v2_activation import expected_stable
        expected = expected_stable(approval, state)
    require(observed == expected, "Primary identity, Run V2 metadata, or cloud controls changed")
    for name, value in state["baseline"]["pair"].items():
        original = Path(value["path"])
        regular(original)
        require(original.stat().st_ino == state["original_program_inodes"][name]
                and sha(original) == value["sha256"], "A shared baseline executable changed")
    original = Path(state["original_plist"])
    regular(original, private=True, maximum=1024 * 1024)
    require(sha(original) == state["baseline"]["plist_sha256"], "Saved primary configuration differs")
    pointer = home / "current"
    require(pointer.is_symlink() and os.readlink(pointer) in (
        state["original_current_target"], state["candidate_directory"]), "Primary pair pointer differs")
    plist_path = Path(approval["launchd_plist"])
    allowed = {state["baseline"]["plist_sha256"], state.get("candidate_plist_sha256")}
    require(sha(plist_path) in allowed, "Primary LaunchAgent configuration has an unrelated change")
    for name, expected in state["stable_program_aliases"].items():
        alias = Path.home() / ".local/bin" / name
        require(alias.is_symlink() and os.readlink(alias) == expected["target"]
                and alias.lstat().st_ino == expected["inode"], "A stable program alias changed")


def prepare(approval, state, path):
    preserved(approval, state)
    target = Path(state["candidate_directory"])
    private_dir(target)
    require(set(p.name for p in target.iterdir()) <= {"lastdb", "lastdbd"},
            "Candidate program directory contains unrelated files")
    saved = private_dir(path.parent / "programs-before")
    for name in ("lastdbd", "lastdb"):
        for directory, source, expected in (
            (saved, Path(state["baseline"]["pair"][name]["path"]), state["baseline"]["pair"][name]["sha256"]),
            (target, Path(state["candidate"][name]["path"]), state["candidate"][name]["sha256"]),
        ):
            destination = directory / name
            if not destination.exists():
                shutil.copy2(source, destination)
                destination.chmod(0o700)
            regular(destination, private=True)
            require(sha(destination) == expected, "Staged or saved program hash differs")
            with destination.open("rb") as stream:
                os.fsync(stream.fileno())
            sync_dir(directory)
    require(pair(target) == candidate_at(state["candidate"], target), "Staged candidate pair differs")
    config = plistlib.loads(bounded_file(Path(state["original_plist"]), private=True))
    config["ProgramArguments"][0] = str(target / "lastdbd")
    rendered = plistlib.dumps(config, fmt=plistlib.FMT_XML, sort_keys=False)
    staged_plist = path.parent / "primary-candidate.plist"
    bytes_save(staged_plist, rendered)
    record(path, state, "prepared", candidate_plist=str(staged_plist), candidate_plist_sha256=sha(staged_plist))


def select(approval, state, path, candidate=True):
    preserved(approval, state)
    target = "gui/" + str(os.getuid()) + "/" + plistlib.loads(
        bounded_file(Path(state["original_plist"]), private=True))["Label"]
    unloaded(target)
    home = Path(approval["primary_home"])
    selected = Path(state["candidate_directory"]) if candidate else Path(state["baseline"]["pair"]["lastdbd"]["path"]).parent
    expected = state["candidate"] if candidate else state["baseline"]["pair"]
    require(pair(selected) == candidate_at(expected, selected), "Selected exact program pair differs")
    record(path, state, "install-requested" if candidate else "rollback-install-requested")
    source = Path(state["candidate_plist"] if candidate else state["original_plist"])
    require(sha(source) == (state["candidate_plist_sha256"] if candidate else state["baseline"]["plist_sha256"]),
            "Selected primary configuration differs")
    bytes_save(Path(approval["launchd_plist"]), bounded_file(source, private=True))
    pointer = home / "current"
    stage = home / (".native-run-v2-current-" + path.parent.name + ("-candidate" if candidate else "-baseline"))
    link = str(selected) if candidate else state["original_current_target"]
    if stage.exists() or stage.is_symlink():
        require(stage.is_symlink() and os.readlink(stage) == link, "Pending primary pointer differs")
    else:
        os.symlink(link, stage)
    os.replace(stage, pointer)
    sync_dir(home)
    preserved(approval, state)
    record(path, state, "selected" if candidate else "rollback-selected")


def selected_session(approval, state, candidate=True):
    preserved(approval, state)
    home, _, plist, program, target = service(approval)
    wanted = state["candidate"] if candidate else state["baseline"]["pair"]
    require(pair(program.parent) == candidate_at(wanted, program.parent), "Live program pair differs")
    require(all((Path.home() / ".local/bin" / name).resolve() == program.parent / name
                for name in ("lastdb", "lastdbd")), "The stable CLI and daemon do not select the installed pair")
    require(sha(approval["launchd_plist"]) == (state["candidate_plist_sha256"] if candidate else
                                             state["baseline"]["plist_sha256"]), "Live primary configuration differs")
    pid = job_pid(target)
    require(pid is not None, "The selected primary is not supervised")
    identity = session(home)
    require(identity["pid"] == pid, "The primary socket session and supervisor differ")
    check_environment(pid, plist)
    require(job_pid(target) == pid and session(home) == identity,
            "The selected Run V2 session changed during its identity check")
    return identity


def live(approval, state, candidate=True):
    identity = selected_session(approval, state, candidate)
    home = Path(approval["primary_home"])
    wanted = state["candidate"] if candidate else state["baseline"]["pair"]
    checked = health(home / "data/folddb.sock", wanted["lastdbd"]["version"], identity["pid"],
                     automatic=automatic(approval))
    if automatic(approval):
        from native_run_v2_auto_policy import observe
        checked["automatic_backup"] = observe(approval)
    elif modern_stopped(approval):
        from native_run_v2_auto_final_policy import observe_off
        checked["automatic_pause"] = observe_off(approval, admission=not state.get("effect_started_at"))
    from native_v2_read import verify
    checked["keyed_read"] = verify(approval, state["baseline"]["keyed_read"])
    require(session(home) == identity, "The selected Run V2 session changed during its health check")
    return {"session": identity, "health": checked,
            "memory_bytes": memory(identity["pid"], state["baseline"]["memory_limit_mb"])}


def checked_startup(home, target, binding):
    identity = binding["session"]
    require(job_pid(target) == identity["pid"] and session(home) == identity
            and run(["/bin/ps", "-p", str(identity["pid"]), "-o", "lstart="]).stdout.strip()
            == binding["process_start"], "The exact selected startup process changed")


def bind_startup(approval, state, path, candidate):
    home, _, _, program, target = service(approval)
    kind = "candidate" if candidate else "baseline"
    directory = (Path(state["candidate_directory"]) if candidate
                 else Path(state["baseline"]["pair"]["lastdbd"]["path"]).parent)
    wanted = state["candidate"] if candidate else state["baseline"]["pair"]
    require(program.parent == directory and pair(directory) == candidate_at(wanted, directory),
            "The selected startup target differs from the exact pair")
    bindings = state.get("startup_bindings", {})
    intents = state.get("startup_intents", {})
    require(isinstance(bindings, dict) and set(bindings) <= {"candidate", "baseline"}
            and isinstance(intents, dict) and set(intents) <= {"candidate", "baseline"},
            "The saved startup target binding differs")
    identity = state.get("last_stopped_session", state["baseline"]["session"])
    intent = {"directory": str(directory), "previous_session": identity}
    if kind in bindings:
        binding = bindings[kind]
        require(set(binding) == {"directory", "session", "process_start"}
                and binding["directory"] == str(directory) and intents.get(kind) == intent,
                "The saved startup directory or intent differs")
        checked_startup(home, target, binding)
        return binding
    require(kind not in intents, "An unknown startup outcome requires review; do not repeat bootstrap")
    unloaded(target)
    require(job_pid(target) is None, "A fresh startup cannot adopt an existing process")
    record(path, state, "start-requested" if candidate else "rollback-start-requested",
           startup_intents={**intents, kind: intent})
    save(home / "restart-intent.json", {"cause": "upgrade", "previous_pid": identity["pid"],
                                       "created_at": int(time.time())})
    bootstrap(approval)
    pid = job_pid(target)
    deadline = time.monotonic() + 10
    observed = None
    while time.monotonic() < deadline:
        try:
            value = session(home)
            if value["pid"] == pid:
                observed = value
                break
        except FileNotFoundError:
            pass
        time.sleep(0.1)
    require(observed is not None and job_pid(target) == pid, "The selected startup session is not bound")
    process_start = run(["/bin/ps", "-p", str(pid), "-o", "lstart="]).stdout.strip()
    require(bool(process_start), "The selected startup process time is absent")
    binding = {"directory": str(directory), "session": observed, "process_start": process_start}
    checked_startup(home, target, binding)
    record(path, state, "start-requested" if candidate else "rollback-start-requested",
           startup_bindings={**bindings, kind: binding}, starting_session=observed,
           starting_process_start=process_start)
    return binding


def start(approval, state, path, candidate=True):
    record(path, state, "start-requested" if candidate else "rollback-start-requested")
    binding = bind_startup(approval, state, path, candidate)
    home, _, _, _, target = service(approval)
    wanted = state["candidate"] if candidate else state["baseline"]["pair"]
    wait_health(home / "data/folddb.sock", wanted["lastdbd"]["version"], binding["session"]["pid"],
                automatic=automatic(approval))
    observed = live(approval, state, candidate)
    checked_startup(home, target, binding)
    require(observed["session"] == binding["session"], "The selected startup health belongs to another session")
    record(path, state, "active" if candidate else "rolled-back", live=observed)
    return observed


def stopped_boundary(approval, state):
    home, _, _, _, target = service(approval)
    identity = state.get("last_stopped_session", state["baseline"]["session"])
    unloaded(target)
    require(stopped(home, identity) == state["stop_proof"], "Run V2 exact clean stop proof differs")
    preserved(approval, state)
    require(not state.get("activation"), "The stopped boundary precedes the offline activation")
    result = stopped_pair(home, state["baseline"]["stable"], stopped_marker(approval), markers(approval))
    preserved(approval, state)
    unloaded(target)
    require(stopped(home, identity) == state["stop_proof"], "Run V2 stopped session changed")
    return result
