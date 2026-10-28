"""Exact public required-CI provenance shared by the RunV2 maintenance gates."""

import re

from native_upgrade_common import require
from native_run_v2_inputs import uint


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
