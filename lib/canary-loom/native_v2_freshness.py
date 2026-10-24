"""Explicit exact-CURRENT alternative to the unchanged five-minute live cut policy."""

import hashlib
import os
from pathlib import Path
import stat
import time

from native_upgrade_common import require


def configuration(approval):
    if "live_freshness" not in approval["recovery"]:
        return None
    value = approval["recovery"]["live_freshness"]
    expected = Path.home() / ".lastdb/data/disk-pack/CURRENT"
    require(isinstance(value, dict) and set(value) == {"policy", "current_path"}
            and value["policy"] == "exact_current" and value["current_path"] == str(expected)
            and Path(approval["primary_home"]) == Path.home() / ".lastdb",
            "Live freshness requires the exact approved CURRENT policy and path")
    return expected


def identity(info):
    return tuple(getattr(info, name) for name in (
        "st_dev", "st_ino", "st_uid", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns", "st_nlink"))


def directories(path):
    result = []
    for directory in (path.parent.parent.parent, path.parent.parent, path.parent):
        info = directory.lstat()
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                and info.st_mode & 0o022 == 0 and directory.resolve() == directory,
                "CURRENT directory is not canonical and owner controlled")
        result.append({"path": str(directory), "device": info.st_dev, "inode": info.st_ino,
                       "owner": info.st_uid, "mode": info.st_mode})
    return result


def observe(approval, report, session):
    path = configuration(approval)
    if path is None:
        return None
    parents = directories(path)
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_mode & 0o022 == 0 and before.st_size == 4096 and before.st_nlink == 1,
                "CURRENT is not an owner-controlled 4096-byte regular file")
        with os.fdopen(os.dup(descriptor), "rb") as stream:
            raw = stream.read(4097)
        require(len(raw) == 4096 and identity(before) == identity(os.fstat(descriptor))
                == identity(path.lstat()) and directories(path) == parents,
                "CURRENT changed during its bounded observation")
        digest = hashlib.sha256(raw).hexdigest()
        require(digest == report["captured_native_root"]["current_sha256"],
                "The current durable cut differs from the accepted live recovery point")
        return {"policy": "exact_current", "current_path": str(path),
                "observed_at": int(time.time()), "capture_started_at": report["capture_started_at"],
                "request_id": report["request_id"], "native_root": report["captured_native_root"],
                "job": report["accepted_backup"]["begin"]["job"],
                "commit_sha256": report["accepted_backup"]["commit_sha256"],
                "session": session, "current_sha256": digest, "current_bytes": len(raw),
                "directories": parents, "file_identity": list(identity(before))}
    finally:
        os.close(descriptor)


def validate(approval, report, proof, session, now):
    path = configuration(approval)
    if path is None:
        require(now - report["capture_started_at"] <= 300,
                "Live recovery point is older than five minutes")
        return
    fields = {"policy", "current_path", "observed_at", "capture_started_at", "request_id",
              "native_root", "job", "commit_sha256", "session", "current_sha256", "current_bytes",
              "directories", "file_identity"}
    require(isinstance(proof, dict) and set(proof) == fields and session is not None
            and proof["policy"] == "exact_current" and proof["current_path"] == str(path)
            and proof["session"] == session and proof["request_id"] == report["request_id"]
            and proof["native_root"] == report["captured_native_root"]
            and proof["job"] == report["accepted_backup"]["begin"]["job"]
            and proof["commit_sha256"] == report["accepted_backup"]["commit_sha256"]
            and proof["capture_started_at"] == report["capture_started_at"]
            and proof["current_sha256"] == report["captured_native_root"]["current_sha256"]
            and proof["current_bytes"] == 4096 and type(proof["observed_at"]) is int
            and 0 <= now - proof["observed_at"] <= 5,
            "Live recovery point lacks an exact current, session-bound observation")
