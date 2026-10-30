"""Exact accepted CI, Linux DEV, and Mini artifact provenance for one closed route.

The historical format4 profile pins its run identities. A route pins only its
accepted main commit. Each run identity comes from the hashed evidence and must
pass the same GitHub property checks against that pinned commit.
"""

from native_upgrade_common import require
from native_run_v2_auto_archive import verify as verify_archive
from native_run_v2_auto_ci import Metadata, steps
from native_run_v2_final_ci import source_ci
from native_run_v2_gate import required_ci
from native_run_v2_inputs import digest, read, uint
from native_run_v2_maintenance_bench import run as benchmarks
from native_v2_benchmark import unexpired
from native_v2_release import accepted_release, git

LINUX_WORKFLOW = ".github/workflows/cloud-backup-recovery.yml"
MINI_WORKFLOW = ".github/workflows/mini-upgrade-artifact.yml"
RECEIPT = "lastdb.private-candidate-verification.v1"

__all__ = ("Metadata", "check", "artifact")


def linux_development(read_metadata, run_id, source):
    value = read_metadata("/actions/runs/" + str(run_id))
    require(value.get("id") == run_id and value.get("head_sha") == source
            and value.get("path") == LINUX_WORKFLOW
            and value.get("event") == "push" and value.get("head_branch") == "main"
            and value.get("repository", {}).get("full_name") == "EdgeVector/lastdb"
            and value.get("status") == "completed" and value.get("conclusion") == "success",
            "The exact accepted-source Linux DEV operation did not succeed")
    page = read_metadata("/actions/runs/" + str(run_id) + "/jobs?per_page=100")
    jobs = page.get("jobs", [])
    require(type(page.get("total_count")) is int and page["total_count"] == len(jobs) <= 100,
            "The Linux DEV job set is incomplete")
    found = [job for job in jobs if job.get("name") == "Automatic DEV backup and recovery"]
    require(len(found) == 1 and found[0].get("run_id") == run_id
            and found[0].get("head_sha") == source and found[0].get("status") == "completed"
            and found[0].get("conclusion") == "success", "The real Linux DEV job did not succeed")
    steps(found[0], ("Build the exact accepted client", "Package the exact client",
                    "Retain the verified client package",
                    "Run automatic snapshots, mutation logs, restart and both recoveries",
                    "Retain successful CI stream ownership", "Record CI ownership provenance"))
    return {"source": source, "run_id": run_id, "job_id": found[0]["id"],
            "platform": "linux", "same_mac_programs": False, "real_automatic_backup_and_recovery": True}


def check(evidence, metadata, source):
    require(evidence.get("source_git_oid") == evidence.get("accepted_main_commit") == source,
            "The route CI evidence names another candidate")
    release = accepted_release(evidence, metadata)
    require(release["method"] == "identical_accepted_tree", "The candidate is not its exact accepted main tree")
    checked = source_ci(metadata, evidence)
    required = required_ci(metadata, evidence, checked)
    measured = benchmarks(metadata, uint(evidence["accepted_main_benchmark_run"], True), source, False,
                          checked["check_run_ids"]["benchmark-complete"])
    development = linux_development(metadata, uint(evidence["linux_dev_run"], True), source)
    return {"release": release, "source_ci": checked, "required_ci": required,
            "measurements": measured, "linux_development": development}


def workflow(read_metadata, repo, run_id, source):
    value = read_metadata("/actions/runs/" + str(run_id))
    head = value.get("head_sha")
    require(value.get("id") == run_id and isinstance(head, str) and len(head) == 40
            and value.get("event") == "workflow_dispatch" and value.get("path") == MINI_WORKFLOW
            and value.get("head_branch") == "main" and value.get("status") == "completed"
            and value.get("conclusion") == "success"
            and value.get("repository", {}).get("full_name") == "EdgeVector/lastdb",
            "The exact normal Mini workflow did not complete successfully")
    blob = git(repo, "rev-parse", head + ":" + MINI_WORKFLOW).decode().strip()
    require(blob == git(repo, "rev-parse", source + ":" + MINI_WORKFLOW).decode().strip(),
            "The dispatched Mini workflow differs from the reviewed accepted source")
    commit = read_metadata("/commits/" + head)
    relation = read_metadata("/compare/" + head + "...main?per_page=1")
    require(commit.get("sha") == head and commit["commit"]["tree"]["sha"]
            == git(repo, "rev-parse", head + "^{tree}").decode().strip()
            and relation.get("status") in ("ahead", "identical")
            and relation["merge_base_commit"]["sha"] == head,
            "The Mini workflow source is not an exact accepted main tree")
    page = read_metadata("/actions/runs/" + str(run_id) + "/jobs?per_page=100")
    jobs = page.get("jobs", [])
    require(type(page.get("total_count")) is int and page["total_count"] == len(jobs) <= 100,
            "The Mini workflow job set is incomplete")
    found = [job for job in jobs if job.get("name") == "Matched macOS release pair"]
    require(len(found) == 1 and found[0].get("run_id") == run_id
            and found[0].get("head_sha") == head and found[0].get("status") == "completed"
            and found[0].get("conclusion") == "success", "The Mini release job did not succeed")
    return value, head, blob


def artifact(pair, receipt_path, receipt_sha256, archive_path, metadata, repo, source):
    """Bind one verified, unexpired Mini artifact of `source` to the exact `pair`."""
    receipt = read(receipt_path, 65536, digest(receipt_sha256))
    run_id = uint(receipt.get("workflow_run"), True)
    run, head, blob = workflow(metadata, repo, run_id, source)
    artifact_id = uint(receipt.get("artifact_id"), True)
    require(receipt.get("schema") == RECEIPT and receipt.get("source_git_oid") == source
            and receipt.get("workflow_head") == head
            and receipt.get("run_attempt") == uint(run.get("run_attempt"), True),
            "The Mini verification receipt names another source or workflow")
    binaries = receipt.get("binaries")
    require(isinstance(binaries, list) and len(binaries) == 2
            and {value.get("name") for value in binaries} == {"lastdb", "lastdbd"}
            and all(value.get("sha256") == pair[value["name"]]["sha256"]
                    and value.get("version") == pair[value["name"]]["version"]
                    and value.get("architecture") == "arm64" and value.get("strict_codesign") is True
                    for value in binaries) and receipt.get("target") == "aarch64-apple-darwin",
            "The Mini verification receipt does not bind the exact signed arm64 pair")
    value = metadata("/actions/artifacts/" + str(artifact_id))
    require(value.get("id") == artifact_id
            and value.get("name") == "lastdb-mini-" + source + "-aarch64-apple-darwin"
            and value.get("expired") is False and unexpired(value.get("expires_at"))
            and value.get("workflow_run", {}).get("id") == run_id
            and value["workflow_run"].get("head_sha") == head,
            "The Mini artifact identity, workflow source, or expiry differs")
    checksum = value.get("digest", "")
    require(isinstance(checksum, str) and checksum.startswith("sha256:")
            and digest(checksum.removeprefix("sha256:")) == receipt.get("artifact_zip_sha256")
            and value.get("size_in_bytes") == receipt.get("artifact_bytes")
            and value.get("expires_at") == receipt.get("expires_at"),
            "The Mini artifact digest differs from its verification receipt")
    archive = verify_archive(archive_path, source, pair, checksum.removeprefix("sha256:"),
                             uint(value.get("size_in_bytes"), True))
    require(archive["package_sha256"] == receipt.get("tarball_sha256")
            and archive["manifest_sha256"] == receipt.get("manifest_sha256"),
            "The Mini verification receipt names another package or manifest")
    return {"source": source, "workflow_source": head, "workflow_blob": blob,
            "run_id": run_id, "attempt": uint(run.get("run_attempt"), True), "artifact_id": artifact_id,
            "github_archive_sha256": checksum, "expires_at": value["expires_at"], **archive}


def receipt_pair(receipt_path, receipt_sha256, programs):
    """Read the exact pair versions from a receipt whose hashes equal `programs`."""
    receipt = read(receipt_path, 65536, digest(receipt_sha256))
    binaries = receipt.get("binaries")
    require(isinstance(binaries, list) and len(binaries) == 2
            and {value.get("name") for value in binaries} == {"lastdb", "lastdbd"}
            and {value["name"]: value.get("sha256") for value in binaries} == programs
            and all(isinstance(value.get("version"), str) and value["version"] for value in binaries),
            "The baseline Mini receipt does not name the exact installed pair")
    return {value["name"]: {"sha256": value["sha256"], "version": value["version"]} for value in binaries}
