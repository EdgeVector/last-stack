"""Require all current split CI measurement jobs and their verified upload receipts."""
import re
from native_upgrade_common import require
from native_v2_benchmark import job, check_id, positive, success, unexpired

LANES = {
    "speed": ("Measure alternating baseline and candidate pairs", "Publish benchmark summary"),
    "disk": ("Measure v2 disk size against logical record or record bytes", "Require the single-pass v2 disk size limit and publish the summary"),
    "growth": ("Measure disk and memory growth in fresh generated homes", "Publish advisory disk and memory growth summary"),
}
UPLOAD = ("Upload measurements and build receipts", "Verify upload and record its download receipt",
          "Retain the compact download receipt")


def steps(value, names):
    rows = value.get("steps", [])
    require(isinstance(rows, list) and len(rows) <= 100, "The measurement steps exceed their bound")
    for name in names:
        found = [row for row in rows if row.get("name") == name]
        require(len(found) == 1 and success(found[0]), "A required measurement or upload step failed: " + name)


def run(read, run_id, source, manual, accepted_check):
    require(manual is False and positive(run_id), "Ordinary maintenance requires its actual accepted main measurements")
    value = read("/actions/runs/" + str(run_id))
    require(value.get("id") == run_id and value.get("head_sha") == source and success(value)
            and value.get("path") == ".github/workflows/bench.yml" and value.get("event") == "push"
            and value.get("head_branch") == "main"
            and value.get("repository", {}).get("full_name") == "EdgeVector/lastdb"
            and positive(value.get("run_attempt")), "The accepted benchmark workflow differs")
    attempt = value["run_attempt"]
    prefix = "/actions/runs/" + str(run_id)
    page = read(prefix + "/attempts/" + str(attempt) + "/jobs?per_page=100")
    rows = page.get("jobs", [])
    require(isinstance(rows, list) and type(page.get("total_count")) is int
            and page["total_count"] == len(rows) <= 100, "The accepted benchmark job list is incomplete")
    job(rows, {"plan"}, run_id, source)
    complete = job(rows, {"benchmark-complete"}, run_id, source)
    require(check_id(complete) == accepted_check, "The accepted benchmark-complete check belongs to another run")
    build = job(rows, {"benchmark / build / Build verified benchmark programs once"}, run_id, source)
    steps(build, ("Build the exact candidate from fresh source", "Package the exact programs for independent measurement jobs",
                  "Upload programs and build receipts", "Verify upload and record its download receipt",
                  "Retain the compact download receipt"))
    checked = {"build": check_id(build)}
    for lane, required in LANES.items():
        measurement = job(rows, {"benchmark / " + lane}, run_id, source)
        steps(measurement, ("Verify and unpack the shared programs before measurements", *required, *UPLOAD))
        checked[lane] = check_id(measurement)
    page = read(prefix + "/artifacts?per_page=100")
    artifacts = page.get("artifacts", [])
    require(isinstance(artifacts, list) and type(page.get("total_count")) is int
            and page["total_count"] == len(artifacts) <= 100, "The accepted benchmark artifact list is incomplete")
    stems = ["lastdb-benchmark-build-", "lastdb-benchmark-build-receipt-"]
    stems += [stem + lane + "-" for lane in LANES for stem in ("lastdb-benchmarks-", "lastdb-benchmark-receipt-")]
    selected = {}
    for stem in stems:
        found = [row for row in artifacts if row.get("name") == stem + str(run_id) + "-" + str(attempt)]
        require(len(found) == 1, "A required exact-attempt measurement artifact is absent")
        item = found[0]
        require(positive(item.get("id")) and positive(item.get("size_in_bytes")) and item.get("expired") is False
                and unexpired(item.get("expires_at"))
                and re.fullmatch(r"sha256:[0-9a-f]{64}", item.get("digest", "")) is not None
                and item.get("workflow_run", {}).get("id") == run_id
                and item["workflow_run"].get("head_sha") == source,
                "A benchmark artifact source, checksum, or expiration differs")
        selected[item["name"]] = {k: item[k] for k in ("id", "digest", "size_in_bytes", "expires_at")}
    return {"run_id": run_id, "attempt": attempt, "source": source,
            "measure_check_run_id": checked["speed"], "lane_check_run_ids": checked, "artifacts": selected}
