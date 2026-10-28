"""Review every changed format, writer, crypto, dependency, and build Git object."""
from pathlib import Path
from native_upgrade_common import require
from native_v2_release import git
from native_run_v2_inputs import read
from native_run_v2_maintenance_blobs import REVIEWED_SOURCE, REVIEWED_TREE, EXACT_CHANGES

BASELINE = "1a8d65daa6477f386c446c106c92fb587396b22f"
BASELINE_PROGRAMS = {
    "lastdb": "9b38986cd0103521dfca640c08fc98f4a75155e5b25db6aa7be6da7e90ba32ef",
    "lastdbd": "be8b67c328b40851aafe77508a75793c55ec9c185b4b66e2a27f8a3818148929",
}


def tree(repo, source):
    result = {}
    for record in git(repo, "ls-tree", "-r", "-z", source).split(b"\0"):
        if record:
            header, name = record.decode().split("\t", 1)
            result[name] = header.split()
    return result


def check(evidence):
    return check_reviewed(evidence, REVIEWED_SOURCE, REVIEWED_TREE, EXACT_CHANGES)


def check_reviewed(evidence, reviewed_source, reviewed_tree, exact_changes):
    source, repo = evidence["source_git_oid"], evidence["source_repository"]
    require(reviewed_source is not None and reviewed_tree is not None and bool(exact_changes),
            "The ordinary RunV2 maintenance source review is incomplete")
    require(source == reviewed_source and git(repo, "rev-parse", source + "^{tree}").decode().strip() == reviewed_tree,
            "The candidate is outside the closed maintenance source review")
    before, after = tree(repo, BASELINE), tree(repo, source)
    changes = {p: [before.get(p), after.get(p)] for p in before.keys() | after.keys()
               if before.get(p) != after.get(p)}
    proof = read(evidence["compatibility_record"], 512 * 1024, evidence["compatibility_sha256"])
    require(changes == exact_changes and proof.get("reviewed_changes") == changes
            and proof.get("baseline") == BASELINE and proof.get("candidate") == source
            and proof.get("source_reviewed") is True and proof.get("no_native_format_change") is True
            and proof.get("primary_restore_or_migration") is False,
            "The full reviewed maintenance source map differs")
    return {"baseline": BASELINE, "candidate": source, "tree": reviewed_tree,
            "changed_files": len(changes), "review_sha256": evidence["compatibility_sha256"]}
