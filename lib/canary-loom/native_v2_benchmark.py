"""Bind real main measurements and the additional exact native5 CI comparison."""

from datetime import datetime, timezone
import re

from native_upgrade_common import require
from native_v2_baseline import SOURCE as BASELINE
from native_v2_benchmark_archive import verify as verify_archives

MEASURE = "Reads, durable writes, and concurrency (advisory)"
STEPS = (
    "Build the exact candidate from fresh source", "Prepare the verified baseline",
    "Measure alternating baseline and candidate pairs",
    "Measure disk and memory growth in fresh generated homes",
    "Publish benchmark summary", "Publish advisory disk and memory growth summary",
    "Upload measurements and build receipts", "Verify upload and record its download receipt",
    "Retain the compact download receipt",
)


def positive(value):
    return type(value) is int and 0 < value < 2**63


def success(value):
    return value.get("status") == "completed" and value.get("conclusion") == "success"


def unexpired(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:.]{8,18}Z", value),
            "The benchmark artifact expiration is invalid")
    return datetime.fromisoformat(value.removesuffix("Z") + "+00:00") > datetime.now(timezone.utc)


def job(page, name, run_id, source):
    matches = [row for row in page if row.get("name") in name]
    require(len(matches) == 1 and success(matches[0]) and matches[0].get("run_id") == run_id
            and matches[0].get("head_sha") == source, "The exact benchmark job did not succeed")
    return matches[0]


def check_id(value):
    match = re.fullmatch(r"https://api\.github\.com/repos/EdgeVector/lastdb/check-runs/([1-9][0-9]{0,18})",
                         value.get("check_run_url", ""))
    require(match is not None, "Benchmark job authority differs from the fixed repository")
    return int(match[1])


def run(read, run_id, source, manual, accepted_check=None):
    require(positive(run_id), "An exact benchmark workflow run is required")
    value = read("/actions/runs/" + str(run_id))
    workflow = ".github/workflows/bench-compare.yml" if manual else ".github/workflows/bench.yml"
    require(value.get("id") == run_id and value.get("head_sha") == source and success(value)
            and value.get("path") == workflow and value.get("event") == ("workflow_dispatch" if manual else "push")
            and (manual or value.get("head_branch") == "main")
            and value.get("repository", {}).get("full_name") == "EdgeVector/lastdb"
            and positive(value.get("run_attempt")), "The exact benchmark workflow identity differs")
    attempt = value["run_attempt"]
    prefix = "/actions/runs/" + str(run_id)
    page = read(prefix + "/attempts/" + str(attempt) + "/jobs?per_page=100")
    rows = page.get("jobs", [])
    require(isinstance(rows, list) and all(isinstance(row, dict) for row in rows)
            and type(page.get("total_count")) is int and page["total_count"] == len(rows) <= 100,
            "Benchmark job enumeration is incomplete")
    job(rows, {"plan"}, run_id, source)
    role = "comparison" if manual else "benchmark"
    measurement = job(rows, {MEASURE, role + " / " + MEASURE}, run_id, source)
    check_id(measurement)
    steps = measurement.get("steps", [])
    require(isinstance(steps, list) and len(steps) <= 100 and all(isinstance(row, dict) for row in steps),
            "Benchmark steps are incomplete")
    for name in STEPS:
        matches = [row for row in steps if row.get("name") == name]
        require(len(matches) == 1 and success(matches[0]), "A required benchmark or upload step did not succeed")
    if not manual:
        complete = job(rows, {"benchmark-complete"}, run_id, source)
        require(check_id(complete) == accepted_check, "The accepted main check belongs to another benchmark run")
    artifacts = read(prefix + "/artifacts?per_page=100")
    entries = artifacts.get("artifacts", [])
    require(isinstance(entries, list) and all(isinstance(row, dict) for row in entries)
            and type(artifacts.get("total_count")) is int and artifacts["total_count"] == len(entries) <= 100,
            "Benchmark artifact enumeration is incomplete")
    selected = {}
    for label, stem in (("measurements", "lastdb-benchmarks-"), ("receipt", "lastdb-benchmark-receipt-")):
        matches = [row for row in entries if row.get("name") == stem + str(run_id) + "-" + str(attempt)]
        require(len(matches) == 1, "An exact-attempt benchmark artifact is absent or duplicated")
        row = matches[0]
        require(positive(row.get("id")) and positive(row.get("size_in_bytes")) and row.get("expired") is False
                and unexpired(row.get("expires_at"))
                and re.fullmatch(r"sha256:[0-9a-f]{64}", row.get("digest", "")) is not None
                and row.get("workflow_run", {}).get("id") == run_id
                and row.get("workflow_run", {}).get("head_sha") == source,
                "Benchmark artifact source, checksum or live state differs")
        selected[label] = row
    return {"run_id": run_id, "attempt": attempt, "source": source,
            "measure_check_run_id": check_id(measurement), "artifacts": selected}


def verify(read, evidence, accepted):
    main = run(read, evidence.get("accepted_main_benchmark_run"), evidence["accepted_main_commit"],
               False, accepted["check_run_ids"]["benchmark-complete"])
    candidate = run(read, evidence.get("candidate_benchmark_run"), evidence["source_git_oid"], True)
    archive = verify_archives(evidence, candidate, BASELINE)
    def summary(value):
        return {key: value[key] for key in ("run_id", "attempt", "source", "measure_check_run_id")} | {
            "artifacts": {name: {key: row[key] for key in ("id", "digest", "size_in_bytes", "expires_at")}
                          for name, row in value["artifacts"].items()}}
    return {"accepted_main": summary(main), "candidate": summary(candidate), "comparison": archive}
