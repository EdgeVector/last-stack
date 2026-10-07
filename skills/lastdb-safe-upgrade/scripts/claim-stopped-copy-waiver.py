#!/usr/bin/env python3
"""Consume the one approved unproved-flush stopped-copy attempt."""

import argparse
import json
import os
from pathlib import Path
import stat
import sys


DECISION = "decision-2026-10-06-cloud-sync-rescue-risk-acceptance"
CLAIM = ".cloud_backup_unproved_flush_claim"
TEMP_PARENT = Path("/private/tmp")
DURABLE_PARENT = Path(".local/state/last-stack/cloud-rescue/source-copies")


def expected_claim(pid: int, start_ts: int, copy_path: Path) -> dict:
    return {
        "version": 1,
        "source_pid": pid,
        "source_start_ts": start_ts,
        "flush_proof": "absent",
        "owner_approved": "2026-10-06",
        "decision_slug": DECISION,
        "copy_path": str(copy_path),
    }


def sync_home(home: Path) -> None:
    dir_fd = os.open(home, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def validate_copy_path(home: Path, copy_path: Path) -> None:
    if not copy_path.is_absolute() or Path(os.path.normpath(str(copy_path))) != copy_path:
        raise ValueError("stopped copy path is not canonical")
    parent = copy_path.parent
    if not parent.is_dir() or parent.is_symlink() or parent.resolve() != parent:
        raise ValueError("stopped copy parent is absent or linked")
    durable_parent = Path.home() / DURABLE_PARENT
    is_temp = parent == TEMP_PARENT or TEMP_PARENT in parent.parents
    is_durable = parent == durable_parent
    if not is_temp and not is_durable:
        raise ValueError("stopped copy parent is not approved")
    if is_durable:
        parent_stat = parent.stat()
        if parent_stat.st_uid != os.getuid() or stat.S_IMODE(parent_stat.st_mode) != 0o700:
            raise ValueError("stopped copy parent is not private")
    home_real = home.resolve()
    if parent == home_real or home_real in parent.parents:
        raise ValueError("stopped copy is under the primary home")
    if parent.stat().st_dev != home.stat().st_dev:
        raise ValueError("stopped copy is on another device")


def claim(home: Path, pid: int, start_ts: int, copy_path: Path, decision_slug: str,
          release: bool = False) -> None:
    if decision_slug != DECISION or pid <= 0 or start_ts <= 0:
        raise ValueError("unproved-flush approval or stopped session is invalid")
    if home.is_symlink() or not home.is_dir():
        raise ValueError("primary home is absent or linked")
    validate_copy_path(home, copy_path)
    if not release and (copy_path.exists() or copy_path.is_symlink()):
        raise ValueError("stopped copy path already exists")
    path = home / CLAIM
    payload = expected_claim(pid, start_ts, copy_path)
    if release:
        if copy_path.exists() or copy_path.is_symlink():
            raise ValueError("stopped copy was published; waiver claim stays consumed")
        if path.is_symlink() or not path.is_file() or path.stat().st_size > 4096:
            raise ValueError("unproved-flush claim is absent or unsafe")
        if json.loads(path.read_text()) != payload:
            raise ValueError("unproved-flush claim does not match this attempt")
        path.unlink()
        sync_home(home)
        return
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    sync_home(home)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--start-ts", required=True, type=int)
    parser.add_argument("--copy-path", required=True, type=Path)
    parser.add_argument("--decision-slug", required=True)
    parser.add_argument("--release", action="store_true")
    args = parser.parse_args()
    try:
        claim(args.home, args.pid, args.start_ts, args.copy_path, args.decision_slug, args.release)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        sys.exit(f"unproved-flush waiver refused: {error}")


if __name__ == "__main__":
    main()
