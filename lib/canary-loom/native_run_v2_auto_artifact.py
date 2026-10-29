"""Bind the dispatched normal Mini workflow and its exact selected source pair."""

from native_upgrade_common import require
from native_run_v2_inputs import digest, read, uint
from native_v2_benchmark import unexpired
from native_v2_release import git
from native_run_v2_auto_archive import verify as verify_archive
from native_run_v2_auto_source import SOURCE

RUN = 40819457325
WORKFLOW_SOURCE = "ba1655071f4f19d67ef1f9c0cd151e7626e17eed"
WORKFLOW_PATH = ".github/workflows/mini-upgrade-artifact.yml"
WORKFLOW_BLOB = "314ac84e6463d4d72b86109d91d2e8eab2c7af20"
NAME = "lastdb-mini-" + SOURCE + "-aarch64-apple-darwin"


def workflow(read_metadata, repo):
    value = read_metadata("/actions/runs/" + str(RUN))
    require(value.get("id") == RUN and value.get("head_sha") == WORKFLOW_SOURCE
            and value.get("event") == "workflow_dispatch" and value.get("path") == WORKFLOW_PATH
            and value.get("head_branch") == "main" and value.get("status") == "completed"
            and value.get("conclusion") == "success"
            and value.get("repository", {}).get("full_name") == "EdgeVector/lastdb",
            "The exact normal Mini workflow did not complete successfully")
    require(git(repo, "rev-parse", WORKFLOW_SOURCE + ":" + WORKFLOW_PATH).decode().strip() == WORKFLOW_BLOB
            and git(repo, "rev-parse", SOURCE + ":" + WORKFLOW_PATH).decode().strip() == WORKFLOW_BLOB,
            "The normal Mini workflow differs from its reviewed accepted source")
    commit = read_metadata("/commits/" + WORKFLOW_SOURCE)
    relation = read_metadata("/compare/" + WORKFLOW_SOURCE + "...main?per_page=1")
    require(commit.get("sha") == WORKFLOW_SOURCE and commit["commit"]["tree"]["sha"]
            == git(repo, "rev-parse", WORKFLOW_SOURCE + "^{tree}").decode().strip()
            and relation.get("status") in ("ahead", "identical")
            and relation["merge_base_commit"]["sha"] == WORKFLOW_SOURCE,
            "The Mini workflow source is not the exact accepted main tree")
    page = read_metadata("/actions/runs/" + str(RUN) + "/jobs?per_page=100")
    jobs = page.get("jobs", [])
    require(type(page.get("total_count")) is int and page["total_count"] == len(jobs) <= 100,
            "The Mini workflow job set is incomplete")
    found = [job for job in jobs if job.get("name") == "Matched macOS release pair"]
    require(len(found) == 1 and found[0].get("run_id") == RUN
            and found[0].get("head_sha") == WORKFLOW_SOURCE and found[0].get("status") == "completed"
            and found[0].get("conclusion") == "success", "The Mini release job did not succeed")
    return value


def check(candidate, evidence, metadata):
    require(evidence["source_git_oid"] == SOURCE, "The normal Mini gate has another candidate source")
    run = workflow(metadata, evidence["source_repository"])
    receipt = read(evidence["artifact_receipt"], 65536, digest(evidence["artifact_receipt_sha256"]))
    artifact_id = uint(receipt.get("artifact_id"), True)
    require(receipt.get("schema") == "lastdb.private-candidate-verification.v1"
            and receipt.get("source_git_oid") == SOURCE and receipt.get("workflow_run") == RUN
            and receipt.get("workflow_head") == WORKFLOW_SOURCE
            and receipt.get("run_attempt") == uint(run.get("run_attempt"), True),
            "The original Mini verification receipt names another source or workflow")
    binaries = receipt.get("binaries")
    require(isinstance(binaries, list) and len(binaries) == 2
            and {value.get("name") for value in binaries} == {"lastdb", "lastdbd"}
            and all(value.get("sha256") == candidate[value["name"]]["sha256"]
                    and value.get("version") == candidate[value["name"]]["version"]
                    and value.get("architecture") == "arm64" and value.get("strict_codesign") is True
                    for value in binaries) and receipt.get("target") == "aarch64-apple-darwin",
            "The original Mini verification receipt does not bind the exact signed arm64 pair")
    value = metadata("/actions/artifacts/" + str(artifact_id))
    require(value.get("id") == artifact_id and value.get("name") == NAME
            and value.get("expired") is False and unexpired(value.get("expires_at"))
            and value.get("workflow_run", {}).get("id") == RUN
            and value["workflow_run"].get("head_sha") == WORKFLOW_SOURCE,
            "The original Mini artifact identity, workflow source, or expiry differs")
    checksum = value.get("digest", "")
    require(isinstance(checksum, str) and checksum.startswith("sha256:")
            and digest(checksum.removeprefix("sha256:")) == receipt.get("artifact_zip_sha256")
            and value.get("size_in_bytes") == receipt.get("artifact_bytes")
            and value.get("expires_at") == receipt.get("expires_at"),
            "The Mini artifact digest differs from the original verification receipt")
    archive = verify_archive(evidence["artifact_archive"], SOURCE, candidate,
                             checksum.removeprefix("sha256:"), uint(value.get("size_in_bytes"), True))
    require(archive["package_sha256"] == receipt.get("tarball_sha256")
            and archive["manifest_sha256"] == receipt.get("manifest_sha256"),
            "The original Mini verification receipt names another package or manifest")
    return {"source": SOURCE, "workflow_source": WORKFLOW_SOURCE, "workflow_blob": WORKFLOW_BLOB,
            "run_id": RUN, "attempt": uint(run.get("run_attempt"), True), "artifact_id": artifact_id,
            "github_archive_sha256": checksum, "expires_at": value["expires_at"], **archive}
