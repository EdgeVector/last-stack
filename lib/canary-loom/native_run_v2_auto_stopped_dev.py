"""Require one real typed stopped capture and its automatic snapshot adoption."""
from pathlib import Path
import time
import uuid

from native_upgrade_common import require
from native_run_v2_auto_source import BASELINE, BASELINE_PROGRAMS, SOURCE
from native_run_v2_auto_qualify_io import hash_file
from native_run_v2_auto_policy import head
from native_run_v2_dev_session import ended
from native_run_v2_final_dev import consumer
from native_run_v2_final_manifest import decimal
from native_run_v2_recovery import FILE
from native_run_v2_inputs import digest, external, read, reference, uint, unwrap

PROFILE = "run-v2-format4-final-stopped-maintenance-v1"
BUDGET = {"scope": "separate-stopped-extension", "max_manual_requests": 1, "max_automatic_requests": 1,
          "max_source_free_restores": 1, "max_manual_inventory_bytes": 33554432,
          "max_automatic_inventory_bytes": 33554432, "max_total_inventory_bytes": 67108864}
LABELS = ("stopped-restored-first", "stopped-restored-second")


def next_point(point, previous, request):
    require(point.get("version") == 2 and point["begin"].get("version") == 2
            and point["begin"].get("descriptor") is None and point["begin"].get("required_destinations") == ["r2", "b2"]
            and point["begin"]["job"]["stream"] == previous["begin"]["job"]["stream"]
            and point["begin"]["job"]["commit_id"] == request
            and point["begin"].get("predecessor") == {"commit_id": previous["begin"]["job"]["commit_id"],
                "commit_sha256": previous["commit_sha256"], "ordinal": previous["ordinal"]}
            and decimal(point["ordinal"]) == decimal(previous["ordinal"]) + 1,
            "The stopped extension must use the exact next accepted point on the same stream")
    digest(point["commit_sha256"])


def native_source(proof, intent, original_stop, previous):
    saved = proof["stopped_backup"]
    report, manifest, files = [reference(saved[name], 32 * 1024 * 1024) for name in ("report", "manifest", "stopped_files")]
    request = intent["request_id"]
    parsed = uuid.UUID(request)
    require(str(parsed) == request and parsed.version == 4 and not request.startswith("a17dbac2-"),
            "The stopped extension needs its own canonical manual request")
    owner = original_stop["owner"]
    require(report.get("version") == 1 and report.get("request") == {"request_id": request,
        "account_id": proof["account"], "stopped_pid": owner["pid"], "stopped_start_ts": owner["start_ts"]}
        and report.get("automatic_backup_enabled") is False
        and all(report.get(name) is True for name in ("all_remote_file_hashes_verified", "source_released", "native_cut_unchanged"))
        and report["verified_remote_objects"] == decimal(report["accepted_backup"]["inventory_root"]["object_count"])
            + decimal(report["accepted_backup"]["inventory_root"]["page_count"]) + 1,
        "The stopped DEV capture lacks its exact clean session and complete provider readback")
    accepted = report["accepted_backup"]
    next_point(accepted, previous, request)
    require(manifest.get("begin") == accepted["begin"] and manifest.get("run_profile") == report["run_profile"]
            and manifest.get("native_files") == files.get("native_files") == report["native_files"]
            and manifest.get("native_bytes") == files.get("native_bytes") == report["native_bytes"]
            and len(manifest["native_file_manifest"]) == report["native_files"]
            and sum(decimal(item["native_bytes"]) for item in manifest["native_file_manifest"]) == report["native_bytes"],
            "The stopped DEV manifest, full source hashes, or native totals differ")
    for home, label in (("disk-run", "main"), ("disk-cas", "cas")):
        checksum = report["run_profile"][label]["current_sha256"]
        require(files["selectors"][home]["sha256"] == intent["current_sha256"][home] == checksum,
                "The stopped DEV source changed during capture or readback")
    paths = [item["path"] for item in manifest["native_file_manifest"]]
    required = {"laststore-pack-node-v1", "disk-run/CURRENT", "disk-cas/CURRENT",
                "disk-run/laststore-run-home-v2", "disk-cas/laststore-run-home-v2"}
    require(len(set(paths)) == len(paths) and required <= set(paths)
            and all(path == "laststore-pack-node-v1" or FILE.fullmatch(path) for path in paths)
            and all(digest(item["native_sha256"]) and 0 < decimal(item["native_bytes"]) <= 2**40
                    for item in manifest["native_file_manifest"]),
            "The stopped DEV source files repeat or lack complete hashes")
    return report, manifest


def restored(proof, parent, summary, programs, report, manifest, *, files=None):
    record = proof["restore"]
    selected = reference(record["selection"])
    actual, result, receipt = [unwrap(reference(record[name])) for name in ("report", "result", "receipt")]
    native = reference(record["native_proof"], 32 * 1024 * 1024)
    accepted, home = report["accepted_backup"], Path(proof["homes"]) / "u"
    base = reference(parent["provider_accounting"])["restores"]["base"]
    require(record.get("accepted_backup") == selected.get("accepted") == accepted
            and selected.get("version") == 2 and selected.get("destination") == str(home)
            and selected.get("endpoint") == reference(base["selection"])["endpoint"]
            and actual == result and receipt == {"version": 2, "session_id": selected["session_id"], "report": actual}
            and actual.get("destination") == str(home) and actual.get("commit_sha256") == accepted["commit_sha256"]
            and actual.get("file_dependencies_verified") is True and uint(actual.get("verified_atoms")) >= 0
            and actual.get("verified_external_files") == 0
            and record.get("restored_boots") == record.get("strict_clean_stops") == 2,
            "The final stopped snapshot lacks its completed source-free restore and two clean boots")
    expected = [{"path": item["path"], "native_sha256": item["native_sha256"], "native_bytes": decimal(item["native_bytes"])}
                for item in manifest["native_file_manifest"]]
    require(native.get("accepted_commit_sha256") == accepted["commit_sha256"]
            and native.get("profile_version") == 2 and native.get("node_format") == 4
            and native.get("required_destinations") == ["r2", "b2"]
            and native.get("native_files") == actual.get("native_files") == report["native_files"]
            and native.get("native_bytes") == actual.get("native_bytes") == report["native_bytes"]
            and native.get("before_first_normal_boot") is True and native.get("product_inventory_closure_verified") is True
            and native.get("native_file_closure_verified") is True and native.get("independent_native_file_hashes_verified") is True
            and sorted(native["files"], key=lambda item: item["path"]) == sorted(expected, key=lambda item: item["path"])
            and record.get("read_receipts") == [proof["reads"][label] for label in LABELS]
            and set(proof["consumers"]) == set(proof["reads"]) == set(LABELS),
            "The stopped source and original preboot restored native hashes differ")
    expected_digest = reference(parent["reads"]["restored-second"])["records_sha256"]
    sessions = set()
    for label in LABELS:
        owner = reference(proof["consumers"][label]["owner"])
        identity = (owner["pid"], owner["start_ts"])
        require(identity not in sessions, "The stopped restore reused a session")
        sessions.add(identity)
        consumer(proof["consumers"][label], proof["reads"][label], programs, summary, home,
                 proof["intent"]["sha256"], accepted, label, expected_digest, files=files)


def adoption(proof, report, operation):
    records = proof["adoption"]
    require(set(records) == {"owner", "stop", "status", "before_enable", "after_disable", "recovery"},
            "The automatic adoption records are incomplete")
    owner, stop, status, before_record, after, recovery = [reference(records[name]) for name in
        ("owner", "stop", "status", "before_enable", "after_disable", "recovery")]
    require(set(before_record) == {"status", "recovery"}, "The original pre-enable status and recovery record differ")
    before, manual_recovery = before_record["status"], before_record["recovery"]
    identity = {"pid": uint(owner["pid"], True), "start_ts": uint(owner["start_ts"], True)}
    require(owner.get("source") == SOURCE and owner.get("programs") == proof["programs"]
            and owner.get("account") == proof["account"] and owner.get("home") == str(Path(proof["homes"]) / "s")
            and owner.get("operation_sha256") == operation and stop.get("owner") == owner
            and stop.get("receipt") == {"version": 1, **identity, "flush_ok": True}
            and all(stop.get("session", {}).get(key) == value for key, value in identity.items())
            and stop["session"].get("exit") == "clean" and ended(identity, stop),
            "Automatic adoption lacks its actual candidate source owner and strict clean stop")
    accepted = status["last_accepted_backup"]
    request = accepted["begin"]["job"]["commit_id"]
    require(request.startswith("a17dbac2-") and str(uuid.UUID(request)) == request,
            "Automatic adoption did not use a daemon-initiated snapshot")
    next_point(accepted, report["accepted_backup"], request)
    policy, journal = status["automatic_backup"], status["mutation_log"]
    position = head(journal["head"])
    require(status.get("user_hash") == proof["account"] and status.get("backup_kind") == "snapshot"
            and status.get("phase") == "published" and status.get("running") is False and status.get("retained_source_bytes") == 0
            and status.get("request_id") == policy.get("last_completed_request_id") == request
            and policy.get("enabled") is True and policy.get("log_interval_seconds") == 60
            and policy.get("snapshot_interval_seconds") == 86400 and policy.get("pending_request_id") is None
            and policy.get("paused") is None and policy.get("attempts") == policy.get("retry_at") == 0
            and journal.get("enabled") is True and journal.get("gap") is None and journal.get("snapshot_required") is False
            and journal.get("acknowledged_through") == position["sequence"] == 0 and journal.get("retained_bytes") == 0
            and policy.get("last_backed_up_frontiers") == position["frontiers"]
            and recovery.get("accepted") == recovery.get("base") == accepted
            and recovery.get("anchor") == journal["anchor"] and recovery.get("through") == position
            and recovery.get("frontiers") == position["frontiers"],
            "The manual stopped head did not gain a coherent fully covered automatic snapshot anchor")
    require(before.get("last_accepted_backup") == report["accepted_backup"]
            and manual_recovery.get("accepted") == manual_recovery.get("base") == report["accepted_backup"]
            and manual_recovery.get("anchor") is None and manual_recovery.get("through") is None
            and manual_recovery.get("frontiers") == {label: decimal(report["run_profile"][label]["frontier"])
                                                      for label in ("main", "cas")}
            and before["automatic_backup"].get("enabled") is False and before.get("running") is False
            and before["automatic_backup"].get("pending_request_id") is None
            and after.get("last_accepted_backup") == accepted and after.get("running") is False
            and after.get("user_hash") == before.get("user_hash") == proof["account"]
            and after.get("retained_source_bytes") == 0 and after["automatic_backup"].get("enabled") is False
            and after["automatic_backup"].get("pending_request_id") is None
            and after["mutation_log"].get("enabled") is False and before["mutation_log"].get("enabled") is False
            and policy["revision"] == before["automatic_backup"]["revision"] + 1
            and after["automatic_backup"]["revision"] == policy["revision"] + 1,
            "The adoption source did not return to its exact idle automatic-off cleanup state")
    return accepted


def source_identity(intent):
    hashes = intent.get("source_hashes")
    require(isinstance(hashes, dict) and 0 < len(hashes) <= 128 and intent.get("no_user_writes") is True,
            "The stopped extension needs its bounded unchanged source and no-user-write intent")
    for name, checksum in hashes.items():
        path = Path(name)
        if path.parent != Path(__file__).resolve().parent:
            external(path)
        require(path.is_absolute() and path.resolve() == path and path.suffix == ".py"
                and hash_file(path, 1048576) == digest(checksum), "A stopped-extension source changed")


def check(candidate, evidence):
    proof = read(evidence["stopped_development_proof"], 512 * 1024, digest(evidence["stopped_development_sha256"]))
    parent_ref = {"path": evidence["development_proof"], "sha256": evidence["development_sha256"]}
    parent, intent = reference(parent_ref), reference(proof["intent"])
    summary = reference(parent["summary"])
    files, operation = None, proof["intent"]["sha256"]
    if proof.get("schema") == "lastdb.format4-stopped-development.v2":
        from native_run_v2_stopped_continuation import check as continuation
        intent, files = continuation(proof, parent, summary, source_identity)
        operation = proof["original_attempt"]["intent"]["sha256"]
    programs = {name: value["sha256"] for name, value in candidate.items()}
    require(proof.get("schema") in ("lastdb.format4-stopped-development.v1", "lastdb.format4-stopped-development.v2")
            and proof.get("profile") == PROFILE
            and proof.get("protocol") == 13
            and proof.get("parent_development") == intent.get("parent_development") == parent_ref
            and proof.get("source") == intent.get("source") == SOURCE
            and proof.get("baseline_source") == intent.get("baseline_source") == BASELINE
            and proof.get("baseline_programs") == intent.get("baseline_programs") == BASELINE_PROGRAMS
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
            and intent.get("parent_final_records_sha256") == reference(parent["reads"]["restored-second"])["records_sha256"]
            and isinstance(intent.get("source_hashes"), dict) and 0 < len(intent["source_hashes"]) <= 128,
            "The stopped extension does not preserve the original stopped source and expected reads")
    reference(proof["usage_before"])
    source_identity(intent)
    stop = reference(intent["stop"])
    report, manifest = native_source(proof, intent, stop, summary["checkpoints"]["later"])
    restored(proof, parent, summary, candidate, report, manifest, files=files)
    adopted = adoption(proof, report, operation)
    manual_bytes, automatic_bytes = [decimal(point["inventory_root"]["stored_bytes"])
                                     for point in (report["accepted_backup"], adopted)]
    require(0 < manual_bytes <= BUDGET["max_manual_inventory_bytes"]
            and 0 < automatic_bytes <= BUDGET["max_automatic_inventory_bytes"]
            and manual_bytes + automatic_bytes <= BUDGET["max_total_inventory_bytes"],
            "The separate stopped and automatic adoption requests exceed their declared allowance")
    return {"manual_request": report["request"]["request_id"], "stopped_snapshot_restored_boots": 2,
            "automatic_adoption": adopted["commit_sha256"], "scope": BUDGET["scope"],
            "new_requests": 2, "declared_inventory_bytes": manual_bytes + automatic_bytes}
