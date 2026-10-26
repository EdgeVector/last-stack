"""Closed source-policy identities, not generated CI receipts."""

from native_upgrade_common import require
from native_v2_release import git
from native_run_v2_blobs import EXACT_CHANGES, REVIEWED_SOURCE, REVIEWED_TREE
from native_run_v2_inputs import read

BASELINE = "58752ee6e40c658735ee9d6423cedadda40383b4"
BASELINE_PROGRAMS = {
    "lastdb": "3b7b52d441ef2a768fa9e862e0fa9a5ab15c889ee471b22579f25a516f8b5250",
    "lastdbd": "5fbc9aaf18667dff39742ab7eb1cc1c7c3bac809f8568ec4cacba850748e0dc2",
}
PROTECTED = ("vendor/", "fold_db/", "lastdb_storage_policy/", "app_identity_crypto/",
             "lastdb_identity/", "schema_service/", "cloud_backup_protocol/", ".github/",
             ".cargo/", "scripts/ci/", "scripts/lints/", "scripts/benchmarks/")


def tree(repo, source):
    result = {}
    for record in git(repo, "ls-tree", "-r", "-z", source).split(b"\0"):
        if record:
            header, name = record.decode().split("\t", 1)
            result[name] = header.split()
    return result


def check(evidence):
    source, repo = evidence["source_git_oid"], evidence["source_repository"]
    require(REVIEWED_SOURCE is not None and REVIEWED_TREE is not None and bool(EXACT_CHANGES),
            "The exact RunV2 source policy is pending review")
    require(source == REVIEWED_SOURCE
            and git(repo, "rev-parse", source + "^{tree}").decode().strip() == REVIEWED_TREE,
            "The candidate is outside the closed reviewed RunV2 source policy")
    git(repo, "merge-base", "--is-ancestor", BASELINE, source)
    proof = read(evidence["compatibility_record"], 512 * 1024, evidence["compatibility_sha256"])
    require(proof.get("schema") == "lastdb.native-source-compatibility.v1"
            and proof.get("profile") == "run-v2-ci-bootstrap-v1"
            and proof.get("baseline") == BASELINE and proof.get("candidate") == source
            and all(proof.get(name) is True for name in
                    ("source_reviewed", "no_native_format_change", "restore_migration_disallowed")),
            "The exact RunV2 source review is incomplete")
    before, after, changes = tree(repo, BASELINE), tree(repo, source), {}
    for path in before.keys() | after.keys():
        protected = path.startswith(PROTECTED) or path.rsplit("/", 1)[-1] in (
            "Cargo.toml", "Cargo.lock", "rust-toolchain.toml")
        if protected and before.get(path) != after.get(path):
            changes[path] = [before.get(path), after.get(path)]
    require(changes == EXACT_CHANGES and proof.get("reviewed_format_neutral_changes") == changes,
            "The protected source, mode, build input, or dependency map differs")
    return {"baseline": BASELINE, "candidate": source, "tree": REVIEWED_TREE,
            "protected_changes": len(changes), "record_sha256": evidence["compatibility_sha256"]}
