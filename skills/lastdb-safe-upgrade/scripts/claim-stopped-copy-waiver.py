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


def claim(home: Path, pid: int, start_ts: int, copy_path: Path, decision_slug: str) -> None:
    if decision_slug != DECISION or pid <= 0 or start_ts <= 0:
        raise ValueError("unproved-flush approval or stopped session is invalid")
    if home.is_symlink() or not home.is_dir():
        raise ValueError("primary home is absent or linked")
    if (not copy_path.is_absolute() or Path("/private/tmp") not in copy_path.parents
            or Path(os.path.normpath(str(copy_path))) != copy_path):
        raise ValueError("stopped copy path is not a canonical /private/tmp path")
    path = home / CLAIM
    payload = {
        "version": 1,
        "source_pid": pid,
        "source_start_ts": start_ts,
        "flush_proof": "absent",
        "owner_approved": "2026-10-06",
        "decision_slug": DECISION,
        "copy_path": str(copy_path),
    }
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
    fd = os.open(path, flags, stat.S_IRUSR | stat.S_IWUSR)
    with os.fdopen(fd, "w", encoding="utf-8") as output:
        json.dump(payload, output, separators=(",", ":"))
        output.write("\n")
        output.flush()
        os.fsync(output.fileno())
    dir_fd = os.open(home, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--start-ts", required=True, type=int)
    parser.add_argument("--copy-path", required=True, type=Path)
    parser.add_argument("--decision-slug", required=True)
    args = parser.parse_args()
    try:
        claim(args.home, args.pid, args.start_ts, args.copy_path, args.decision_slug)
    except (OSError, ValueError) as error:
        sys.exit(f"unproved-flush waiver refused: {error}")


if __name__ == "__main__":
    main()
