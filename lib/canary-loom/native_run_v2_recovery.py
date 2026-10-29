"""Exact accepted RunV2 cut before stop and full stopped-file verification."""
import hashlib
import json
import os
from pathlib import Path
import re
import time
import stat
import uuid

from native_upgrade_common import call, require, session
from native_run_v2_inputs import reference
from native_run_v2_state import NODE, Metadata, current_hash, stable

FILE = re.compile(r"disk-(run|cas)/(?:CURRENT|laststore-run-home-v2|runs/[0-9a-f-]{36}\.ldrun)")


def local(path, maximum=262144):
    metadata = Metadata()
    try:
        parent = metadata.directory(path.parent)
        _, raw = metadata.file(parent, path.name, maximum, private=True)
        return json.loads(raw)
    finally:
        metadata.close()


def wrapped(path):
    value = local(path)
    require(set(value) == {"sha256", "value"}, "The recovery checkpoint envelope differs")
    raw = json.dumps(value["value"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(hashlib.sha256(raw).hexdigest() == value["sha256"], "The recovery checkpoint digest differs")
    return value["value"]


def selected(approval):
    home = Path(approval["primary_home"])
    recovery = approval["recovery"]
    accepted = recovery["accepted_backup"]
    request = accepted["begin"]["job"]["commit_id"]
    require(str(uuid.UUID(request)) == request, "The recovery request UUID differs")
    job = local(home / "data/cloud-byte-backup-v2/jobs" / request / "state.json")
    terminal = local(home / "data/cloud-byte-backup-v2/jobs" / request / "terminal.json")
    core = wrapped(home / "data/disk-run/cloud-byte-source-v2/job.json")
    require(job.get("phase") == "published" and job.get("accepted") == accepted
            and job.get("retained_source_bytes") == 0 and job.get("blocked_reason") is None
            and core.get("released") is True and core.get("ready") is True
            and core.get("terminal") == terminal
            and terminal.get("status") == {"state": "published", "backup": accepted}
            and core.get("begin") == accepted["begin"] and core.get("run", {}).get("version") == 2,
            "The exact recovery snapshot is not accepted and source-released")
    require(accepted["begin"].get("descriptor") is None
            and accepted["begin"].get("required_destinations") == ["r2", "b2"]
            and accepted["begin"]["job"]["stream"]["scope"]["account_id"] == recovery["account_id"],
            "The opaque recovery account or provider set differs")
    return core


def selectors(home, profile, stopped=False):
    metadata = Metadata()
    try:
        data = metadata.directory(home / "data", private=False)
        if stopped:
            metadata.lock(data, "laststore-pack-node-v1", len(NODE), private=False)
        result = {}
        for name, label in (("disk-run", "main"), ("disk-cas", "cas")):
            directory = metadata.directory(home / "data" / name, data, name, private=False)
            if stopped:
                metadata.lock(directory, "LOCK", 0)
            actual = current_hash(directory)
            require(actual["sha256"] == profile[label]["current_sha256"],
                    "The current native cut exceeds the accepted recovery snapshot")
            result[name] = actual
        return metadata, result
    except BaseException:
        metadata.close()
        raise


def before_stop(approval, state):
    home = Path(approval["primary_home"])
    require(session(home) == state["baseline"]["session"], "The recovery primary session changed")
    core = selected(approval)
    for name,label in (("disk-run","main"),("disk-cas","cas")):
        require(core["run"][label]["home_id"] == state["baseline"]["stable"]["run_homes"][name]["descriptor"]["home_id"],
                "The accepted recovery snapshot belongs to another native home")
    status = call(home / "data/folddb.sock", "/api/sync/byte-backup-v2", {"action": "status"})
    require(status.get("last_accepted_backup") == approval["recovery"]["accepted_backup"]
            and status.get("phase") == "published" and status.get("running") is False
            and status.get("retained_source_bytes") == 0 and status.get("blocked_reason") is None,
            "The current primary backup is incomplete or has a backlog")
    sample = call(home / "data/folddb.sock", "/api/status")["status"]
    require(type(sample.get("sampled_at")) is int and 0 <= time.time() - sample["sampled_at"] <= 300,
            "The live recovery status sample is stale")
    provider = reference(approval["recovery"]["provider_verification"])
    require(provider.get("accepted_backup") == approval["recovery"]["accepted_backup"]
            and provider.get("environment") == "prod" and provider.get("all_transfers_verified") is True
            and provider.get("routes_verified") is True and provider.get("native_bytes_unchanged") is True
            and provider.get("reservations") == 0,
            "The current snapshot lacks independent provider and account verification")
    manifest = recovery_manifest(approval, core)
    require(provider.get("native_manifest_sha256") == approval["recovery"]["native_manifest"]["sha256"],
            "The provider proof names another original native manifest")
    require(provider.get("native_files_verified") == [
        {"path": f["path"], "bytes": int(f["native_bytes"]), "sha256": f["native_sha256"]}
        for f in manifest["native_files"]], "The remote native bytes differ from the saved source manifest")
    metadata, roots = selectors(home, core["run"])
    try:
        require(session(home) == state["baseline"]["session"], "The exact recovery session changed")
        return {"accepted_backup": approval["recovery"]["accepted_backup"], "selectors": roots,
                "observed_at": int(time.time()), "profile": core["run"]}
    finally:
        metadata.close()


def native_hash(path, length):
    metadata = Metadata()
    try:
        parent = metadata.directory(path.parent, private=False)
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        try:
            before = os.fstat(fd)
            require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                    and not before.st_mode & (0o022 if path.name in ("laststore-pack-node-v1", "laststore-run-home-v2") else 0o077)
                    and before.st_size == length,
                    "The stopped snapshot file metadata differs")
            h, count = hashlib.sha256(), 0
            while block := os.read(fd, 1024 * 1024):
                h.update(block);count += len(block)
                require(count <= length, "The stopped native file grew")
            from native_run_v2_state import file_identity
            require(count == length and file_identity(before) == file_identity(os.fstat(fd))
                    == file_identity(path.lstat()), "The stopped native file changed")
            return h.hexdigest()
        finally:
            os.close(fd)
    finally:
        metadata.close()


def stopped_cut(approval, state):
    home = Path(approval["primary_home"])
    core = selected(approval)
    metadata, roots = selectors(home, core["run"], stopped=True)
    try:
        require(roots == state["recovery_point"]["selectors"]
                and stable(home) == state["baseline"]["stable"], "The stopped recovery identities differ")
        manifest = recovery_manifest(approval, core)
        files = {}
        for item in manifest["native_files"]:
            path = item["path"]
            require(path not in files and (path == "laststore-pack-node-v1" or FILE.fullmatch(path)),
                    "The accepted native file path is duplicated or invalid")
            length = int(item["native_bytes"])
            require(0 < length <= 2**40 and len(files) < 1000000
                    and native_hash(home / "data" / path, length) == item["native_sha256"],
                    "The stopped bytes differ from the accepted recovery snapshot")
            files[path] = length
        require(len(files) == core["native_files"] and sum(files.values()) == core["native_bytes"],
                "The accepted stopped native file set is incomplete")
        return {"native_files": len(files), "native_bytes": sum(files.values())}
    finally:
        metadata.close()


def recovery_manifest(approval, core):
    from native_run_v2_profiles import typed_recovery
    if typed_recovery(approval):
        from auto_recovery_manifest import check
        return check(approval, core)
    manifest = reference(approval["recovery"]["native_manifest"])
    require(manifest.get("begin") == core["begin"] and manifest.get("run_profile") == core["run"]
            and manifest.get("native_root") == core["native_root"]
            and manifest.get("full_held_native_hashes_verified") is True
            and manifest.get("before_terminal_cleanup") is True,
            "The retained original native manifest belongs to another accepted cut")
    files = manifest.get("native_files")
    require(isinstance(files, list) and 0 < len(files) <= 1000000
            and len(files) == core["native_files"]
            and sum(int(f["native_bytes"]) for f in files) == core["native_bytes"],
            "The retained original manifest does not cover the full accepted native cut")
    return manifest
