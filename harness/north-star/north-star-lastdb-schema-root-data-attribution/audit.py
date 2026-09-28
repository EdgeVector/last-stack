#!/usr/bin/env python3
"""Audit refcount deletion candidates against isolated-copy reachability.

This is the former schema-root copy-only harness. It is now an audit, not a
North Star proof. A disagreement reports a refcount bookkeeping defect and
does not return a terminal-gate failure code.
"""

import argparse
import json
import sys
from collections import deque
from pathlib import Path


CANDIDATE_SCHEMA = "lastdb-atom-refcount-grace-window-delete.v1"
REACHABILITY_SCHEMA = "lastdb-schema-root-reachability.v1"
REPORT_SCHEMA = "lastdb-refcount-reachability-audit.v1"
ROOT_GROUPS = ("schema_catalogs", "retention", "system")
PRIMARY_MARKERS = ("/.lastdb", "/.folddb", "~/.lastdb", "~/.folddb")


class AuditError(RuntimeError):
    pass


def load_json(path):
    try:
        data = json.loads(Path(path).read_text(encoding="utf-8"))
    except OSError as exc:
        raise AuditError("cannot read %s: %s" % (path, exc)) from exc
    except json.JSONDecodeError as exc:
        raise AuditError("%s is not JSON: %s" % (path, exc)) from exc
    if not isinstance(data, dict):
        raise AuditError("%s must contain a JSON object" % path)
    return data


def reject_primary(value, label):
    text = json.dumps(value, sort_keys=True)
    if any(marker in text for marker in PRIMARY_MARKERS):
        raise AuditError("%s names a primary LastDB home" % label)


def copy_id(document, label):
    surface = document.get("surface")
    if not isinstance(surface, dict):
        raise AuditError("%s has no surface object" % label)
    if surface.get("kind") != "isolated-copy":
        raise AuditError("%s is not from an isolated copy" % label)
    value = surface.get("copy_id")
    if not isinstance(value, str) or not value:
        raise AuditError("%s has no isolated copy identity" % label)
    return value


def candidate_atoms(document):
    if document.get("schema") != CANDIDATE_SCHEMA:
        raise AuditError("candidate schema is not %s" % CANDIDATE_SCHEMA)
    candidates = document.get("candidates")
    if not isinstance(candidates, list):
        raise AuditError("candidates is not a list")
    atoms = []
    seen = set()
    for row in candidates:
        if not isinstance(row, dict):
            raise AuditError("a candidate is not an object")
        atom_id = row.get("atom_id")
        if not isinstance(atom_id, str) or not atom_id:
            raise AuditError("a candidate has no atom_id")
        if atom_id in seen:
            raise AuditError("candidate atom_id %s appears twice" % atom_id)
        if row.get("refcount") != 0:
            raise AuditError("candidate %s does not have refcount zero" % atom_id)
        if row.get("grace_elapsed") is not True:
            raise AuditError("candidate %s has not passed the grace window" % atom_id)
        seen.add(atom_id)
        atoms.append(atom_id)
    return atoms


def graph(document):
    if document.get("schema") != REACHABILITY_SCHEMA:
        raise AuditError("reachability schema is not %s" % REACHABILITY_SCHEMA)
    roots = document.get("roots")
    objects = document.get("objects")
    if not isinstance(roots, dict) or not isinstance(objects, list):
        raise AuditError("reachability needs roots and objects")
    edges = {}
    for row in objects:
        if not isinstance(row, dict):
            raise AuditError("a reachable object is not an object")
        object_id = row.get("id")
        references = row.get("references", [])
        if not isinstance(object_id, str) or not object_id:
            raise AuditError("a reachable object has no id")
        if object_id in edges:
            raise AuditError("reachable object %s appears twice" % object_id)
        if not isinstance(references, list) or not all(isinstance(item, str) and item for item in references):
            raise AuditError("reachable object %s has invalid references" % object_id)
        edges[object_id] = references
    starts = []
    for group in ROOT_GROUPS:
        ids = roots.get(group, [])
        if not isinstance(ids, list) or not all(isinstance(item, str) and item for item in ids):
            raise AuditError("root group %s is invalid" % group)
        starts.extend((group, item) for item in ids)
    return edges, starts


def reachability(edges, starts):
    """Return each reachable id and the root classes that reach it."""
    reached = {}
    queue = deque(starts)
    while queue:
        root_group, object_id = queue.popleft()
        groups = reached.setdefault(object_id, set())
        if root_group in groups:
            continue
        groups.add(root_group)
        for child in edges.get(object_id, []):
            queue.append((root_group, child))
    return reached


def audit(candidates_document, reachability_document):
    reject_primary(candidates_document, "candidate input")
    reject_primary(reachability_document, "reachability input")
    candidate_copy = copy_id(candidates_document, "candidate input")
    reachability_copy = copy_id(reachability_document, "reachability input")
    if candidate_copy != reachability_copy:
        raise AuditError("candidate and reachability inputs use different isolated copies")
    candidates = candidate_atoms(candidates_document)
    edges, starts = graph(reachability_document)
    live = reachability(edges, starts)
    disagreements = [
        {"atom_id": atom_id, "root_groups": sorted(live[atom_id])}
        for atom_id in candidates
        if atom_id in live
    ]
    return {
        "schema": REPORT_SCHEMA,
        "surface": {"kind": "isolated-copy", "copy_id": candidate_copy},
        "result": "disagreement" if disagreements else "agreement",
        "terminal_gate": False,
        "candidate_count": len(candidates),
        "reachable_candidate_count": len(disagreements),
        "reachable_candidates": disagreements,
        "action": (
            "file-refcount-bookkeeping-bug" if disagreements else "no-action"
        ),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidates", required=True, help="refcount grace-window candidate JSON")
    parser.add_argument("--reachability", required=True, help="isolated-copy reachability JSON")
    parser.add_argument("--out", type=Path, help="write the audit report to this path")
    args = parser.parse_args()
    report = audit(load_json(args.candidates), load_json(args.reachability))
    text = json.dumps(report, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    else:
        sys.stdout.write(text)
    # Disagreement is a defect report. It must not act as a terminal gate.
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AuditError as exc:
        print("lastdb refcount audit: %s" % exc, file=sys.stderr)
        raise SystemExit(2)
