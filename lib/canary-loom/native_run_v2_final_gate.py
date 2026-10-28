"""Closed RunV2 maintenance with a verified final backup after the clean stop."""
import time

from native_upgrade_common import require
from native_run_v2_maintenance_bench import run as benchmark_run
from native_v2_maintenance import accepted_ci, artifact
from native_v2_public import PublicMetadata
from native_v2_release import accepted_release, git
from native_run_v2_gate import required_ci
from native_run_v2_inputs import read, digest
from native_run_v2_maintenance_source import BASELINE, BASELINE_PROGRAMS, check_reviewed
from native_run_v2_final_blobs import REVIEWED_SOURCE, REVIEWED_TREE, EXACT_CHANGES
from native_run_v2_final_recovery import request_id
from native_run_v2_final_dev import check as development
from native_run_v2_final_ci import source_ci

PROFILE = "run-v2-maintenance-v2"


def check(candidate, evidence, approval):
    require(evidence.get("schema") == "lastdb.run-v2-maintenance-evidence.v2"
            and evidence.get("profile") == PROFILE and approval.get("mode") == "native-run-v2-ci"
            and evidence.get("source_git_oid") == approval["source_git_oid"]
            and evidence.get("accepted_main_commit") == approval["accepted_main_commit"],
            "The exact ordinary RunV2 maintenance identity differs")
    require(approval["baseline_source_git_oid"] == BASELINE
            and approval["baseline_programs_sha256"] == BASELINE_PROGRAMS,
            "The ordinary RunV2 maintenance baseline differs")
    proofs = {name: digest(evidence[name]) for name in (
        "artifact_receipt_sha256", "development_sha256", "compatibility_sha256")}
    require(approval.get("proofs") == proofs, "The maintenance approval binds another proof")
    request_id(approval)
    source_review = check_reviewed(evidence, REVIEWED_SOURCE, REVIEWED_TREE, EXACT_CHANGES)
    metadata = PublicMetadata()
    source, accepted = evidence["source_git_oid"], evidence["accepted_main_commit"]
    release = accepted_release(evidence, metadata)
    require(release["acceptance_tree"] == approval["accepted_tree"], "The accepted tree differs")
    pull = metadata("/pulls/" + str(evidence["accepted_pull_request"]))
    require(pull.get("merged") is True and pull.get("head", {}).get("sha") == source
            and pull.get("merge_commit_sha") == accepted
            and pull.get("base", {}).get("ref") == "main"
            and pull.get("base", {}).get("repo", {}).get("full_name") == "EdgeVector/lastdb"
            and pull.get("head", {}).get("repo", {}).get("full_name") == "EdgeVector/lastdb",
            "The exact tested source PR is not merged")
    git(evidence["source_repository"], "merge-base", "--is-ancestor", BASELINE, source)
    head_checks, main_checks = source_ci(metadata, evidence), accepted_ci(metadata, accepted)
    ci = required_ci(metadata, evidence, head_checks)
    receipt = read(evidence["artifact_receipt"], 16384, evidence["artifact_receipt_sha256"])
    require(receipt.get("source") == source, "The CI artifact receipt source differs")
    package = artifact(candidate, evidence, metadata)
    measured = benchmark_run(metadata, evidence["accepted_main_benchmark_run"], accepted, False,
                             main_checks["check_run_ids"]["benchmark-complete"])
    dev = development(candidate, evidence, approval["memory_limit_mb"])
    return {"profile": PROFILE, "source_review": source_review, "release": release,
            "head_checks": head_checks, "main_checks": main_checks, "required_ci": ci,
            "artifact": package, "development": dev,
            "measurements": {k: measured[k] for k in ("run_id", "attempt", "source", "measure_check_run_id", "lane_check_run_ids", "artifacts")},
            "checked_at": int(time.time())}
