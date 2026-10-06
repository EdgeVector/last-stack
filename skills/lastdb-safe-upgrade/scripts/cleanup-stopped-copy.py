#!/usr/bin/env python3
"""Remove one verified stopped rescue source copy after a fresh S0 restore."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import subprocess
import sys


TEMP_ROOT = Path("/private/tmp")
SHA = re.compile(r"[0-9a-f]{64}\Z")
COPY_NAME = re.compile(r"lastdb-stopped-backup-[A-Za-z0-9_-]{8,}\Z")
MAX_JSON_BYTES = 262_144


def refuse(message: str) -> None:
    raise ValueError(message)


def exact_temp_path(raw: str, label: str, directory: bool) -> Path:
    path = Path(raw)
    if not path.is_absolute() or os.path.normpath(raw) != raw or path.parent != TEMP_ROOT:
        refuse(f"{label} must be an exact child of /private/tmp")
    try:
        status = path.lstat()
    except OSError as error:
        refuse(f"{label} is unavailable: {error.strerror}")
    if stat.S_ISLNK(status.st_mode) or path.resolve() != path:
        refuse(f"{label} is a symlink or alias")
    if status.st_uid != os.getuid():
        refuse(f"{label} belongs to another user")
    if directory and not stat.S_ISDIR(status.st_mode):
        refuse(f"{label} is not a directory")
    if not directory and not stat.S_ISREG(status.st_mode):
        refuse(f"{label} is not a regular file")
    return path


def read_file(path: Path, limit: int = MAX_JSON_BYTES) -> bytes:
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError:
        refuse(f"required file is unavailable: {path.name}")
    try:
        status = os.fstat(fd)
        if not stat.S_ISREG(status.st_mode) or status.st_uid != os.getuid():
            refuse(f"required file is unsafe: {path.name}")
        if status.st_size > limit:
            refuse(f"required file is too large: {path.name}")
        chunks = []
        remaining = limit + 1
        while remaining:
            chunk = os.read(fd, remaining)
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        data = b"".join(chunks)
        if len(data) > limit:
            refuse(f"required file is too large: {path.name}")
        return data
    finally:
        os.close(fd)


def read_json(path: Path) -> dict:
    try:
        value = json.loads(read_file(path))
    except (UnicodeDecodeError, json.JSONDecodeError):
        refuse(f"required JSON is invalid: {path.name}")
    if not isinstance(value, dict):
        refuse(f"required JSON is not an object: {path.name}")
    return value


def require_regular(path: Path) -> None:
    try:
        status = path.lstat()
    except OSError:
        refuse(f"required file is unavailable: {path.name}")
    if not stat.S_ISREG(status.st_mode) or status.st_uid != os.getuid():
        refuse(f"required file is unsafe: {path.name}")


def require_absent(path: Path) -> None:
    if os.path.lexists(path):
        refuse(f"unexpected path exists: {path.name}")


def require_off(home: Path) -> None:
    require_absent(home / "cloud_sync.json")
    require_regular(home / "cloud_sync.json.paused")
    require_regular(home / ".cloud_resume_required")


def database_hash(store_uuid: str) -> str:
    if not isinstance(store_uuid, str) or not store_uuid or len(store_uuid) > 128:
        refuse("store UUID is invalid")
    return hashlib.sha256(f"laststore-db:{store_uuid}".encode()).hexdigest()


def require_identity(value: dict, db_hash: str, sha: str, store_uuid: str, counter: int) -> None:
    if (value.get("db_hash"), value.get("manifest_sha256"), value.get("store_uuid"),
        value.get("counter")) != (db_hash, sha, store_uuid, counter):
        refuse("rescue identities do not match")


def require_no_home_process(copy: Path, restored: Path) -> None:
    try:
        result = subprocess.run(
            ["ps", "-axo", "pid=,command="], check=True, capture_output=True, text=True
        )
    except (OSError, subprocess.CalledProcessError):
        refuse("active process check is unavailable")
    ignored = {os.getpid(), os.getppid()}
    for line in result.stdout.splitlines():
        parts = line.strip().split(maxsplit=1)
        if len(parts) == 2 and parts[0].isdigit():
            if int(parts[0]) not in ignored and any(
                str(home) in parts[1] for home in (copy, restored)
            ):
                refuse("a process still names a rescue home")


def require_no_open_files(home: Path) -> None:
    try:
        result = subprocess.run(
            ["lsof", "-w", "-n", "-P", "-F", "p", "+D", str(home)],
            capture_output=True, text=True, timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired):
        refuse("open-file check is unavailable")
    if result.returncode not in (0, 1):
        refuse("open-file check failed")
    holders = [
        int(line[1:]) for line in result.stdout.splitlines()
        if line.startswith("p") and line[1:].isdigit()
    ]
    if result.returncode == 1 and not result.stdout.strip() and not result.stderr.strip():
        return
    if not holders:
        refuse("open-file check returned no process identity")
    if any(pid not in (os.getpid(), os.getppid()) for pid in holders):
        refuse("a process still has a rescue file open")


def verify(args: argparse.Namespace) -> Path:
    copy = exact_temp_path(args.copy, "stopped copy", True)
    if not COPY_NAME.fullmatch(copy.name):
        refuse("stopped copy name is not recognized")
    restored = exact_temp_path(args.restored_home, "restored home", True)
    report_path = exact_temp_path(args.restore_report, "restore report", False)
    if restored == copy or report_path.is_relative_to(copy):
        refuse("restore proof aliases the stopped copy")
    if not SHA.fullmatch(args.expect_db_hash) or not SHA.fullmatch(args.expect_manifest_sha256):
        refuse("expected database or manifest hash is invalid")
    if stat.S_IMODE(copy.stat().st_mode) != 0o700:
        refuse("stopped copy permissions are not 0700")
    if os.path.lexists(Path(f"/tmp/lastdb-safe-upgrade-owner-{os.getuid()}.lock.d")):
        refuse("a safe-upgrade owner lock is present")
    require_off(copy)
    require_off(restored)
    require_regular(copy / "identity.key")
    exact_data = copy / "data"
    if not exact_data.is_dir() or exact_data.is_symlink():
        refuse("stopped copy data is unsafe")
    if not (restored / "data").is_dir() or (restored / "data").is_symlink():
        refuse("restored data is unsafe")
    for home in (copy, restored):
        for name in ("folddb.sock", "folddb-full.sock"):
            require_absent(home / "data" / name)
    if read_file(restored / ".bootstrap_done", 3) != b"ok\n":
        refuse("restored home lacks a complete bootstrap")

    source = read_json(copy / ".cloud_backup_source_copy")
    shutdown = read_json(copy / ".shutdown_flush_ready")
    if (source.get("version"), shutdown.get("version"), shutdown.get("flush_ok")) != (1, 1, True):
        refuse("stopped copy lacks a successful flush")
    if (source.get("source_pid"), source.get("source_start_ts")) != (
        shutdown.get("pid"), shutdown.get("start_ts")
    ):
        refuse("stopped copy session does not match the flush")
    if type(source.get("source_pid")) is not int or source["source_pid"] <= 0:
        refuse("stopped copy PID is invalid")
    if type(source.get("source_start_ts")) is not int or source["source_start_ts"] <= 0:
        refuse("stopped copy start time is invalid")

    source_high = read_json(copy / "laststore_high_water.json")
    target_high = read_json(restored / "laststore_high_water.json")
    store_uuid = source_high.get("store_uuid")
    db_hash = database_hash(store_uuid)
    if target_high.get("store_uuid") != store_uuid or db_hash != args.expect_db_hash:
        refuse("restored database hash differs from the stopped copy")
    complete = read_json(copy / ".rescue_s0_complete")
    target = read_json(restored / ".rescue_s0_restore_ready")
    report = read_json(report_path)
    sha = args.expect_manifest_sha256
    counter = complete.get("counter")
    if type(counter) is not int or counter <= 0:
        refuse("rescue counter is invalid")
    for value in (complete, target, report):
        require_identity(value, db_hash, sha, store_uuid, counter)
        if value.get("version") != 1 or value.get("cloud_sync_off") is not True:
            refuse("rescue proof does not keep cloud sync off")
    if complete.get("rescue_key") != f"rescue/s0/{sha}.json":
        refuse("rescue pointer key does not match the manifest")
    if target.get("ok") is not True or report.get("ok") is not True:
        refuse("source-free restore did not complete")
    if target.get("restore_mode") != "s0_only" or report.get("restore_mode") != "s0_only":
        refuse("restore mode is not S0-only")
    if report.get("source_scope_verified") is not True or report.get("remote_read_only") is not True:
        refuse("restore report lacks source scope proof")
    require_no_home_process(copy, restored)
    require_no_open_files(copy)
    require_no_open_files(restored)
    return copy


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--copy", required=True)
    parser.add_argument("--restored-home", required=True)
    parser.add_argument("--restore-report", required=True)
    parser.add_argument("--expect-db-hash", required=True)
    parser.add_argument("--expect-manifest-sha256", required=True)
    parser.add_argument("--execute", action="store_true")
    args = parser.parse_args()
    try:
        copy = verify(args)
        if args.execute:
            if not shutil.rmtree.avoids_symlink_attacks:
                refuse("safe directory removal is unavailable")
            shutil.rmtree(copy)
            if os.path.lexists(copy):
                refuse("stopped copy remains after removal")
        print(f"STOPPED_COPY_CLEANUP={'deleted' if args.execute else 'checked'} path={copy}")
        return 0
    except ValueError as error:
        print(f"STOPPED_COPY_CLEANUP=red reason={error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
