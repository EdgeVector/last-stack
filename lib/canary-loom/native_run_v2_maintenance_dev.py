"""Verify retained exact-client automatic DEV operations and ordinary reads."""
from pathlib import Path
import time
from native_upgrade_common import alive, require, sha
from native_run_v2_inputs import read, reference, uint
from native_run_v2_maintenance_source import BASELINE, BASELINE_PROGRAMS


def check(candidate, evidence):
    proof = read(evidence["development_proof"], 262144, evidence["development_sha256"])
    require(proof.get("schema") == "lastdb.run-v2-automatic-development.v1"
            and proof.get("environment") == "dev" and proof.get("source") == evidence["source_git_oid"]
            and proof.get("programs") == {k: v["sha256"] for k, v in candidate.items()}
            and proof.get("baseline_source") == BASELINE and proof.get("baseline_programs") == BASELINE_PROGRAMS
            and 0 <= time.time() - uint(proof.get("completed_at"), True) <= 3600,
            "The exact-client DEV operation is absent, stale, or from another pair")
    summary = reference(proof["summary"])
    required = ("initial_automatic_snapshot", "same_cut_automatic_restart", "separate_later_snapshot",
                "source_free_restore", "baseline_ordinary_reopen", "exact_keyed_values_and_deletes")
    require(summary.get("source") == evidence["source_git_oid"]
            and summary.get("primary_access") is False and all(summary.get(k) is True for k in required)
            and summary.get("automatic_log_checkpoints", 0) >= 2 and summary.get("restored_boots") == 2,
            "The automatic snapshot/log/restart/restore operation is incomplete")
    homes = Path(summary["homes"])
    require(homes.resolve() == homes and homes != Path.home() / ".lastdb"
            and (Path.home() / ".lastdb") not in homes.parents,
            "The DEV operation overlaps the primary")
    for label in ("candidate-reads-baseline-data", "source-after-two-logs", "baseline-reopens-candidate-data",
                  "restored-first", "restored-second"):
        receipt = reference(proof["reads"][label])
        expected = (16, 0) if label == "candidate-reads-baseline-data" else (14, 2)
        require((receipt.get("existing_records"), receipt.get("absent_records")) == expected
                and receipt.get("exact_keyed_values") is True and receipt.get("full_file_bytes_equal") is True,
                "An ordinary exact keyed-read or complete file-byte operation is incomplete")
    before, after = reference(proof["before_log_restart"]), reference(proof["after_log_restart"])
    require(before["request_id"] == after["request_id"]
            and before["frozen_sha256"] == after["frozen_sha256"]
            and after.get("same_cut_automatic_resume") is True,
            "The interrupted log changed its native range or transfer identities")
    restore = reference(proof["restore"])
    require(restore["commit_sha256"] == summary["accepted_backup"]["commit_sha256"]
            and restore.get("file_dependencies_verified") is True
            and uint(restore.get("verified_atoms"), True) > 0,
            "The selected immutable log chain did not restore completely")
    for stop in proof["stops"]:
        value = reference(stop)
        require(value.get("flush_ok") is True and value.get("exit") == "clean"
                and not alive(uint(value["pid"], True)), "A DEV consumer lacks its clean stop")
    provider = reference(proof["provider_accounting"])
    require(provider.get("source") == evidence["source_git_oid"] and provider.get("environment") == "dev"
            and provider.get("all_transfers_verified") is True and provider.get("routes_verified") is True
            and provider.get("native_bytes_unchanged") is True and provider.get("reservations") == 0,
            "The final exact-client provider and account check is incomplete")
    return {"source": summary["source"], "restored_boots": 2, "records": 14, "absent_records": 2,
            "file_bytes": [item["bytes"] for item in summary["full_CAS_file_bytes"]]}
