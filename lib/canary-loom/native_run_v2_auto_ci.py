"""Read exact accepted-source CI and the separate Linux DEV operation provenance."""

import re
import time

from native_upgrade_common import require
from native_run_v2_final_ci import source_ci
from native_run_v2_gate import required_ci
from native_run_v2_maintenance_bench import run as benchmarks
from native_run_v2_auto_source import SOURCE
from native_v2_public import ROUTES
from native_v2_release import accepted_release, command_json

LINUX_DEV_RUN = 40816027476


class Metadata:
    """Fixed read-only routes, one finite request budget, and repeat-read reuse."""

    def __init__(self):
        self.cache, self.deadline = {}, time.monotonic() + 240

    def __call__(self, path):
        require(isinstance(path, str) and any(re.fullmatch(pattern, path) for pattern in ROUTES),
                "Format4 provenance refuses an unknown repository route")
        require(time.monotonic() < self.deadline, "Format4 provenance exceeded its request deadline")
        if path not in self.cache:
            require(len(self.cache) < 32, "Format4 provenance exceeded its request count")
            value = command_json(["gh", "api", "repos/EdgeVector/lastdb" + path])
            require(time.monotonic() < self.deadline and isinstance(value, dict),
                    "Format4 provenance exceeded its deadline or returned a non-object")
            self.cache[path] = value
        return self.cache[path]


def steps(job, names):
    rows = job.get("steps", [])
    require(isinstance(rows, list) and len(rows) <= 100, "The Linux DEV step set exceeds its bound")
    for name in names:
        found = [row for row in rows if row.get("name") == name]
        require(len(found) == 1 and found[0].get("status") == "completed"
                and found[0].get("conclusion") == "success", "A required Linux DEV operation step did not succeed")


def linux_development(read_metadata):
    value = read_metadata("/actions/runs/" + str(LINUX_DEV_RUN))
    require(value.get("id") == LINUX_DEV_RUN and value.get("head_sha") == SOURCE
            and value.get("path") == ".github/workflows/cloud-backup-recovery.yml"
            and value.get("event") == "push" and value.get("head_branch") == "main"
            and value.get("repository", {}).get("full_name") == "EdgeVector/lastdb"
            and value.get("status") == "completed" and value.get("conclusion") == "success",
            "The exact accepted-source Linux DEV operation did not succeed")
    page = read_metadata("/actions/runs/" + str(LINUX_DEV_RUN) + "/jobs?per_page=100")
    jobs = page.get("jobs", [])
    require(type(page.get("total_count")) is int and page["total_count"] == len(jobs) <= 100,
            "The Linux DEV job set is incomplete")
    found = [job for job in jobs if job.get("name") == "Automatic DEV backup and recovery"]
    require(len(found) == 1 and found[0].get("run_id") == LINUX_DEV_RUN
            and found[0].get("head_sha") == SOURCE and found[0].get("status") == "completed"
            and found[0].get("conclusion") == "success", "The real Linux DEV job did not succeed")
    steps(found[0], ("Build the exact accepted client", "Package the exact client",
                    "Retain the verified client package",
                    "Run automatic snapshots, mutation logs, restart and both recoveries",
                    "Retain successful CI stream ownership", "Record CI ownership provenance"))
    return {"source": SOURCE, "run_id": LINUX_DEV_RUN, "job_id": found[0]["id"],
            "platform": "linux", "same_mac_programs": False, "real_automatic_backup_and_recovery": True}


def check(evidence, metadata):
    require(evidence.get("source_git_oid") == SOURCE and evidence.get("accepted_main_commit") == SOURCE
            and evidence.get("linux_dev_run") == LINUX_DEV_RUN,
            "The format4 CI evidence names another candidate or DEV run")
    release = accepted_release(evidence, metadata)
    require(release["method"] == "identical_accepted_tree", "The candidate is not its exact accepted main tree")
    checked = source_ci(metadata, evidence)
    required = required_ci(metadata, evidence, checked)
    measured = benchmarks(metadata, evidence["accepted_main_benchmark_run"], SOURCE, False,
                           checked["check_run_ids"]["benchmark-complete"])
    development = linux_development(metadata)
    return {"release": release, "source_ci": checked, "required_ci": required,
            "measurements": measured, "linux_development": development}
