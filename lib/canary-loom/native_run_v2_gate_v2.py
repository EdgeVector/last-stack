"""Closed second profile for one tested H accepted beside other main changes."""

import time

from native_upgrade_common import require
from native_v2_benchmark import run as benchmark_run
from native_v2_maintenance import accepted_ci, artifact
from native_v2_public import PublicMetadata
from native_v2_release import accepted_release, git
from native_run_v2_acceptance import PROFILE, check as acceptance
from native_run_v2_compatibility import BASELINE, BASELINE_PROGRAMS, check as compatibility
from native_run_v2_development import check as development
from native_run_v2_gate import PULL_REQUEST, required_ci
from native_run_v2_inputs import digest, external, read


def release(candidate, evidence, approval):
    require(evidence.get("github_metadata_transport") == "public_https",
            "RunV2 bootstrap requires bounded credential-free public provenance")
    metadata = PublicMetadata()
    source, accepted = evidence["source_git_oid"], evidence["accepted_main_commit"]
    require(type(evidence.get("accepted_pull_request")) is int
            and evidence["accepted_pull_request"] == PULL_REQUEST,
            "The closed RunV2 release requires its exact merged PR")
    result = accepted_release(evidence, metadata)
    integration = acceptance(evidence, approval, result)
    head = metadata("/commits/" + source)
    require(head.get("sha") == source
            and head.get("commit", {}).get("tree", {}).get("sha") == result["artifact_tree"],
            "The original tested artifact head tree differs")
    git(evidence["source_repository"], "merge-base", "--is-ancestor", BASELINE, source)
    head_checks, main_checks = accepted_ci(metadata, source), accepted_ci(metadata, accepted)
    ci = required_ci(metadata, evidence, head_checks)
    external(evidence["artifact_archive"])
    receipt = read(evidence["artifact_receipt"], 16384, evidence["artifact_receipt_sha256"])
    require(receipt.get("source") == source, "The original Mac receipt names another source")
    archived = artifact(candidate, evidence, metadata)
    measured = benchmark_run(metadata, evidence.get("accepted_main_benchmark_run"), accepted,
                             False, main_checks["check_run_ids"]["benchmark-complete"])
    return {"acceptance": result, "reviewed_integration": integration,
            "head_checks": head_checks, "main_checks": main_checks,
            "required_ci": ci, "artifact": archived,
            "head_benchmark_scope": "pull-request-integration-check",
            "main_measurements": {key: measured[key] for key in
                                  ("run_id", "attempt", "source", "measure_check_run_id")}}


def check(candidate, evidence, approval):
    require(evidence.get("schema") == "lastdb.run-v2-ci-evidence.v2"
            and evidence.get("profile") == PROFILE
            and evidence.get("source_git_oid") == approval["source_git_oid"]
            and evidence.get("accepted_main_commit") == approval["accepted_main_commit"]
            and evidence.get("accepted_tree") == approval["accepted_tree"],
            "The approved versioned RunV2 evidence identity differs")
    require(approval["baseline_source_git_oid"] == BASELINE
            and approval["baseline_programs_sha256"] == BASELINE_PROGRAMS,
            "The closed RunV2 baseline program pair differs")
    proofs = {name: digest(evidence[name]) for name in (
        "artifact_receipt_sha256", "development_sha256", "baseline_reopen_sha256",
        "compatibility_sha256", "acceptance_delta_sha256", "acceptance_review_sha256")}
    require(approval.get("proofs") == proofs, "The approval binds another original proof or source review")
    source = compatibility(evidence)
    release_proof = release(candidate, evidence, approval)
    dev = development(candidate, evidence)
    return {"profile": PROFILE, "compatibility": source, "release": release_proof,
            "development": dev, "checked_at": int(time.time())}
