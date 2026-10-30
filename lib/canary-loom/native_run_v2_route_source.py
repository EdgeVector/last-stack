"""Close one route to the complete reviewed Git change map of its pinned commits."""

import hashlib
import json

from native_upgrade_common import require
from native_run_v2_auto_source import tree
from native_run_v2_inputs import digest, read
from native_v2_release import git

SCHEMA = "lastdb.run-v2-route-source-review.v1"


def changes(repo, baseline, source):
    before, after = tree(repo, baseline), tree(repo, source)
    return {path: [before.get(path), after.get(path)] for path in before.keys() | after.keys()
            if before.get(path) != after.get(path)}


def check(evidence, selected):
    source, repo, baseline = selected["source"], evidence["source_repository"], selected["baseline"]
    require(evidence["source_git_oid"] == evidence["accepted_main_commit"] == source,
            "The candidate is outside the closed route source review")
    candidate_tree = git(repo, "rev-parse", source + "^{tree}").decode().strip()
    baseline_tree = git(repo, "rev-parse", baseline + "^{tree}").decode().strip()
    # The baseline is an accepted main commit. It must be an ancestor of the
    # candidate, so the reviewed map is a forward change on one main line.
    require(git(repo, "merge-base", "--all", baseline, source).decode().splitlines() == [baseline],
            "The route baseline is not an ancestor of its accepted candidate")
    reviewed = changes(repo, baseline, source)
    changes_sha256 = hashlib.sha256(json.dumps(reviewed, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
    proof_sha = digest(evidence["compatibility_sha256"])
    proof = read(evidence["compatibility_record"], 2 * 1024 * 1024, proof_sha)
    require(len(reviewed) <= 20000 and proof.get("reviewed_changes") == reviewed
            and proof.get("reviewed_paths") == len(reviewed)
            and proof.get("reviewed_changes_sha256") == changes_sha256,
            "The complete reviewed Git mode, type, or blob map differs")
    activation = selected["kind"] == "activation"
    require(proof.get("schema") == SCHEMA and proof.get("profile") == selected["profile"]
            and proof.get("baseline") == baseline and proof.get("candidate") == source
            and proof.get("baseline_tree") == baseline_tree and proof.get("candidate_tree") == candidate_tree
            and proof.get("source_reviewed") is True
            and proof.get("baseline_node_marker") == selected["marker"].decode()
            and proof.get("candidate_node_marker") == selected["after"].decode()
            and proof.get("format_activation") is activation
            and proof.get("legacy_format_support") is False
            and proof.get("primary_restore_or_migration") is False,
            "The route compatibility review is absent or has another scope")
    require(activation == (baseline == source and not reviewed and selected["marker"] != selected["after"]),
            "Only an activation route keeps its exact program source and changes its marker")
    return {"baseline": baseline, "baseline_tree": baseline_tree, "candidate": source, "tree": candidate_tree,
            "changed_paths": len(reviewed), "reviewed_changes_sha256": changes_sha256,
            "review_sha256": proof_sha, "format_activation": activation,
            "baseline_node_marker": selected["marker"].decode(), "candidate_node_marker": selected["after"].decode(),
            "legacy_format_support": False, "backward_reopen_exercised": False}
