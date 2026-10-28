"""Make and verify a real V2 snapshot after shutdown, before pair selection."""
import json
import os
from pathlib import Path
import uuid

from native_upgrade_common import require, run, sha, stopped, save
from native_v2_primary import record
from native_run_v2_inputs import reference, uint
from native_run_v2_recovery import local, selected
from native_run_v2_final_manifest import decimal, retain, verify


def request_id(approval):
    value = approval.get("final_backup")
    require(isinstance(value, dict) and set(value) == {"request_id"},
            "The final stopped backup needs one immutable request")
    request = value["request_id"]
    parsed = uuid.UUID(request)
    require(str(parsed) == request and parsed.version == 4,
            "The final stopped backup needs a canonical manual UUID")
    require(request != approval["recovery"]["accepted_backup"]["begin"]["job"]["commit_id"],
            "The final backup cannot reuse the earlier live snapshot request")
    return request


def report_check(approval, state, report):
    accepted = report["accepted_backup"]
    previous = approval["recovery"]["accepted_backup"]
    identity = state["last_stopped_session"]
    require(report.get("version") == 1 and report.get("request") == {
        "request_id": request_id(approval), "account_id": approval["recovery"]["account_id"],
        "stopped_pid": identity["pid"], "stopped_start_ts": identity["start_ts"]},
        "The final backup belongs to another request, account, or stopped session")
    require(accepted.get("version") == 2 and accepted["begin"].get("version") == 2
            and accepted["begin"].get("descriptor") is None
            and accepted["begin"].get("required_destinations") == ["r2", "b2"]
            and accepted["begin"]["job"]["stream"] == previous["begin"]["job"]["stream"]
            and accepted["begin"]["job"]["commit_id"] == request_id(approval)
            and accepted["begin"].get("predecessor") == {
                "commit_id": previous["begin"]["job"]["commit_id"],
                "commit_sha256": previous["commit_sha256"], "ordinal": previous["ordinal"]}
            and decimal(accepted["ordinal"]) == decimal(previous["ordinal"]) + 1,
            "The final accepted backup is not the exact next V2 snapshot")
    require(all(report.get(k) is True for k in (
        "all_remote_file_hashes_verified", "source_released", "native_cut_unchanged"))
        and report.get("automatic_backup_enabled") is False
        and uint(report.get("verified_remote_objects"), True) ==
        decimal(accepted["inventory_root"]["object_count"]) +
        decimal(accepted["inventory_root"]["page_count"]) + 1,
        "The final backup lacks full provider readback or clean source release")
    core = selected({**approval, "recovery": {**approval["recovery"], "accepted_backup": accepted}})
    require(core["run"] == report["run_profile"] and core["native_files"] == report["native_files"]
            and core["native_bytes"] == report["native_bytes"], "The final accepted native cut differs")
    for label in ("main", "cas"):
        before, after = state["recovery_point"]["profile"][label], report["run_profile"][label]
        require(before["home_id"] == after["home_id"]
                and before["descriptor_sha256"] == after["descriptor_sha256"]
                and decimal(after["frontier"]) >= decimal(before["frontier"])
                and decimal(after["generation"]) >= decimal(before["generation"]),
                "The final native home identity or counters moved backwards")


def complete(approval, state, path):
    home = Path(approval["primary_home"])
    identity = state["last_stopped_session"]
    require(stopped(home, identity) == state["stop_proof"], "The final backup requires the exact clean stop")
    request = request_id(approval)
    job = home / "data/cloud-byte-backup-v2/jobs" / request
    stored = job / "stopped-report.json"
    program = Path(state["candidate_directory"]) / "lastdb"
    require(sha(program) == approval["candidate"]["lastdb"]["sha256"],
            "The final backup CLI differs from the exact CI candidate")
    if not stored.exists():
        record(path, state, state["phase"], final_backup_requested=request)
        env = {k: v for k, v in os.environ.items() if not k.startswith(
            ("LASTDB_", "FOLD", "AWS_", "B2_", "CF_", "CLOUDFLARE_", "DYLD_", "LD_"))
            and k not in ("EXEMEM_API_URL", "EXEMEM_ENV", "ENVIRONMENT")}
        result = run([program, "--data-dir", home, "cloud", "backup-v2", "start-stopped",
                      "--request-id", request, "--expected-user-hash", approval["recovery"]["account_id"],
                      "--stopped-pid", str(identity["pid"]), "--stopped-start-ts", str(identity["start_ts"]),
                      "--json"], timeout=3600, env=env)
        require(len(result.stdout.encode()) <= 262144, "The final backup reply exceeds its bound")
        value = json.loads(result.stdout)
        if value.get("ok") is True:
            value = value["data"]
        require(value == local(stored), "The final command reply differs from its retained result")
    report = local(stored)
    report_check(approval, state, report)
    manifest_ref = retain(job, path.parent)
    proof = verify(approval, state, report, reference(manifest_ref, 32 * 1024 * 1024))
    require(stopped(home, identity) == state["stop_proof"], "The final stopped session changed")
    saved = path.parent / "final-stopped-report.json"
    if saved.exists():
        require(reference({"path": str(saved), "sha256": sha(saved)}) == report,
                "The retained final backup report differs")
    else:
        save(saved, report)
    record(path, state, state["phase"], final_backup={"report": {"path": str(saved), "sha256": sha(saved)},
                                                   "manifest": manifest_ref, "stopped_files": proof})
