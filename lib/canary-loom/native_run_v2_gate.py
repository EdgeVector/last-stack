"""Exact public CI provenance and original operational proof for RunV2."""

import re
import time

from native_upgrade_common import require, sha
from native_v2_benchmark import run as benchmark_run
from native_v2_maintenance import accepted_ci, artifact
from native_v2_public import PublicMetadata
from native_v2_release import accepted_release, git
from native_run_v2_compatibility import BASELINE, BASELINE_PROGRAMS, check as compatibility
from native_run_v2_development import check as development
from native_run_v2_inputs import digest, external, read, uint

PROFILE = "run-v2-ci-bootstrap-v1"
PULL_REQUEST = 434


def required_ci(read_metadata, evidence, checked):
    source, run_id = evidence["source_git_oid"], uint(evidence["required_ci_run"], True)
    run = read_metadata("/actions/runs/" + str(run_id))
    require(run.get("id") == run_id and run.get("head_sha") == source
            and run.get("event") in ("pull_request", "workflow_dispatch", "push")
            and run.get("path") == ".github/workflows/ci-required.yml"
            and run.get("repository", {}).get("full_name") == "EdgeVector/lastdb"
            and run.get("status") == "completed" and run.get("conclusion") == "success",
            "The exact candidate required workflow did not succeed")
    page = read_metadata("/actions/runs/" + str(run_id) + "/jobs?per_page=100")
    rows = page.get("jobs", [])
    require(isinstance(rows, list) and type(page.get("total_count")) is int
            and page["total_count"] == len(rows) <= 100, "Required CI job enumeration is incomplete")
    found = [item for item in rows if item.get("name") == "ci-required"]
    require(len(found) == 1 and found[0].get("run_id") == run_id
            and found[0].get("head_sha") == source and found[0].get("status") == "completed"
            and found[0].get("conclusion") == "success", "The exact required CI job differs")
    match = re.fullmatch(
        r"https://api\.github\.com/repos/EdgeVector/lastdb/check-runs/([1-9][0-9]{0,18})",
        found[0].get("check_run_url", ""))
    require(match is not None and int(match[1]) == checked["check_run_ids"]["ci-required"],
            "The required workflow belongs to another candidate check")
    return {"source": source, "run_id": run_id, "check_run_id": int(match[1])}


def release(candidate, evidence):
    require(evidence.get("github_metadata_transport") == "public_https",
            "RunV2 bootstrap requires bounded credential-free public provenance")
    metadata = PublicMetadata()
    source, accepted = evidence["source_git_oid"], evidence["accepted_main_commit"]
    require(type(evidence.get("accepted_pull_request")) is int
            and evidence["accepted_pull_request"] == PULL_REQUEST,
            "The closed RunV2 release requires its exact merged PR")
    pull = metadata("/pulls/" + str(PULL_REQUEST))
    require(pull.get("merged") is True and pull.get("state") == "closed"
            and pull.get("head", {}).get("sha") == source
            and pull.get("head", {}).get("repo", {}).get("full_name") == "EdgeVector/lastdb"
            and pull.get("base", {}).get("ref") == "main"
            and pull.get("base", {}).get("repo", {}).get("full_name") == "EdgeVector/lastdb"
            and pull.get("merge_commit_sha") == accepted, "The exact artifact PR is not accepted")
    result = accepted_release(evidence, metadata)
    head = metadata("/commits/" + source)
    require(head.get("sha") == source
            and head.get("commit", {}).get("tree", {}).get("sha") == result["artifact_tree"]
            == result["acceptance_tree"], "The squash merge tree differs from the artifact head")
    # A squash merge does not make the PR head an ancestor of main.
    # The baseline relation applies to H, while exact tree equality binds H to M.
    git(evidence["source_repository"], "merge-base", "--is-ancestor", BASELINE, source)
    head_checks, main_checks = accepted_ci(metadata, source), accepted_ci(metadata, accepted)
    ci = required_ci(metadata, evidence, head_checks)
    external(evidence["artifact_archive"])
    receipt = read(evidence["artifact_receipt"], 16384, evidence["artifact_receipt_sha256"])
    require(receipt.get("source") == source, "The original Mac receipt names another source")
    archived = artifact(candidate, evidence, metadata)
    measured = benchmark_run(metadata, evidence.get("accepted_main_benchmark_run"), accepted,
                             False, main_checks["check_run_ids"]["benchmark-complete"])
    return {"acceptance": result, "head_checks": head_checks, "main_checks": main_checks,
            "required_ci": ci, "artifact": archived,
            "main_measurements": {key: measured[key] for key in
                                  ("run_id", "attempt", "source", "measure_check_run_id")}}


def check(candidate, evidence, approval):
    require(evidence.get("schema") == "lastdb.run-v2-ci-evidence.v1"
            and evidence.get("profile") == PROFILE
            and evidence.get("source_git_oid") == approval["source_git_oid"]
            and evidence.get("accepted_main_commit") == approval["accepted_main_commit"]
            and evidence.get("accepted_tree") == approval["accepted_tree"],
            "The approved RunV2 evidence identity differs")
    require(approval["baseline_source_git_oid"] == BASELINE
            and approval["baseline_programs_sha256"] == BASELINE_PROGRAMS,
            "The closed RunV2 baseline program pair differs")
    proofs = {name: digest(evidence[name]) for name in (
        "artifact_receipt_sha256", "development_sha256", "baseline_reopen_sha256",
        "compatibility_sha256")}
    require(approval.get("proofs") == proofs, "The approval binds another original proof")
    source = compatibility(evidence)
    release_proof = release(candidate, evidence)
    require(release_proof["acceptance"]["acceptance_tree"] == approval["accepted_tree"],
            "The approved accepted tree differs")
    dev = development(candidate, evidence)
    return {"profile": PROFILE, "compatibility": source, "release": release_proof,
            "development": dev, "checked_at": int(time.time())}
