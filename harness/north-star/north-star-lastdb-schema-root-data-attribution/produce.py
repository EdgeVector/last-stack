#!/usr/bin/env python3
"""Produce refcount-audit input documents from one running isolated copy.

The producer asks the daemon for grace-window candidates, then asks its
liveness walker about every candidate. It never reads a LastDB data tree.
The caller must point it at a running CoW copy, not the primary home.
"""

import argparse
import hashlib
import json
import stat
import subprocess
import sys
from pathlib import Path


CANDIDATE_SCHEMA = "lastdb-atom-refcount-grace-window-delete.v1"
REACHABILITY_SCHEMA = "lastdb-schema-root-reachability.v1"
PRIMARY_NAMES = {".lastdb", ".folddb"}


class ProduceError(RuntimeError):
    pass


def run_json(command, label):
    result = subprocess.run(command, check=False, capture_output=True, text=True)
    if result.returncode:
        detail = result.stderr.strip().replace("\n", " ")[-400:]
        raise ProduceError("%s failed: %s" % (label, detail or result.returncode))
    try:
        document = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise ProduceError("%s did not return JSON: %s" % (label, exc)) from exc
    if not isinstance(document, dict):
        raise ProduceError("%s did not return a JSON object" % label)
    return document


def isolated_copy(home):
    resolved = home.resolve()
    if resolved.name in PRIMARY_NAMES or any(part in PRIMARY_NAMES for part in resolved.parts[-2:]):
        raise ProduceError("refusing a primary LastDB home")
    socket_path = resolved / "data" / "folddb.sock"
    if not socket_path.exists() or not stat.S_ISSOCK(socket_path.stat().st_mode):
        raise ProduceError("%s has no running isolated-copy socket" % resolved)
    if not (resolved / ".lastdb-dev-owner").is_file():
        raise ProduceError("%s has no LastDB CoW owner stamp" % resolved)
    return resolved


def copy_identity(home):
    stamp = (home / ".lastdb-dev-owner").read_bytes()
    digest = hashlib.sha256(str(home).encode("utf-8") + b"\0" + stamp).hexdigest()[:20]
    return "cow-" + digest


def candidates(document):
    rows = document.get("candidates")
    if not isinstance(rows, list):
        raise ProduceError("gc-atoms JSON has no candidates list")
    result = []
    seen = set()
    for row in rows:
        if not isinstance(row, dict):
            raise ProduceError("a gc-atoms candidate is not an object")
        atom_id = row.get("atom_id")
        if not isinstance(atom_id, str) or not atom_id:
            raise ProduceError("a gc-atoms candidate has no atom_id")
        if atom_id in seen:
            raise ProduceError("gc-atoms listed %s twice" % atom_id)
        if row.get("refcount") != 0 or row.get("grace_elapsed") is not True:
            raise ProduceError("candidate %s is not zero-count after the grace window" % atom_id)
        seen.add(atom_id)
        result.append({"atom_id": atom_id, "refcount": 0, "grace_elapsed": True})
    return result


def root_groups(document, atom_id):
    if document.get("complete") is not True:
        raise ProduceError("liveness explanation for %s is incomplete" % atom_id)
    state = document.get("reclaim_state")
    if state == "candidate":
        return []
    groups = document.get("root_groups")
    if not isinstance(groups, list) or not groups or not all(isinstance(item, str) for item in groups):
        raise ProduceError("live candidate %s has no root_groups" % atom_id)
    allowed = {"schema_catalogs", "retention", "system"}
    if not set(groups).issubset(allowed):
        raise ProduceError("live candidate %s has an unknown root group" % atom_id)
    return sorted(set(groups))


def write_json(path, document):
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--copy-home", required=True, type=Path)
    parser.add_argument("--out-dir", required=True, type=Path)
    parser.add_argument("--lastdb", default="lastdb")
    args = parser.parse_args()

    home = isolated_copy(args.copy_home)
    args.out_dir.mkdir(parents=True, exist_ok=True)
    if args.out_dir.resolve() == home or home in args.out_dir.resolve().parents:
        raise ProduceError("output must stay outside the isolated-copy home")
    copy_id = copy_identity(home)
    prefix = [args.lastdb, "--data-dir", str(home)]
    candidate_rows = candidates(run_json(prefix + ["db", "gc-atoms", "--json"], "gc-atoms"))
    roots = {"schema_catalogs": [], "retention": [], "system": []}
    objects = []
    for row in candidate_rows:
        atom_id = row["atom_id"]
        explanation = run_json(prefix + ["liveness", "explain", "atom", atom_id, "--json"], "liveness explain")
        for group in root_groups(explanation, atom_id):
            root_id = "%s:%s" % (group, atom_id)
            roots[group].append(root_id)
            objects.append({"id": root_id, "references": [atom_id]})

    candidate_path = args.out_dir / "candidates.json"
    reachability_path = args.out_dir / "reachability.json"
    write_json(candidate_path, {"schema": CANDIDATE_SCHEMA, "surface": {"kind": "isolated-copy", "copy_id": copy_id}, "candidates": candidate_rows})
    write_json(reachability_path, {"schema": REACHABILITY_SCHEMA, "surface": {"kind": "isolated-copy", "copy_id": copy_id}, "roots": roots, "objects": objects})
    print(json.dumps({"copy_id": copy_id, "candidates": str(candidate_path), "reachability": str(reachability_path)}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except ProduceError as exc:
        print("lastdb refcount audit producer: %s" % exc, file=sys.stderr)
        raise SystemExit(2)
