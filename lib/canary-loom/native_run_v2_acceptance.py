"""One reviewed accepted integration; the selected artifact remains H."""

import hashlib
import json

from native_upgrade_common import require
from native_run_v2_acceptance_changes_a import EXACT_CHANGES as FIRST
from native_run_v2_acceptance_changes_b import EXACT_CHANGES as SECOND
from native_run_v2_compatibility import tree
from native_run_v2_inputs import read

PROFILE = "run-v2-ci-bootstrap-v2"
SOURCE = "ee8a5b78f4d337c26542fea5e38543ef523587f7"
SOURCE_TREE = "9d82065b4afbe58a312db64ba12a6ee85fc576f7"
ACCEPTED = "54337df4199e78a72c65ad08bf9ddde147ea9b51"
PARENT = "0b0a79d4c10949e2f0570e82d9bc4fdb9513a285"
ACCEPTED_TREE = "49bd0c89df992749aaf74c70ce4d86727a961988"
MERGE_BASE = "24f2844b2efe8b8f39349a5c5c9dfedb65599d04"
DELTA_SHA256 = "38086d231dac74149fa5d7285374929b6ee21fe845b08ef82f46a8fd19fdea0a"
REVIEW_SHA256 = "7b23892880e8578438755b8005813980f2db1702e76d52523c65240eea43d305"


def check(evidence, approval, result):
    identities = {"source_git_oid": SOURCE, "artifact_tree": SOURCE_TREE,
                  "accepted_main_commit": ACCEPTED, "accepted_parent": PARENT,
                  "accepted_tree": ACCEPTED_TREE, "accepted_pull_request": 434}
    require(all(evidence.get(k) == v and approval.get(k) == v for k, v in identities.items()),
            "The versioned accepted integration names another source or acceptance")
    expected = {"artifact_source": SOURCE, "artifact_tree": SOURCE_TREE,
                "acceptance_commit": ACCEPTED, "acceptance_tree": ACCEPTED_TREE,
                "method": "merged_pull_request", "pull_request": 434,
                "squash_parent": PARENT, "merge_base": MERGE_BASE}
    require(result == expected, "The exact clean accepted integration proof differs")
    require(not FIRST.keys() & SECOND.keys() and len(FIRST) + len(SECOND) == 184,
            "The closed acceptance map is incomplete or repeats a path")
    before, after = tree(evidence["source_repository"], SOURCE), tree(evidence["source_repository"], ACCEPTED)
    changes = {path: [before.get(path), after.get(path)] for path in before.keys() | after.keys()
               if before.get(path) != after.get(path)}
    encoded = json.dumps(changes, sort_keys=True, separators=(",", ":")).encode()
    require(changes == {**FIRST, **SECOND} and hashlib.sha256(encoded).hexdigest() == DELTA_SHA256
            and evidence.get("acceptance_delta_sha256") == DELTA_SHA256
            and approval["proofs"].get("acceptance_delta_sha256") == DELTA_SHA256,
            "The complete accepted source delta differs from its reviewed tuples")
    require(evidence.get("acceptance_review_sha256") == REVIEW_SHA256
            and approval["proofs"].get("acceptance_review_sha256") == REVIEW_SHA256,
            "The named approval does not bind the exact source-review record")
    review = read(evidence["acceptance_review_record"], 128 * 1024, REVIEW_SHA256)
    require(review.get("schema") == "lastdb.run-v2-accepted-integration-review.v1"
            and review.get("profile") == PROFILE and review.get("reviewed_changes") == changes
            and review.get("acceptance_delta_sha256") == DELTA_SHA256
            and review.get("source_reviewed") is True
            and review.get("active_run_v2_security_or_format_fix_omitted") is False
            and review.get("artifact_is_accepted_main_binary") is False
            and review.get("artifact_retains_legacy_tools_removed_from_main") is True,
            "The exact private acceptance source review is incomplete")
    return {"changed_paths": len(changes), "delta_sha256": DELTA_SHA256,
            "review_sha256": REVIEW_SHA256, "artifact_is_accepted_main_binary": False}
