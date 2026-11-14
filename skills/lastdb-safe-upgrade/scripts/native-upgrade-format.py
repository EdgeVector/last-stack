#!/usr/bin/env python3
"""Require the same native disk format before replacing the primary binary."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess


FORMAT_FILE = "data/laststore-pack-node-v1"
FORMAT_SOURCE = "fold_db/crates/core/src/storage/format.rs"


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def read_file(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "unsafe local format marker")
        raw = stream.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, "oversized local format marker")
    return raw


def layout(mirror, source):
    require(re.fullmatch(r"[0-9a-f]{40}", source), "full LastDB source required")
    code = subprocess.check_output(["git", "-C", mirror, "show", f"{source}:{FORMAT_SOURCE}"],
                                   stderr=subprocess.DEVNULL, text=True, timeout=15)
    format_number = re.search(r"^pub const HOME_FORMAT: u32 = (\d+);$", code, re.M)
    marker = re.search(r'^pub const RECORD_NODE_BYTES: &\[u8\] = b("[^"]*");$', code, re.M)
    profile = re.search(r"^pub\(in crate::storage\) const RECORD_PROFILE: u16 = (\d+);$", code, re.M)
    require(format_number and marker and profile, "cannot identify the candidate disk format")
    marker = json.loads(marker[1])
    require(marker.startswith(f"format={format_number[1]}\n"), "source format marker differs")
    return marker.encode(), int(profile[1])


def compatible(home, mirror, baseline, candidate):
    old, new = (layout(mirror, source) for source in (baseline, candidate))
    if old != new or old[0] != read_file(home / FORMAT_FILE):
        raise ValueError("disk format changed: one-time logical export and import into a fresh home required")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("home", type=Path)
    parser.add_argument("mirror", type=Path)
    parser.add_argument("baseline")
    parser.add_argument("candidate")
    args = parser.parse_args()
    compatible(args.home, args.mirror, args.baseline, args.candidate)


if __name__ == "__main__":
    try:
        main()
    except (OSError, subprocess.SubprocessError):
        raise SystemExit("native disk format metadata is unavailable") from None
    except ValueError as error:
        raise SystemExit(str(error)) from None
