"""Close the current typed-format4 upgrade to its complete reviewed Git trees."""

from native_upgrade_common import require
from native_run_v2_inputs import digest, read
from native_v2_release import git
from native_run_v2_auto_changes_a import CHANGES as FIRST
from native_run_v2_auto_changes_b import CHANGES as SECOND
from native_run_v2_auto_changes_c import CHANGES as THIRD

BASELINE = "1d4b205bb84ad3f6dc0a3b4c9d5088e13b499f46"
BASELINE_TREE = "3cc0d32c3434d044c3f0d436f4026dcd672fa065"
COMMON_ANCESTOR = "2f83760fa74c391abbfc9312515dd168ac2dff40"
SOURCE = "a1c406f5d1dbfdd99b826be2e4854c025993a90b"
TREE = "66709687327401c26298d713c360b3ba7edbdc41"
BASELINE_PROGRAMS = {
    "lastdb": "f94b96c5a820a19c76502c150c8b2815ff0d150dff86720c3f11f489976422ed",
    "lastdbd": "a53ac5ce39713574a47f9c8a9a38c337dd395c70a02212c217d2cf80d99c87d5",
}
EXACT_CHANGES = {**FIRST, **SECOND, **THIRD}


def tree(repo, source):
    result = {}
    for record in git(repo, "ls-tree", "-r", "-z", source).split(b"\0"):
        if record:
            header, name = record.decode().split("\t", 1)
            require(name not in result, "The source tree repeats a path")
            result[name] = header.split()
    return result


def check(evidence):
    source, repo = evidence["source_git_oid"], evidence["source_repository"]
    require(source == SOURCE and evidence["accepted_main_commit"] == SOURCE
            and git(repo, "rev-parse", source + "^{tree}").decode().strip() == TREE,
            "The candidate is outside the closed format4 source review")
    # The exact installed head became PR606 through a squash merge. Compare
    # its original tree, not a claim that the original head is on main.
    require(git(repo, "rev-parse", BASELINE + "^{tree}").decode().strip() == BASELINE_TREE
            and git(repo, "merge-base", "--all", BASELINE, source).decode().splitlines()
            == [COMMON_ANCESTOR], "The exact reviewed baseline tree or common ancestor differs")
    before, after = tree(repo, BASELINE), tree(repo, source)
    changes = {path: [before.get(path), after.get(path)] for path in before.keys() | after.keys()
               if before.get(path) != after.get(path)}
    proof_sha = digest(evidence["compatibility_sha256"])
    proof = read(evidence["compatibility_record"], 512 * 1024, proof_sha)
    require(len(EXACT_CHANGES) == len(FIRST) + len(SECOND) + len(THIRD)
            and changes == EXACT_CHANGES and proof.get("reviewed_changes") == changes,
            "The complete reviewed Git mode, type, or blob map differs")
    require(proof.get("schema") == "lastdb.format4-auto-source-review.v1"
            and proof.get("baseline") == BASELINE and proof.get("candidate") == SOURCE
            and proof.get("baseline_tree") == BASELINE_TREE
            and proof.get("common_ancestor") == COMMON_ANCESTOR
            and proof.get("candidate_tree") == TREE
            and proof.get("source_reviewed") is True
            and proof.get("existing_typed_format4_only") is True
            and proof.get("legacy_format_support") is False
            and proof.get("primary_restore_or_migration") is False,
            "The typed-format4 compatibility review is absent or has another scope")
    return {"baseline": BASELINE, "baseline_tree": BASELINE_TREE,
            "common_ancestor": COMMON_ANCESTOR, "candidate": source, "tree": TREE,
            "changed_paths": len(changes), "review_sha256": proof_sha,
            "existing_typed_format4_only": True, "legacy_format_support": False,
            "backward_reopen_exercised": False}
