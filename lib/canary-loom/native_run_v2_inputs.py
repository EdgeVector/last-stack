"""Bounded private inputs for the RunV2 maintenance policy."""

import hashlib
import json
import os
from pathlib import Path
import re
import stat

from native_upgrade_common import require


def external(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts and len(path.parts) <= 64
            and path.parent.resolve() == path.parent, "An external input path is not canonical")
    roots = (Path.home() / ".local/state/last-stack/artifacts",
             Path.home() / ".local/state/last-stack/lastdb-safe-upgrade/native-run-v2-maintenance")
    require(any(root.resolve() == root and (path == root or root in path.parents) for root in roots),
            "RunV2 inputs require the exact canonical artifact or profile-journal root")
    return path


def parent_descriptor(path):
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY
    descriptor = os.open("/", flags)
    try:
        for part in path.parent.parts[1:]:
            child = os.open(part, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = child
        info = os.fstat(descriptor)
        require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid()
                and not info.st_mode & 0o022, "An input directory is not owner-controlled")
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def unique(pairs):
    value = {}
    for key, item in pairs:
        require(key not in value, "A private input repeats a JSON key")
        value[key] = item
    return value


def read(path, maximum=1024 * 1024, expected=None):
    path = external(path)
    parent = parent_descriptor(path)
    try:
        descriptor = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
    except BaseException:
        os.close(parent)
        raise
    try:
        before = os.fstat(descriptor)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and before.st_mode & 0o077 == 0 and before.st_nlink == 1
                and 0 < before.st_size <= maximum, "A private input has unsafe ownership or size")
        chunks, count = [], 0
        while True:
            block = os.read(descriptor, min(65536, maximum + 1 - count))
            if not block:
                break
            chunks.append(block)
            count += len(block)
            require(count <= maximum, "A private input exceeds its bound")
        after = os.fstat(descriptor)
        current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        identity = lambda item: (item.st_dev, item.st_ino, item.st_uid, item.st_mode,
                                 item.st_nlink, item.st_size, item.st_mtime_ns)
        require(identity(before) == identity(after) == identity(current)
                and count == before.st_size and path.parent.resolve() == path.parent
                and os.fstat(parent).st_ino == path.parent.lstat().st_ino
                and os.fstat(parent).st_dev == path.parent.lstat().st_dev,
                "A private input or its anchored directory changed during its read")
        raw = b"".join(chunks)
        require(expected is None or hashlib.sha256(raw).hexdigest() == expected,
                "A private input does not match its approved hash")
        value = json.loads(raw, object_pairs_hook=unique,
                           parse_constant=lambda unused: require(False, "Nonfinite JSON is forbidden"))
        require(isinstance(value, dict), "A private input must be a JSON object")
        return value
    finally:
        os.close(descriptor)
        os.close(parent)


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None,
            "A required SHA256 is invalid")
    return value


def uint(value, positive=False):
    require(type(value) is int and (value > 0 if positive else value >= 0)
            and value < 2**63, "A required exact counter is invalid")
    return value


def reference(value, maximum=8 * 1024 * 1024):
    require(isinstance(value, dict) and set(value) == {"path", "sha256"},
            "An original proof reference is incomplete")
    return read(value["path"], maximum, digest(value["sha256"]))


def unwrap(value):
    if value.get("ok") is True and isinstance(value.get("data"), dict):
        return value["data"]
    return value
