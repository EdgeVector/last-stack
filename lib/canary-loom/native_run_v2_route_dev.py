"""Exact Mac DEV proofs for one closed route: main operation, stopped cut, activation."""

import hashlib
import json
from pathlib import Path
import time

from native_upgrade_common import require
from native_run_v2_auto_dev import data_reads, memory_guard, restart
from native_run_v2_auto_dev_continuation import expected_operation
from native_run_v2_auto_dev_restore import check as restored_closures
from native_run_v2_auto_stopped_dev import BUDGET, adoption, native_source, restored, source_identity
from native_run_v2_auto_writer_policy import development as writer_policy
from native_run_v2_dev_session import ended
from native_run_v2_final_manifest import decimal
from native_run_v2_inputs import digest, read, reference, uint, unwrap
from native_run_v2_routes import FORMAT4, FORMAT6, PROTOCOL, RUN_PROFILE
from native_v2_release import git

BOOTS = ("baseline-source", "source-first", "source-second", "baseline-after-candidate",
         "restored-first", "restored-second", "base-restored-first", "base-restored-second",
         "later-restored-first", "later-restored-second")
MAIN = "lastdb.run-v2-automatic-development.v2"
STOPPED = "lastdb.run-v2-route-stopped-development.v1"
ACTIVATION = "lastdb.run-v2-route-activation-development.v1"
FILES = "lastdb.native-file-list.v1"
ACTIVATED = {"previous_format": 4, "current_format": 6, "changed": True, "encrypted_files_unchanged": True}


def home_name(label):
    if label.startswith("base-restored-"):
        return "b"
    if label.startswith("later-restored-"):
        return "t"
    return "r" if label.startswith("restored-") else "s"


def consumers(proof, summary, programs, baseline, operation):
    stages = proof.get("consumers")
    require(isinstance(stages, dict) and set(stages) == set(BOOTS), "Every expected DEV consumer needs its original stop")
    owners, sessions = {}, set()
    for name in BOOTS:
        old = name.startswith("baseline-")
        expected = baseline["programs"] if old else programs
        source = baseline["source"] if old else summary["source"]
        owner, stop = reference(stages[name]["owner"]), reference(stages[name]["stop"])
        home = str(Path(summary["homes"]) / home_name(name))
        identity = {"pid": uint(owner["pid"], True), "start_ts": uint(owner["start_ts"], True)}
        require(owner.get("source") == source and owner.get("programs") == expected
                and owner.get("account") == summary["account"] and owner.get("home") == home
                and owner.get("operation_sha256") == expected_operation(operation, name) and stop.get("owner") == owner,
                "A DEV consumer belongs to another program pair, home, or operation")
        require(stop.get("receipt") == {"version": 1, **identity, "flush_ok": True}
                and all(stop.get("session", {}).get(k) == v for k, v in identity.items())
                and stop["session"].get("exit") == "clean"
                and uint(stop["session"].get("end_ts"), True) >= identity["start_ts"]
                and ended(identity, stop), "A DEV consumer lacks its exact flush receipt and clean session ledger")
        key = (identity["pid"], identity["start_ts"])
        require(key not in sessions, "Two DEV consumers reuse the same session")
        sessions.add(key)
        owners[name] = {**owner, "identity": identity}
    return owners


def main(candidate, evidence, memory_limit_mb, writer, dev, baseline_programs, *, maximum_age_seconds=86400):
    """The exact old and new pair on fresh DEV data; `dev` is the qualified route."""
    require(type(maximum_age_seconds) is int and 0 < maximum_age_seconds <= 86400,
            "The exact-client DEV proof age policy differs")
    proof = read(evidence["development_proof"], 262144, digest(evidence["development_sha256"]))
    programs = {k: v["sha256"] for k, v in candidate.items()}
    require(proof.get("schema") == MAIN and proof.get("profile") == dev["profile"]
            and proof.get("protocol") == int(PROTOCOL)
            and proof.get("environment") == "dev" and proof.get("source") == dev["source"]
            and evidence["source_git_oid"] == dev["source"]
            and proof.get("programs") == programs and proof.get("candidate_version") == candidate["lastdbd"]["version"]
            and proof.get("baseline_source") == dev["baseline"]
            and proof.get("baseline_programs") == baseline_programs
            and 0 <= time.time() - uint(proof.get("completed_at"), True) <= maximum_age_seconds,
            "The exact-client DEV operation is absent, stale, or from another pair")
    summary, intent = reference(proof["summary"]), reference(proof["intent"])
    writer_policy(writer["result"], intent, summary)
    operation = digest(proof["intent"]["sha256"])
    require(intent.get("source") == summary.get("source") == dev["source"]
            and intent.get("profile") == dev["profile"]
            and intent.get("homes") == summary.get("homes") and intent.get("account") == summary.get("account")
            and intent.get("programs") == programs and intent.get("baseline_programs") == baseline_programs
            and intent.get("baseline_source") == dev["baseline"] and intent.get("primary_access") is False,
            "The original DEV intent belongs to another operation")
    required = ("initial_automatic_snapshot", "automatic_policy_survives_restart", "separate_later_snapshot",
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
            and len({digest(f.get("sha256")) for f in files}) == 2
            and all(set(item) == {"bytes", "sha256", "pointer"}
                    and set(item["pointer"]) == {"path", "sha256"}
                    and digest(item["pointer"]["sha256"]) for item in files),
            "The two full DEV files or their original private pointer references differ")
    baseline = {"source": dev["baseline"], "programs": baseline_programs}
    owners = consumers(proof, summary, programs, baseline, operation)
    data_reads(proof, summary, owners, operation)
    memory_guard(proof, summary, programs, operation, memory_limit_mb)
    before, after = reference(proof["before_log_restart"]), reference(proof["after_log_restart"])
    restart(before, after, summary)
    restore = unwrap(reference(proof["restore"]))
    require(restore["commit_sha256"] == summary["accepted_backup"]["commit_sha256"]
            and restore.get("destination") == str(homes / "r") and restore.get("file_dependencies_verified") is True
            and uint(restore.get("verified_atoms"), True) > 0, "The selected immutable log chain did not restore completely")
    provider = reference(proof["provider_accounting"])
    require(provider.get("source") == dev["source"] and provider.get("environment") == "dev"
            and provider.get("scope") == "selected-accepted-closures"
            and provider.get("all_selected_object_hashes_verified") is True
            and provider.get("routes_verified") is True and provider.get("whole_account_reconciled") is False
            and provider.get("provider_deletions") == 0,
            "The final exact-client provider and account check is incomplete")
    configured = json.loads(git(evidence["source_repository"], "show", dev["source"] + ":folddb_profile/environments.json"))
    endpoint = configured["environments"]["dev"]["exemem_api"] + "/api/cloud/backups/v2/"
    closure_proof = restored_closures(proof, summary, endpoint, owners, dev["marker"])
    require(proof.get("baseline_ordinary_reopen", summary.get("baseline_ordinary_reopen")) is True,
            "The actual baseline did not reopen ordinary candidate-written DEV data")
    return {"source": summary["source"], "profile": dev["profile"], "restored_boots": 2, "records": 14,
            "absent_records": 2, "file_bytes": [item["bytes"] for item in files], "baseline_ordinary_reopen": True,
            "provider_scope": "selected-accepted-closures", "whole_account_reconciled": False,
            "restored_closures": closure_proof}


def _extension(candidate, evidence, schema, selected, dev, baseline_programs, marker):
    proof = read(evidence["stopped_development_proof"], 512 * 1024, digest(evidence["stopped_development_sha256"]))
    parent_ref = {"path": evidence["development_proof"], "sha256": evidence["development_sha256"]}
    parent, intent = reference(parent_ref), reference(proof["intent"])
    summary = reference(parent["summary"])
    operation = proof["intent"]["sha256"]
    programs = {name: value["sha256"] for name, value in candidate.items()}
    require(proof.get("schema") == schema and proof.get("profile") == selected["profile"]
            and proof.get("protocol") == int(PROTOCOL)
            and proof.get("parent_development") == intent.get("parent_development") == parent_ref
            and proof.get("source") == intent.get("source") == dev["source"]
            and proof.get("baseline_source") == intent.get("baseline_source") == dev["baseline"]
            and proof.get("baseline_programs") == intent.get("baseline_programs") == baseline_programs
            and proof.get("programs") == intent.get("programs") == programs
            and proof.get("account") == intent.get("account") == summary["account"]
            and proof.get("homes") == intent.get("homes") == summary["homes"]
            and intent.get("home") == str(Path(proof["homes"]) / "s")
            and 0 <= time.time() - uint(proof.get("completed_at"), True) <= 3600
            and proof.get("budget") == intent.get("budget") == BUDGET
            and all(type(proof["budget"][key]) is type(intent["budget"][key]) is int
                    for key in BUDGET if key != "scope"),
            "The separate stopped DEV extension scope, identity, or budget differs")
    require(intent.get("stop") == parent["consumers"]["baseline-after-candidate"]["stop"]
            and intent.get("files") == summary["full_CAS_file_bytes"]
            and intent.get("parent_final_records_sha256") == reference(parent["reads"]["restored-second"])["records_sha256"],
            "The stopped extension does not preserve the original stopped source and expected reads")
    reference(proof["usage_before"])
    source_identity(intent)
    stop = reference(intent["stop"])
    report, manifest = native_source(proof, intent, stop, summary["checkpoints"]["later"])
    restored(proof, parent, summary, candidate, report, manifest,
             node_format=int(marker.split(b"\n")[0].removeprefix(b"format=")),
             profile_version=RUN_PROFILE[marker])
    return proof, parent, summary, intent, operation, report, manifest


def _budget(report, adopted):
    manual_bytes, automatic_bytes = [decimal(point["inventory_root"]["stored_bytes"])
                                     for point in (report["accepted_backup"], adopted)]
    require(0 < manual_bytes <= BUDGET["max_manual_inventory_bytes"]
            and 0 < automatic_bytes <= BUDGET["max_automatic_inventory_bytes"]
            and manual_bytes + automatic_bytes <= BUDGET["max_total_inventory_bytes"],
            "The separate stopped and automatic adoption requests exceed their declared allowance")
    return manual_bytes + automatic_bytes


def stopped(candidate, evidence, selected, dev, baseline_programs):
    """A real stopped capture of the DEV home, its restore, and automatic adoption."""
    proof, parent, summary, intent, operation, report, manifest = _extension(
        candidate, evidence, STOPPED, selected, dev, baseline_programs, dev["marker"])
    adopted = adoption(proof, report, operation, source=dev["source"])
    return {"manual_request": report["request"]["request_id"], "stopped_snapshot_restored_boots": 2,
            "automatic_adoption": adopted["commit_sha256"], "scope": BUDGET["scope"],
            "new_requests": 2, "declared_inventory_bytes": _budget(report, adopted)}


def _files(value, home):
    require(value.get("schema") == FILES and value.get("home") == home
            and uint(value.get("observed_at"), True) and isinstance(value.get("files"), list)
            and 0 < len(value["files"]) <= 1000000, "A DEV native file list is incomplete")
    result = {}
    for item in value["files"]:
        require(set(item) == {"path", "native_sha256", "native_bytes"} and item["path"] not in result
                and digest(item["native_sha256"]) and uint(item["native_bytes"], True),
                "A DEV native file list entry is invalid")
        result[item["path"]] = (item["native_sha256"], item["native_bytes"])
    return result


def activation(candidate, evidence, selected, dev, baseline_programs):
    """The stopped capture at format 4, the offline activation, and a format 6 adoption."""
    require(selected["kind"] == "activation" and dev["marker"] == FORMAT4 and selected["after"] == FORMAT6,
            "The activation DEV proof needs a format 4 DEV home and the format 6 marker")
    proof, parent, summary, intent, operation, report, manifest = _extension(
        candidate, evidence, ACTIVATION, selected, dev, baseline_programs, FORMAT4)
    record = proof.get("activation")
    require(isinstance(record, dict) and set(record) == {"before", "result", "after", "read"},
            "The DEV activation record is incomplete")
    home = intent["home"]
    before, after = _files(reference(record["before"], 32 * 1024 * 1024), home), _files(
        reference(record["after"], 32 * 1024 * 1024), home)
    observed_before = reference(record["before"], 32 * 1024 * 1024)["observed_at"]
    observed_after = reference(record["after"], 32 * 1024 * 1024)["observed_at"]
    result = reference(record["result"], 65536)
    require(result.get("home") == home and result.get("programs") == proof["programs"]
            and result.get("source") == dev["source"] and result.get("operation_sha256") == operation
            and unwrap(result.get("reply", {})) == ACTIVATED and result.get("exit_code") == 0
            and observed_before <= uint(result.get("observed_at"), True) <= observed_after,
            "The DEV activation did not use the exact CLI on the stopped DEV home")
    captured = {item["path"]: (item["native_sha256"], decimal(item["native_bytes"]))
                for item in manifest["native_file_manifest"]}
    marker = "laststore-pack-node-v1"
    require(before == captured and before[marker] == (hashlib.sha256(FORMAT4).hexdigest(), len(FORMAT4))
            and after == {**before, marker: (hashlib.sha256(FORMAT6).hexdigest(), len(FORMAT6))},
            "The DEV activation changed native bytes other than the node marker")
    adopted = adoption(proof, report, operation, source=dev["source"])
    owner = reference(proof["adoption"]["owner"])
    identity = {"pid": uint(owner["pid"], True), "start_ts": uint(owner["start_ts"], True)}
    read_value = reference(record["read"])
    require(identity["start_ts"] >= observed_after and read_value.get("session") == identity
            and read_value.get("home") == home and read_value.get("source") == dev["source"]
            and read_value.get("programs") == proof["programs"] and read_value.get("stage") == "activated-source"
            and read_value.get("operation_sha256") == operation and read_value.get("node_marker") == FORMAT6.decode()
            and read_value.get("records_sha256") == intent["parent_final_records_sha256"]
            and (read_value.get("existing_records"), read_value.get("absent_records")) == (14, 2)
            and read_value.get("exact_keyed_values") is True and read_value.get("full_file_bytes_equal") is True
            and read_value.get("files") == summary["full_CAS_file_bytes"],
            "The activated DEV home did not boot and read the exact records and files at format 6")
    return {"manual_request": report["request"]["request_id"], "stopped_snapshot_restored_boots": 2,
            "activation": ACTIVATED, "native_files_unchanged_except_marker": len(before) - 1,
            "automatic_adoption": adopted["commit_sha256"], "scope": BUDGET["scope"],
            "new_requests": 2, "declared_inventory_bytes": _budget(report, adopted)}
