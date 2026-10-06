#!/usr/bin/env python3
"""Write the durable marker for one stopped LastDB backup source copy."""

import argparse
import json
import os
from pathlib import Path
import stat
import time
from typing import Optional

DECISION = "decision-2026-10-06-cloud-sync-rescue-risk-acceptance"


def write_marker(copy: Path, pid: int, start_ts: int, waiver: Optional[str] = None) -> None:
    if copy.is_symlink() or not copy.is_dir():
        raise ValueError("copy root is absent or linked")
    receipt_path = copy / ".shutdown_flush_ready"
    if waiver is None:
        if receipt_path.is_symlink() or not receipt_path.is_file():
            raise ValueError("shutdown flush receipt is absent or linked")
        receipt = json.loads(receipt_path.read_text())
        if receipt != {"version": 1, "pid": pid, "start_ts": start_ts, "flush_ok": True}:
            raise ValueError("shutdown flush receipt does not match the stopped session")
    else:
        if waiver != DECISION:
            raise ValueError("unproved-flush approval does not match the decision")
        if receipt_path.exists() or receipt_path.is_symlink():
            raise ValueError("unproved-flush copy has a shutdown receipt")
        for path in (copy / "current-session.json", copy / "cloud_sync.json",
                     copy / "data/folddb.sock", copy / "data/folddb-full.sock"):
            if path.exists() or path.is_symlink():
                raise ValueError(f"unproved-flush copy has a live path: {path.name}")
        paused = copy / "cloud_sync.json.paused"
        if paused.is_symlink() or not paused.is_file():
            raise ValueError("paused cloud configuration is absent or linked")
        claim_path = copy / ".cloud_backup_unproved_flush_claim"
        if claim_path.is_symlink() or not claim_path.is_file():
            raise ValueError("unproved-flush claim is absent or linked")
        claim = json.loads(claim_path.read_text())
        if claim != {
            "version": 1,
            "source_pid": pid,
            "source_start_ts": start_ts,
            "flush_proof": "absent",
            "owner_approved": "2026-10-06",
            "decision_slug": DECISION,
            "copy_path": str(copy),
        }:
            raise ValueError("unproved-flush claim does not match the stopped session")
    marker = copy / ".cloud_backup_source_copy"
    if marker.exists() or marker.is_symlink():
        raise ValueError("copy marker already exists")
    payload = {
        "version": 1 if waiver is None else 2,
        "source_pid": pid,
        "source_start_ts": start_ts,
        "copied_at_unix_s": int(time.time()),
    }
    if waiver is not None:
        payload.update({
            "flush_proof": "absent",
            "owner_approved": "2026-10-06",
            "stop_proof": "supervised_sigterm_no_forced_kill",
        })
    temp = copy / f".cloud_backup_source_copy.tmp.{os.getpid()}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    fd = os.open(temp, flags, stat.S_IRUSR | stat.S_IWUSR)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(payload, output, separators=(",", ":"))
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temp, marker)
        dir_fd = os.open(copy, os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    finally:
        if temp.exists():
            temp.unlink()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--copy", required=True, type=Path)
    parser.add_argument("--pid", required=True, type=int)
    parser.add_argument("--start-ts", required=True, type=int)
    parser.add_argument("--accept-unproved-flush")
    args = parser.parse_args()
    if args.pid <= 0 or args.start_ts <= 0:
        parser.error("pid and start time must be positive")
    try:
        write_marker(args.copy, args.pid, args.start_ts, args.accept_unproved_flush)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        parser.exit(1, f"stopped-copy marker refused: {error}\n")


if __name__ == "__main__":
    main()
