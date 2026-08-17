#!/usr/bin/env python3
"""Estimate bytes pinned solely by LastDB backup clones (APFS-aware proxy).

`du` double-counts APFS clones. `cp -cR` preserves (st_size, st_mtime_ns), so
that pair collapses every clone of one original to a single identity while a
rewritten segment keeps a distinct one. Bytes whose identity appears under a
backup root and nowhere under the live primary home are treated as pinned by
the backups alone.

This is an identity proxy, not block accounting — same method as brain
`lastdb-safe-upgrade-backups-pin-131-gib-with-no-retention-policy-2026-08-17`
(±10% decision band).

Usage:
  backup-pin-bytes.py <primary_home> <backup_root>
  backup-pin-bytes.py --tree <dir>   # sum identities under one tree only

Prints: pinned_bytes=<n> backup_trees=<n> live_identities=<n> backup_only_identities=<n>
"""
from __future__ import annotations

import os
import stat
import sys
from pathlib import Path
from typing import Dict, Iterable, Set, Tuple

Id = Tuple[int, int]  # (st_size, st_mtime_ns)


def mtime_ns(st: os.stat_result) -> int:
    ns = getattr(st, "st_mtime_ns", None)
    if ns is not None:
        return int(ns)
    return int(st.st_mtime * 1_000_000_000)


def walk_identities(root: Path) -> Dict[Id, int]:
    """Map identity -> size (size is st_size; one entry per identity)."""
    out: Dict[Id, int] = {}
    if not root.is_dir():
        return out
    for dirpath, _dirnames, filenames in os.walk(root, followlinks=False):
        for name in filenames:
            path = Path(dirpath) / name
            try:
                st = path.lstat()
            except OSError:
                continue
            if not stat.S_ISREG(st.st_mode):
                continue
            key: Id = (int(st.st_size), mtime_ns(st))
            # First win is enough; size is identical for a given identity key.
            if key not in out:
                out[key] = int(st.st_size)
    return out


def routine_backup_dirs(backup_root: Path) -> list[Path]:
    """Only routine pre-<ver>-from-<ver>-<ts> trees (not BROKEN / pre-repair / hand names)."""
    found: list[Path] = []
    if not backup_root.is_dir():
        return found
    for child in sorted(backup_root.iterdir()):
        if not child.is_dir() or child.is_symlink():
            continue
        name = child.name
        # Narrow: pre-…-from-…-YYYYMMDDTHHMMSSZ
        if not name.startswith("pre-"):
            continue
        if "-from-" not in name:
            continue
        if len(name) < 17:
            continue
        ts = name[-16:]
        if (
            len(ts) == 16
            and ts[8] == "T"
            and ts.endswith("Z")
            and ts[:8].isdigit()
            and ts[9:15].isdigit()
        ):
            found.append(child)
    return found


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--tree":
        tree = Path(argv[2])
        ids = walk_identities(tree)
        pinned = sum(ids.values())
        print(
            f"pinned_bytes={pinned} backup_trees=1 live_identities=0 "
            f"backup_only_identities={len(ids)}"
        )
        return 0

    if len(argv) != 3:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    primary = Path(argv[1])
    backup_root = Path(argv[2])
    live = walk_identities(primary)
    live_keys: Set[Id] = set(live.keys())

    trees = routine_backup_dirs(backup_root)
    # Also scan non-routine siblings so preflight cost is complete (BROKEN, pre-repair, …)
    all_dirs: list[Path] = []
    if backup_root.is_dir():
        for child in sorted(backup_root.iterdir()):
            if child.is_dir() and not child.is_symlink():
                all_dirs.append(child)

    backup_only: Dict[Id, int] = {}
    for d in all_dirs:
        for key, size in walk_identities(d).items():
            if key in live_keys:
                continue
            if key not in backup_only:
                backup_only[key] = size

    pinned = sum(backup_only.values())
    print(
        f"pinned_bytes={pinned} backup_trees={len(all_dirs)} "
        f"live_identities={len(live_keys)} backup_only_identities={len(backup_only)} "
        f"routine_pre_trees={len(trees)}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
