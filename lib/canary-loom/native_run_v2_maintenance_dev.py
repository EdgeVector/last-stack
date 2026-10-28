"""Bind every DEV data read and clean stop to its exact client, home, and session."""
from pathlib import Path
import time
from native_upgrade_common import require
from native_run_v2_dev_session import ended
from native_run_v2_inputs import read, reference, uint, digest
from native_run_v2_maintenance_source import BASELINE, BASELINE_PROGRAMS

BOOTS = ("baseline-source", "source-first", "source-second", "baseline-after-candidate",
         "restored-first", "restored-second")
READS = {"candidate-reads-baseline-data": "source-first", "source-after-two-logs": "source-second",
         "baseline-reopens-candidate-data": "baseline-after-candidate",
         "restored-first": "restored-first", "restored-second": "restored-second"}


def consumers(proof, summary, programs, operation):
    stages = proof.get("consumers")
    require(isinstance(stages, dict) and set(stages) == set(BOOTS), "Every expected DEV consumer needs its original stop")
    owners, sessions = {}, set()
    for name in BOOTS:
        expected = BASELINE_PROGRAMS if name.startswith("baseline-") else programs
        source = BASELINE if name.startswith("baseline-") else summary["source"]
        owner, stop = reference(stages[name]["owner"]), reference(stages[name]["stop"])
        home = str(Path(summary["homes"]) / ("r" if name.startswith("restored-") else "s"))
        identity = {"pid": uint(owner["pid"], True), "start_ts": uint(owner["start_ts"], True)}
        require(owner.get("source") == source and owner.get("programs") == expected
                and owner.get("account") == summary["account"] and owner.get("home") == home
                and owner.get("operation_sha256") == operation and stop.get("owner") == owner,
                "A DEV consumer belongs to another program pair, home, or operation")
        require(stop.get("receipt") == {"version": 1, **identity, "flush_ok": True}
                and stop["receipt"]["flush_ok"] is True and type(stop["receipt"]["version"]) is int
                and all(stop.get("session", {}).get(k) == v for k, v in identity.items())
                and stop["session"].get("exit") == "clean"
                and uint(stop["session"].get("end_ts"), True) >= identity["start_ts"]
                and ended(identity, stop), "A DEV consumer lacks its exact flush receipt and clean session ledger")
        key = (identity["pid"], identity["start_ts"])
        require(key not in sessions, "Two DEV consumers reuse the same session")
        sessions.add(key)
        owners[name] = {**owner, "identity": identity}
    return owners


def data_reads(proof, summary, owners, operation):
    hashes = {}
    require(set(proof.get("reads", {})) == set(READS), "Every expected DEV read needs its original receipt")
    for label, boot in READS.items():
        receipt, owner = reference(proof["reads"][label]), owners[boot]
        initial = label == "candidate-reads-baseline-data"
        require(receipt.get("source") == owner["source"] and receipt.get("programs") == owner["programs"]
                and receipt.get("home") == owner["home"] and receipt.get("session") == owner["identity"]
                and receipt.get("stage") == label and receipt.get("operation_sha256") == operation,
                "A DEV read belongs to another client, stage, home, or session")
        require((receipt.get("existing_records"), receipt.get("absent_records")) == ((16, 0) if initial else (14, 2))
                and receipt.get("exact_keyed_values") is True and receipt.get("full_file_bytes_equal") is True
                and receipt.get("files") == (summary["full_CAS_file_bytes"][:1] if initial else summary["full_CAS_file_bytes"])
                and receipt.get("accepted_commit_sha256") == (None if initial else summary["accepted_backup"]["commit_sha256"]),
                "The DEV values, deletions, files, or selected log backup differ")
        hashes[label] = digest(receipt.get("records_sha256"))
    final = hashes["source-after-two-logs"]
    require(all(value == final for label, value in hashes.items() if label != "candidate-reads-baseline-data")
            and hashes["candidate-reads-baseline-data"] != final,
            "Actual DEV record digests differ across baseline reopen or distinct restored boots")


def memory_guard(proof, summary, programs, operation, limit):
    value = reference(proof["memory_guard"])
    owner = value["owner"]
    identity = {"pid": uint(owner["pid"], True), "start_ts": uint(owner["start_ts"], True)}
    require(value.get("source") == summary["source"] and value.get("programs") == programs
            and value.get("operation_sha256") == operation and owner.get("source") == summary["source"]
            and owner.get("programs") == programs and owner.get("home") == str(Path(summary["homes"]) / "r")
            and owner.get("operation_sha256") == operation and value.get("memory_limit_mb") == limit,
            "The candidate memory observation belongs to another operation or limit")
    failures = value.get("persist_failures", {})
    require(set(failures) == {"persist_lane_failures", "deferred_persist_failed"}
            and all(type(n) is int and n == 0 for n in failures.values())
            and value.get("native_health", {}).get("version") == proof["candidate_version"]
            and owner.get("version") in (None, proof["candidate_version"])
            and value["native_health"].get("native", {}).get("writer_failed") is False,
            "The restored candidate persist or native writer health is absent or failed")
    samples = value.get("samples_bytes")
    require(isinstance(samples, list) and 15 <= len(samples) <= 120
            and all(type(n) is int and 0 < n < limit * 1048576 * 0.9 for n in samples)
            and value.get("peak_bytes") == max(samples) and value.get("settle_seconds", 0) >= 45
            and value.get("observation_seconds", 0) >= 15 and value.get("elapsed_seconds", 0) >= 60,
            "The candidate memory guard or required observation interval did not pass")
    stop, observed = reference(value["stop"]), reference(value["read"])
    require(stop.get("owner") == owner and stop.get("receipt") == {"version":1, **identity, "flush_ok":True}
            and all(stop.get("session", {}).get(k) == v for k,v in identity.items())
            and stop["session"].get("exit") == "clean" and ended(identity, stop)
            and observed.get("session") == identity and observed.get("source") == summary["source"]
            and observed.get("programs") == programs and observed.get("operation_sha256") == operation
            and observed.get("records_sha256") == reference(proof["reads"]["restored-second"])["records_sha256"],
            "The observed candidate lacks its exact data read and native clean stop")


def check(candidate, evidence, memory_limit_mb):
    proof = read(evidence["development_proof"], 262144, evidence["development_sha256"])
    programs = {k: v["sha256"] for k, v in candidate.items()}
    require(proof.get("schema") == "lastdb.run-v2-automatic-development.v1"
            and proof.get("environment") == "dev" and proof.get("source") == evidence["source_git_oid"]
            and proof.get("programs") == programs and proof.get("candidate_version") == candidate["lastdbd"]["version"]
            and proof.get("baseline_source") == BASELINE
            and proof.get("baseline_programs") == BASELINE_PROGRAMS
            and 0 <= time.time() - uint(proof.get("completed_at"), True) <= 3600,
            "The exact-client DEV operation is absent, stale, or from another pair")
    summary, intent = reference(proof["summary"]), reference(proof["intent"])
    operation = digest(proof["intent"]["sha256"])
    require(intent.get("source") == summary.get("source") == evidence["source_git_oid"]
            and intent.get("homes") == summary.get("homes") and intent.get("account") == summary.get("account")
            and intent.get("baseline_source") == BASELINE and intent.get("primary_access") is False,
            "The original DEV intent belongs to another operation")
    required = ("initial_automatic_snapshot", "same_cut_automatic_restart", "separate_later_snapshot",
                "source_free_restore", "baseline_ordinary_reopen", "exact_keyed_values_and_deletes")
    require(summary.get("primary_access") is False and all(summary.get(k) is True for k in required)
            and summary.get("automatic_log_checkpoints", 0) >= 2 and summary.get("restored_boots") == 2,
            "The automatic snapshot/log/restart/restore operation is incomplete")
    homes = Path(summary["homes"])
    primary = Path.home() / ".lastdb"
    require(homes.resolve() == homes and homes != primary and primary not in homes.parents and homes not in primary.parents,
            "The DEV operation overlaps the primary")
    files = summary["full_CAS_file_bytes"]
    require(isinstance(files, list) and len(files) == 2 and all(f.get("bytes") == 8388608 for f in files)
            and len({digest(f.get("sha256")) for f in files}) == 2, "The two full DEV files differ from the operation")
    owners = consumers(proof, summary, programs, operation)
    data_reads(proof, summary, owners, operation)
    memory_guard(proof, summary, programs, operation, memory_limit_mb)
    before, after = reference(proof["before_log_restart"]), reference(proof["after_log_restart"])
    require(before["request_id"] == after["request_id"] and before["frozen_sha256"] == after["frozen_sha256"]
            and after.get("same_cut_automatic_resume") is True, "The interrupted native range or transfer identities changed")
    restore = reference(proof["restore"])
    require(restore["commit_sha256"] == summary["accepted_backup"]["commit_sha256"]
            and restore.get("destination") == str(homes / "r") and restore.get("file_dependencies_verified") is True
            and uint(restore.get("verified_atoms"), True) > 0, "The selected immutable log chain did not restore completely")
    provider = reference(proof["provider_accounting"])
    require(provider.get("source") == evidence["source_git_oid"] and provider.get("environment") == "dev"
            and provider.get("all_transfers_verified") is True and provider.get("routes_verified") is True
            and provider.get("native_bytes_unchanged") is True and provider.get("reservations") == 0,
            "The final exact-client provider and account check is incomplete")
    return {"source": summary["source"], "restored_boots": 2, "records": 14, "absent_records": 2,
            "file_bytes": [item["bytes"] for item in files]}
