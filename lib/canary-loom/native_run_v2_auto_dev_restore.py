"""Bind all selected DEV closures to their original offline restore records."""

from pathlib import Path
import re

from native_upgrade_common import require
from native_run_v2_inputs import digest, reference, uint, unwrap
from auto_recovery_manifest import observation
from auto_recovery_files import recorded_closure

NAMES = {"base", "log", "later"}


def check(proof, summary, endpoint, owners):
    value = reference(proof["provider_accounting"])
    selected, restored = summary["checkpoints"], value["restores"]
    require(set(selected) == set(restored) == NAMES and selected["log"] == summary["accepted_backup"]
            and summary.get("provider_bytes_scope") == "selected-accepted-closures"
            and value.get("source") == summary["source"] and value.get("environment") == "dev"
            and value.get("scope") == "selected-accepted-closures"
            and value.get("all_selected_object_hashes_verified") is True
            and value.get("routes_verified") is True and value.get("whole_account_reconciled") is False
            and value.get("provider_deletions") == 0,
            "The exact DEV proof must cover selected closures without a whole-account claim")
    for name in sorted(NAMES):
        one(restored[name], selected[name], name, summary, endpoint, owners, proof["reads"])
    observed = summary["observed_accepted"]
    require(isinstance(observed, list) and 2 <= len(observed) <= 8
            and all(point in observed for point in selected.values()), "The actual DEV checkpoints exceed their bound")
    stream = selected["base"]["begin"]["job"]["stream"]
    ids = [point["begin"]["job"]["commit_id"] for point in observed]
    declared = [point["inventory_root"]["stored_bytes"] for point in observed]
    require(len(set(ids)) == len(ids)
            and all(point["begin"]["job"]["stream"] == stream for point in observed)
            and stream["scope"]["account_id"] == summary["account"]
            and all(isinstance(size, str) and re.fullmatch(r"[1-9][0-9]{0,19}", size)
                    and int(size) <= 2**64 - 1 for size in declared)
            and sum(int(size) for size in declared) <= 64 * 1024 * 1024,
            "The actual DEV stream or declared stored-byte allowance differs")
    return {"scope": "selected-accepted-closures", "whole_account_reconciled": False,
            "selected_restore_points": 3, "observed_checkpoints": len(observed)}


def one(record, accepted, name, summary, endpoint, owners, reads):
    selected = reference(record["selection"])
    report, result, receipt = [unwrap(reference(record[field])) for field in ("report", "result", "receipt")]
    native = reference(record["native_proof"], 32 * 1024 * 1024)
    prefix = {"base": "base-restored", "log": "restored", "later": "later-restored"}[name]
    labels = [prefix + "-" + boot for boot in ("first", "second")]
    require(record.get("read_receipts") == [reads[label] for label in labels],
            "A selected DEV restore does not bind its two original data reads")
    require(record.get("restored_boots") == record.get("strict_clean_stops") == 2,
            "A selected DEV restore lacks two actual strict normal boots")
    require(record.get("accepted_backup") == selected.get("accepted") == accepted
            and selected.get("endpoint") == endpoint
            and report == result and receipt == {"version": 2, "session_id": selected["session_id"], "report": report}
            and report.get("commit_sha256") == accepted["commit_sha256"]
            and report.get("destination") == selected.get("destination")
            and report.get("file_dependencies_verified") is True
            and uint(report.get("verified_records")) >= 0 and uint(report.get("verified_external_files")) == 0,
            "A selected DEV restore differs from its original completed product records")
    expected = {"base": "b", "log": "r", "later": "t"}[name]
    require(selected["destination"] == str(Path(summary["homes"]) / expected)
            and native.get("accepted_commit_sha256") == accepted["commit_sha256"]
            and native.get("before_first_normal_boot") is True
            and native.get("product_inventory_closure_verified") is True
            and native.get("native_file_closure_verified") is True
            and native.get("native_files") == report["native_files"]
            and native.get("native_bytes") == report["native_bytes"]
            and len(native["files"]) == report["native_files"]
            and len({item["path"] for item in native["files"]}) == len(native["files"])
            and sum(uint(item["native_bytes"], True) for item in native["files"]) == report["native_bytes"],
            "A DEV restore lacks complete native hashes before its first normal boot")
    for item in native["files"]:
        digest(item["native_sha256"])
    if name == "log":
        routes = native.get("mutation_log_routes", {})
        require(native.get("selected_log_chain_verified") is True
                and all(routes.get(field) is True for field in (
                    "main_r2", "cas_b2", "metadata_r2", "product_validated_routes", "written_prefix_verified"))
                and 0 < uint(routes.get("accepted_log_links"), True) <= 8,
                "The selected DEV log lacks its full written prefix or original product route checks")
    else:
        manifest = reference(record["snapshot_manifest"], 32 * 1024 * 1024)
        require(all(manifest.get(field) == record[field.removeprefix("restore_")] for field in (
            "restore_selection", "restore_report", "restore_result", "restore_receipt")),
            "The DEV snapshot manifest references another original restore")
        before, snapshot_report = observation(manifest, accepted, selected["endpoint"])
        first_boot = name + "-restored-first"
        require(before["observed_at"] <= owners[first_boot]["identity"]["start_ts"],
                "The snapshot native observation does not precede its first normal boot")
        require(snapshot_report == report and native.get("independent_native_file_hashes_verified") is True,
                "The DEV snapshot lacks its original full native hashes")
        recorded_closure(manifest["native_files"], before)
        normalized = [{key: item[key] for key in ("path", "native_sha256", "native_bytes")}
                      for item in manifest["native_files"]]
        require(normalized == native["files"], "The original snapshot manifest and native proofs differ")
