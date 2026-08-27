#!/usr/bin/env python3
"""Fail-closed source-ancestry gate for a LastDB primary candidate."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


OID_RE = re.compile(r"^[0-9a-f]{7,40}$", re.IGNORECASE)
VERSION_OID_RE = re.compile(r"-g([0-9a-f]{7,40})(?:\b|-dirty\b)", re.IGNORECASE)


def run(cmd: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, text=True, capture_output=True, check=False, timeout=10)


def binary_version(path: str) -> str:
    if not path:
        return ""
    try:
        proc = run([path, "--version"])
    except (OSError, subprocess.TimeoutExpired):
        return ""
    if proc.returncode != 0:
        return ""
    fields = (proc.stdout or "").strip().split()
    return fields[-1] if fields else ""


def version_oid(version: str) -> str:
    match = VERSION_OID_RE.search(version)
    return match.group(1).lower() if match else ""


def oid_compatible(left: str, right: str) -> bool:
    if not left or not right:
        return True
    left = left.lower()
    right = right.lower()
    return left.startswith(right) or right.startswith(left)


def manifest_oids(binary: str) -> list[str]:
    if not binary:
        return []
    path = Path(binary).expanduser().resolve()
    candidates = (
        path.parent / "manifest.json",
        path.parent / "lastdb-aarch64-apple-darwin.manifest.json",
        path.parent.parent / "manifest.json",
        path.parent.parent / "lastdb-aarch64-apple-darwin.manifest.json",
    )
    found: list[str] = []
    for candidate in candidates:
        if not candidate.is_file():
            continue
        try:
            doc = json.loads(candidate.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            continue
        oid = str(doc.get("source_git_oid") or doc.get("git_oid") or "").strip().lower()
        if OID_RE.fullmatch(oid) and oid not in found:
            found.append(oid)
    return found


def choose_source_oid(
    label: str,
    explicit: str,
    manifests: list[str],
    embedded: str,
) -> tuple[str, str]:
    values = [value.lower() for value in [explicit, *manifests, embedded] if value]
    for value in values:
        if not OID_RE.fullmatch(value):
            return "", f"{label} source oid is invalid: {value}"
    for index, left in enumerate(values):
        for right in values[index + 1 :]:
            if not oid_compatible(left, right):
                return "", f"{label} source evidence disagrees: {left} vs {right}"
    return (max(values, key=len), "") if values else ("", "")


def resolve_commit(git_dir: Path, oid: str) -> str:
    if not oid or not git_dir.is_dir():
        return ""
    try:
        proc = run(["git", "-C", str(git_dir), "rev-parse", "--verify", f"{oid}^{{commit}}"])
    except (OSError, subprocess.TimeoutExpired):
        return ""
    value = (proc.stdout or "").strip().lower()
    return value if proc.returncode == 0 and re.fullmatch(r"[0-9a-f]{40}", value) else ""


def is_ancestor(git_dir: Path, ancestor: str, descendant: str) -> bool | None:
    try:
        proc = run(
            ["git", "-C", str(git_dir), "merge-base", "--is-ancestor", ancestor, descendant]
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if proc.returncode == 0:
        return True
    if proc.returncode == 1:
        return False
    return None


def default_current_bin() -> str:
    explicit = os.environ.get("LASTDB_SAFE_UPGRADE_CURRENT_BIN", "").strip()
    if explicit:
        return explicit
    for candidate in (
        Path.home() / ".lastdb" / "current" / "lastdbd",
        Path.home() / ".lastdb" / "bin-with-upload-cap" / "lastdbd",
    ):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            return str(candidate)
    return shutil.which("lastdbd") or ""


def emit(ok: bool, relation: str, reason: str, **extra: object) -> int:
    payload = {"ok": ok, "relation": relation, "reason": reason, **extra}
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    return 0 if ok else 1


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--candidate", required=True)
    parser.add_argument("--candidate-version", default="")
    parser.add_argument("--candidate-source-oid", default="")
    parser.add_argument("--current-bin", default="")
    parser.add_argument("--current-version", default="")
    parser.add_argument("--current-source-oid", default="")
    parser.add_argument("--git-dir", default="")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    candidate = str(Path(args.candidate).expanduser())
    if not os.path.isfile(candidate) or not os.access(candidate, os.X_OK):
        return emit(False, "unknown", f"candidate is not executable: {candidate}")

    actual_candidate_version = binary_version(candidate)
    candidate_version = args.candidate_version or actual_candidate_version
    if not actual_candidate_version:
        return emit(False, "unknown", "candidate version is unreadable")
    if args.candidate_version and args.candidate_version != actual_candidate_version:
        return emit(
            False,
            "unknown",
            "candidate version does not match the graph context",
            candidate_version=actual_candidate_version,
            context_candidate_version=args.candidate_version,
        )

    current_bin = args.current_bin or default_current_bin()
    current_version = (
        args.current_version
        or os.environ.get("LASTDB_SAFE_UPGRADE_CURRENT_VERSION", "").strip()
        or binary_version(current_bin)
    )
    if not current_version:
        return emit(False, "unknown", "live primary version is unreadable")

    candidate_oid, candidate_error = choose_source_oid(
        "candidate",
        args.candidate_source_oid,
        manifest_oids(candidate),
        version_oid(candidate_version),
    )
    if candidate_error:
        return emit(False, "unknown", candidate_error)

    current_explicit = (
        args.current_source_oid
        or os.environ.get("LASTDB_SAFE_UPGRADE_CURRENT_SOURCE_GIT_OID", "").strip()
    )
    current_oid, current_error = choose_source_oid(
        "current",
        current_explicit,
        manifest_oids(current_bin),
        version_oid(current_version),
    )
    if current_error:
        return emit(False, "unknown", current_error)

    common = {
        "candidate_version": candidate_version,
        "current_version": current_version,
        "candidate_oid": candidate_oid,
        "current_oid": current_oid,
    }
    if candidate_oid and current_oid and oid_compatible(candidate_oid, current_oid):
        return emit(True, "current", "candidate source equals the live source", **common)

    if not candidate_oid or not current_oid:
        return emit(False, "unknown", "source ancestry is unproved", **common)

    git_dir = Path(
        args.git_dir
        or os.environ.get("LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR", "").strip()
        or Path.home() / ".cache" / "edgevector-git" / "fold.git"
    ).expanduser()
    candidate_commit = resolve_commit(git_dir, candidate_oid)
    current_commit = resolve_commit(git_dir, current_oid)
    common.update(
        {
            "candidate_oid": candidate_commit or candidate_oid,
            "current_oid": current_commit or current_oid,
            "git_dir": str(git_dir),
        }
    )
    if not candidate_commit or not current_commit:
        return emit(False, "unknown", "source commit cannot be resolved in the Fold mirror", **common)
    if candidate_commit == current_commit:
        return emit(True, "current", "candidate source equals the live source", **common)

    forward = is_ancestor(git_dir, current_commit, candidate_commit)
    reverse = is_ancestor(git_dir, candidate_commit, current_commit)
    if forward is None or reverse is None:
        return emit(False, "unknown", "git ancestry check failed", **common)
    if forward:
        return emit(True, "forward", "candidate descends from the live source", **common)
    if reverse:
        return emit(False, "stale", "candidate is older than the live source", **common)
    return emit(False, "diverged", "candidate is not on the live source lineage", **common)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
