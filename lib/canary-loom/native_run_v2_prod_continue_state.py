"""Retain the actual before-state and probe exclusive ownership of one saved restore."""

from contextlib import contextmanager
import fcntl
import os
from pathlib import Path
import stat

from native_run_v2_auto_qualify_io import hash_file, read, reference, require
from native_run_v2_auto_qualify_restore import NODE, names
from native_run_v2_dev_session import original_gone
from native_run_v2_inputs import external

ABSENT = ("current-session.json", "sessions.jsonl", "boot-error.json", "restart-intent.json",
          ".shutdown_flush_ready", "data/folddb.sock", "data/folddb-full.sock")


def unbooted(home):
    require(all(not os.path.lexists(home / name) for name in ABSENT), "continued_restore_has_prior_boot_evidence")


@contextmanager
def owner_probe(session):
    files = [(session / "owner.lock", 0, True),
             (session / "home/data/laststore-pack-node-v1", len(NODE), False)]
    files += [(session / "home/data" / home / "LOCK", 0, True) for home in ("disk-run", "disk-cas")]
    opened = []
    try:
        for path, size, private in files:
            require(path.resolve() == path, "saved_restore_lock_path")
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            opened.append(descriptor)
            info = os.fstat(descriptor)
            require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1
                    and info.st_size == size and not info.st_mode & (0o077 if private else 0o022),
                    "saved_restore_lock_metadata")
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        yield
    finally:
        for descriptor in reversed(opened):
            os.close(descriptor)


def prior_children(original):
    folder = Path(original["output"]) / "operation/cli"
    entries = sorted(names(folder, 16384))
    require(entries, "original_restore_cli_evidence_absent")
    for name in entries:
        require(name.startswith("cli-") and name[4:].isdigit(), "original_restore_cli_entry")
        path = folder / name / "result.json"
        result = read(path, 16384)
        require(type(result.get("pid")) is int and result["pid"] > 0
                and type(result.get("returncode")) is int
                and original_gone(result["pid"], int(path.stat().st_mtime)), "original_restore_cli_still_owned")


def snapshot(original, session):
    """Only JSON control values and tiny native-control hashes enter this record."""
    session = external(session)
    destination = Path(original["homes"]) / "r"
    require(session.parent == destination.parent and names(session.parent, 64) == {session.name}
            and not os.path.lexists(destination) and not os.path.lexists(session / "result.json"),
            "continued_restore_must_be_incomplete_and_unpublished")
    unbooted(session / "home")
    prior_children(original)
    selected = read(session / "selection.json")
    require(selected.get("version") == 2 and selected.get("accepted") == original["before"]["accepted"]
            and selected.get("destination") == str(destination)
            and session.name == ".byte-cloud-restore-" + selected["session_id"], "original_saved_selection")
    plan = read(session / "chain/plan.json")
    cursor = read(session / "chain/cursor.json")
    links, remaining = plan["links"], cursor["remaining"]
    require(type(links) is int and 1 <= links <= 32768 and type(remaining) is int and 0 < remaining <= links
            and plan["version"] == cursor["version"] == 1
            and plan["base"] == original["base"]
            and plan["head"] == cursor["head"] == selected["accepted"]["commit_sha256"], "original_saved_chain")
    mandatory = {"plan.json", "cursor.json"} | {f"link-{n:08}.json" for n in range(links)}
    possible = mandatory | {f"routes-{n:08}.json" for n in range(links)}
    observed = names(session / "chain", 65538)
    require(mandatory <= observed <= possible
            and all(f"routes-{n:08}.json" in observed for n in range(remaining, links)), "original_chain_control_set")
    paths = [session / "selection.json"] + [session / "chain" / name for name in sorted(observed)]
    controls, total = [], 0
    for path in paths:
        value = read(path)
        total += path.stat().st_size
        require(total <= 32 * 1024 * 1024, "continued_control_metadata_bound")
        controls.append({"original": reference(path), "value": value})
    previous = original["base"] if remaining == links else read(session / f"chain/link-{remaining:08}.json")
    require(cursor["previous"] == previous, "original_completed_chain_predecessor")
    native = []
    for home in ("disk-run", "disk-cas"):
        for name in ("CURRENT", "laststore-run-home-v2"):
            path = session / "home/data" / home / name
            require(0 < path.stat().st_size <= 65536, "continued_native_control_bound")
            native.append({"path": str(path), "sha256": hash_file(path, 65536), "bytes": path.stat().st_size})
    return {"selection": selected, "controls": controls, "native_controls": native,
            "destination": str(destination), "session": str(session), "before_first_boot": True}


def admission(path, controls):
    value = read(path)
    cursor = next(item["value"] for item in controls["controls"] if item["original"]["path"].endswith("/cursor.json"))
    index = cursor["remaining"] - 1
    point = next(item["value"] for item in controls["controls"]
                 if item["original"]["path"].endswith(f"/link-{index:08}.json"))
    items = value.get("items")
    require(value.get("http_status") == 200 and value.get("ordinal") == point["ordinal"]
            and isinstance(items, list) and len(items) == 4
            and all(item.get("result") == "ok" for item in items), "actual_current_grant_admission")
    selectors = [item.get("selector") for item in items]
    require(selectors.count({"kind": "inventory_index", "sha256": point["inventory_root"]["sha256"]}) == 1
            and selectors.count({"kind": "receipt", "receipt_id": point["root_receipt_id"]}) == 1
            and all(item["object"].get("destination") == "r2" for item in items)
            and len({str(item) for item in selectors}) == 4, "actual_grant_admission_selection")
    return {"summary": reference(path), "ordinal": point["ordinal"], "http_status": 200,
            "ok_selectors": 4, "original_error_cause_known": False}


@contextmanager
def operator_owner(path):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        os.write(descriptor, (str(os.getpid()) + "\n").encode())
        os.fsync(descriptor)
        parent = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
        yield
    finally:
        os.close(descriptor)
