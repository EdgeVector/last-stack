"""Primary-only pair selection. Never replace a shared executable or another job."""

import os
from pathlib import Path
import plistlib
import shutil
import time

from native_upgrade import (baseline_snapshot, bootstrap, candidate_at, check_environment,
                            check_old_session_health, job_pid, service, stable, unloaded)
from native_upgrade_common import (health, memory, pair, private_dir, regular, require,
                                   run, save, session, sha, sync_dir, wait_health)
from native_v2_read import verify as verify_read


def bytes_save(path, data):
    stage = path.with_name(path.name + ".tmp." + str(os.getpid()))
    with os.fdopen(os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(stage, path)
    sync_dir(path.parent)


def record(path, state, phase, **values):
    state.update(values, phase=phase, updated_at=int(time.time()))
    save(path, state)


def initial(approval, candidate, path):
    baseline = baseline_snapshot(approval)
    require({k: v["sha256"] for k, v in baseline["pair"].items()} == approval["baseline_programs_sha256"],
            "The approved baseline program pair differs")
    home, plist_path, plist, _, _ = service(approval)
    require("Program" not in plist, "An explicit LaunchAgent Program needs a separately reviewed selection change")
    pointer = home / "current"
    require(pointer.is_symlink(), "The primary current path must be its existing program-pair pointer")
    target = home / "native-v2-programs" / approval["source_git_oid"]
    require(str(target) == approval["target_program_dir"] and target.resolve() == target,
            "Candidate program directory is not the exact primary-only target")
    require(target != pointer.resolve() and target.parent != pointer.resolve(),
            "Candidate staging must not use the shared baseline directory")
    original = path.parent / "primary-original.plist"
    if not original.exists():
        bytes_save(original, plist_path.read_bytes())
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
    require(stable(home) == state["baseline"]["stable"], "Primary identity, native home, or legacy cloud config changed")
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
    config = plistlib.loads(Path(state["original_plist"]).read_bytes())
    config["ProgramArguments"][0] = str(target / "lastdbd")
    rendered = plistlib.dumps(config, fmt=plistlib.FMT_XML, sort_keys=False)
    staged_plist = path.parent / "primary-candidate.plist"
    bytes_save(staged_plist, rendered)
    record(path, state, "prepared", candidate_plist=str(staged_plist), candidate_plist_sha256=sha(staged_plist))


def select(approval, state, path, candidate=True):
    preserved(approval, state)
    target = "gui/" + str(os.getuid()) + "/" + plistlib.loads(
        Path(state["original_plist"]).read_bytes())["Label"]
    unloaded(target)
    home = Path(approval["primary_home"])
    selected = Path(state["candidate_directory"]) if candidate else Path(state["baseline"]["pair"]["lastdbd"]["path"]).parent
    expected = state["candidate"] if candidate else state["baseline"]["pair"]
    require(pair(selected) == candidate_at(expected, selected), "Selected exact program pair differs")
    record(path, state, "install-requested" if candidate else "rollback-install-requested")
    source = Path(state["candidate_plist"] if candidate else state["original_plist"])
    require(sha(source) == (state["candidate_plist_sha256"] if candidate else state["baseline"]["plist_sha256"]),
            "Selected primary configuration differs")
    bytes_save(Path(approval["launchd_plist"]), source.read_bytes())
    pointer = home / "current"
    stage = home / (".native-v2-current-" + path.parent.name + ("-candidate" if candidate else "-baseline"))
    link = str(selected) if candidate else state["original_current_target"]
    if stage.exists() or stage.is_symlink():
        require(stage.is_symlink() and os.readlink(stage) == link, "Pending primary pointer differs")
    else:
        os.symlink(link, stage)
    os.replace(stage, pointer)
    sync_dir(home)
    preserved(approval, state)
    record(path, state, "selected" if candidate else "rollback-selected")


def live(approval, state, candidate=True):
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
    checked = (check_old_session_health(home, state["baseline"])
               if not candidate and identity == state["baseline"]["session"] else
               health(home / "data/folddb.sock", wanted["lastdbd"]["version"], pid))
    return {"session": identity, "health": checked,
            "memory_bytes": memory(pid, state["baseline"]["memory_limit_mb"])}


def start(approval, state, path, candidate=True):
    home, _, _, _, target = service(approval)
    identity = state.get("last_stopped_session", state["baseline"]["session"])
    record(path, state, "start-requested" if candidate else "rollback-start-requested")
    save(home / "restart-intent.json", {"cause": "upgrade", "previous_pid": identity["pid"],
                                       "created_at": int(time.time())})
    if job_pid(target) is None:
        bootstrap(approval)
    wanted = state["candidate"] if candidate else state["baseline"]["pair"]
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
    record(path, state, "start-requested" if candidate else "rollback-start-requested",
           starting_session=observed, starting_process_start=process_start)
    wait_health(home / "data/folddb.sock", wanted["lastdbd"]["version"], job_pid(target))
    observed = live(approval, state, candidate)
    observed["keyed_read"] = verify_read(approval, state["keyed_read"])
    record(path, state, "active" if candidate else "rolled-back", live=observed)
    return observed
