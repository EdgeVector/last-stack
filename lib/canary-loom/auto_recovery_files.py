"""Read only a completed fresh restore's native metadata and original file hashes."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat

from native_upgrade_common import require
from native_run_v2_inputs import external, parent_descriptor, uint, unique
from native_run_v2_recovery import native_hash
from native_run_v2_state import NODE, Metadata, descriptor, file_identity

MAXIMUM = 32 * 1024 * 1024
MAX_FILES = 1000000
ABSENT = ("current-session.json", "sessions.jsonl", "boot-error.json", ".shutdown_flush_ready",
          "data/folddb.sock", "data/folddb-full.sock")


def original(path, maximum=MAXIMUM):
    path = external(path)
    parent = parent_descriptor(path)
    descriptor = None
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_mode & 0o077 == 0 and before.st_nlink == 1
                and 0 < before.st_size <= maximum, "An original snapshot proof has unsafe ownership or size")
        chunks, count = [], 0
        while block := os.read(descriptor, min(65536, maximum + 1 - count)):
            chunks.append(block)
            count += len(block)
            require(count <= maximum, "An original snapshot proof exceeds its bound")
        require(count == before.st_size and file_identity(before) == file_identity(os.fstat(descriptor))
                == file_identity(os.stat(path.name, dir_fd=parent, follow_symlinks=False))
                and path.parent.resolve() == path.parent
                and os.fstat(parent).st_ino == path.parent.lstat().st_ino
                and os.fstat(parent).st_dev == path.parent.lstat().st_dev,
                "An original snapshot proof or its anchored directory changed")
        raw = b"".join(chunks)
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda unused: require(False, "Nonfinite snapshot metadata is forbidden"))
        require(isinstance(value, dict), "An original snapshot proof must be an object")
        return {"path": str(path), "sha256": hashlib.sha256(raw).hexdigest()}, value
    finally:
        if descriptor is not None:
            os.close(descriptor)
        os.close(parent)


def names(path):
    metadata = Metadata()
    try:
        fd = metadata.directory(path, private=True)
        result = set()
        with os.scandir(fd) as entries:
            for entry in entries:
                require(len(result) < MAX_FILES and entry.name not in result,
                        "The restored native directory exceeds its name bound")
                result.add(entry.name)
        return sorted(result)
    finally:
        metadata.close()


def destination(path):
    path = external(path)
    require(path.resolve() == path, "The fresh restored destination is not canonical")
    forbidden = (Path.home() / ".lastdb", Path.home() / ".primary-lastdb-archive-20261014")
    require(all(path != root and root not in path.parents and path not in root.parents for root in forbidden),
            "The snapshot proof overlaps the primary or its archive")
    metadata = Metadata()
    try:
        metadata.directory(path, private=True)
    finally:
        metadata.close()
    return path


def native_path(path):
    if path == "laststore-pack-node-v1":
        return
    controls = {name + "/" + control for name in ("disk-run", "disk-cas")
                for control in ("CURRENT", "laststore-run-home-v2")}
    run = re.fullmatch(r"disk-(run|cas)/runs/([0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12})\.ldrun", path)
    require(path in controls or run and run[2] != "00000000-0000-0000-0000-000000000000",
        "A restored snapshot native path is unsupported")


def files(session, restored):
    entries = session / "entries"
    result = []
    paths = set()
    for name in names(entries):
        require(re.fullmatch(r"[0-9a-f]{64}", name), "A snapshot native proof name differs")
        proof_ref, proof = original(entries / name, 4096)
        require(set(proof) == {"path", "sha256", "bytes"}, "A native file proof has another shape")
        path = proof["path"]
        require(isinstance(path, str), "A native snapshot path is absent")
        native_path(path)
        require(path not in paths and name == hashlib.sha256(path.encode()).hexdigest(),
                "The native snapshot proof repeats or misnames a file")
        size = uint(proof["bytes"], True)
        require(native_hash(restored / "data" / path, size) == proof["sha256"],
                "A full restored snapshot file differs from its original native proof")
        paths.add(path)
        result.append({"path": path, "native_sha256": proof["sha256"],
                       "native_bytes": size, "native_proof": proof_ref})
    require(bool(result), "The snapshot native file list is empty")
    return sorted(result, key=lambda item: item["path"])


def closure(restored, native):
    expected = {item["path"] for item in native}
    require(names(restored / "data") == ["disk-cas", "disk-run", "laststore-pack-node-v1"],
            "The restored data root is not an exact native snapshot")
    observed = {"data": names(restored / "data")}
    paths = {"laststore-pack-node-v1"}
    homes = {}
    for name in ("disk-run", "disk-cas"):
        folder = restored / "data" / name
        observed[name] = names(folder)
        require(observed[name] == ["CURRENT", "LOCK", "laststore-run-home-v2", "runs"],
                "A restored native home has an unexpected file")
        require(native_hash(folder / "LOCK", 0) == hashlib.sha256(b"").hexdigest(),
                "A restored native owner lock is not empty")
        observed[name + "/runs"] = names(folder / "runs")
        paths.update(name + "/" + control for control in ("CURRENT", "laststore-run-home-v2"))
        paths.update(name + "/runs/" + run for run in observed[name + "/runs"])
        metadata = Metadata()
        try:
            parent = metadata.directory(folder, private=True)
            homes[name] = descriptor(metadata, parent)["home_id"]
        finally:
            metadata.close()
    marker = next(item for item in native if item["path"] == "laststore-pack-node-v1")
    require(marker["native_bytes"] == len(NODE)
            and marker["native_sha256"] == hashlib.sha256(NODE).hexdigest()
            and paths == expected, "The restored typed-format4 file closure differs")
    return observed, homes


def recorded_closure(native, observation):
    observed = observation["native_closure"]
    require(observed.get("data") == ["disk-cas", "disk-run", "laststore-pack-node-v1"]
            and set(observed) == {"data", "disk-run", "disk-cas", "disk-run/runs", "disk-cas/runs"}
            and set(observation["native_home_ids"]) == {"disk-run", "disk-cas"},
            "The original snapshot closure observation has another shape")
    paths = {"laststore-pack-node-v1"}
    for folder in ("disk-run", "disk-cas"):
        require(observed[folder] == ["CURRENT", "LOCK", "laststore-run-home-v2", "runs"],
                "The original snapshot home closure differs")
        runs = observed[folder + "/runs"]
        require(isinstance(runs, list) and runs == sorted(set(runs)),
                "The original snapshot run names repeat or lack their exact order")
        paths.update(folder + "/" + name for name in ("CURRENT", "laststore-run-home-v2"))
        paths.update(folder + "/runs/" + name for name in runs)
    for item in native:
        native_path(item["path"])
    require(paths == {item["path"] for item in native}, "The original snapshot file closure is incomplete")
    marker = next(item for item in native if item["path"] == "laststore-pack-node-v1")
    require(marker["native_bytes"] == len(NODE)
            and marker["native_sha256"] == hashlib.sha256(NODE).hexdigest(),
            "The original restored node is not the exact typed-format4 marker")
