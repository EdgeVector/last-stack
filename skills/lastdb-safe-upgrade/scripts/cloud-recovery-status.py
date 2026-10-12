#!/usr/bin/env python3
"""Validate one owned native cloud recovery status sample with exact integers."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import stat
import sys

CAP = 4 * 1024 * 1024
U64_MAX = 18446744073709551615


def require(value):
    if not value:
        raise ValueError("cloud recovery status refused")


def metadata(info):
    return (info.st_uid, info.st_mode, info.st_dev, info.st_ino, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result


def integer(token):
    require(len(token) <= 21)
    return int(token)


def floating(token):
    require(len(token) <= 128)
    value = float(token)
    require(math.isfinite(value))
    return value


def read_status(path):
    require(path.is_absolute())
    parent = path.parent.lstat()
    require(stat.S_ISDIR(parent.st_mode) and parent.st_uid == os.getuid())
    require(stat.S_IMODE(parent.st_mode) == 0o700)
    physical = path.parent.resolve(strict=True)
    parent_fd = os.open(physical, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    fd = None
    try:
        require(metadata(os.fstat(parent_fd)) == metadata(parent))
        before = path.lstat()
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid())
        require(stat.S_IMODE(before.st_mode) == 0o600 and before.st_nlink == 1)
        require(0 < before.st_size <= CAP)
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        require(metadata(os.fstat(fd)) == metadata(before))
        raw = bytearray()
        while len(raw) <= CAP:
            block = os.read(fd, min(65536, CAP + 1 - len(raw)))
            if not block:
                break
            raw.extend(block)
        require(len(raw) == before.st_size)
        require(metadata(os.fstat(fd)) == metadata(before))
        require(metadata(path.lstat()) == metadata(before))
        require(path.parent.resolve(strict=True) == physical)
        require(metadata(path.parent.lstat()) == metadata(parent))
        require(metadata(os.fstat(parent_fd)) == metadata(parent))
    finally:
        if fd is not None:
            os.close(fd)
        os.close(parent_fd)
    return json.loads(bytes(raw).decode("utf-8", errors="strict"), object_pairs_hook=pairs,
                      parse_int=integer, parse_float=floating,
                      parse_constant=lambda _value: require(False))


def unsigned(value):
    require(type(value) is int and 0 <= value <= U64_MAX)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status", required=True, type=Path)
    parser.add_argument("--max-age-secs", required=True)
    args = parser.parse_args()
    require(re.fullmatch(r"[0-9]+", args.max_age_secs) is not None)
    require(len(args.max_age_secs) <= 20)
    max_age = unsigned(int(args.max_age_secs))
    value = read_status(args.status)
    require(type(value) is dict and value.get("ok") is True)
    require(type(value.get("status")) is dict)
    sync = value["status"].get("sync")
    require(type(sync) is dict)
    require(sync.get("enabled") is True and sync.get("state") in ("Idle", "Dirty", "Syncing"))
    require(sync.get("sync_degraded") is False and unsigned(sync.get("consecutive_sync_failures")) == 0)
    require("last_error" in sync and sync["last_error"] is None)
    require("replay_blocker" in sync and sync["replay_blocker"] is None)
    require(sync.get("mutation_log_active") is True and sync.get("mutation_log_lag_degraded") is False)
    frontier = unsigned(sync.get("mutation_log_frontier_f"))
    durable = unsigned(sync.get("mutation_log_last_durable_frontier"))
    published = unsigned(sync.get("mutation_log_published_through"))
    require(published >= frontier and published >= durable)
    for key in ("upload_queue_count", "pending_count", "durable_outbox_count"):
        require(unsigned(sync.get(key)) == 0)
    age = unsigned(sync.get("mutation_log_recovery_point_age_secs"))
    require(age <= max_age)
    print("ok %d %d" % (published, age))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, RecursionError):
        print("refused")
        raise SystemExit(1)
