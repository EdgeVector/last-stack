"""Bind the exact source workflow without discarding other successful CI runs."""
import re

from native_upgrade_common import require
from native_run_v2_inputs import uint


def source_ci(read, evidence):
    source = evidence["source_git_oid"]
    page = read("/commits/" + source + "/check-runs?filter=latest&per_page=100")
    rows = page.get("check_runs", [])
    require(isinstance(rows, list) and type(page.get("total_count")) is int
            and page["total_count"] == len(rows) <= 100,
            "Exact source CI check enumeration is incomplete")
    checked = {}
    for name in ("ci-required", "benchmark-complete"):
        matches = [row for row in rows if row.get("name") == name]
        require(0 < len(matches) <= 10 and all(
            row.get("head_sha") == source and row.get("status") == "completed"
            and row.get("conclusion") == "success" and row.get("app", {}).get("slug") == "github-actions"
            for row in matches), "An exact source gate is absent, incomplete, or failed: " + name)
        ids = [uint(row.get("id"), True) for row in matches]
        require(len(set(ids)) == len(ids), "Source CI check identities are duplicated")
        checked[name] = ids
    require(len(checked["benchmark-complete"]) == 1, "The source benchmark gate is ambiguous")
    run = uint(evidence.get("required_ci_run"), True)
    jobs = read("/actions/runs/" + str(run) + "/jobs?per_page=100")
    values = jobs.get("jobs", [])
    require(isinstance(values, list) and type(jobs.get("total_count")) is int
            and jobs["total_count"] == len(values) <= 100, "Exact source workflow jobs are incomplete")
    selected = [job for job in values if job.get("name") == "ci-required"]
    require(len(selected) == 1 and selected[0].get("run_id") == run
            and selected[0].get("head_sha") == source and selected[0].get("status") == "completed"
            and selected[0].get("conclusion") == "success", "The named source workflow did not pass")
    match = re.fullmatch(r"https://api\.github\.com/repos/EdgeVector/lastdb/check-runs/([1-9][0-9]{0,18})",
                         selected[0].get("check_run_url", ""))
    require(match is not None and int(match[1]) in checked["ci-required"],
            "The named source workflow is not an actual successful source check")
    return {"source": source, "check_run_ids": {
        "ci-required": int(match[1]), "benchmark-complete": checked["benchmark-complete"][0]},
        "successful_ci_check_run_ids": sorted(checked["ci-required"])}
