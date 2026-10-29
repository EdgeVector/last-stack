"""Three source-free recovery points; no CI identity is supplied or invented."""
import os

from native_run_v2_auto_qualify_data import memory
from native_run_v2_auto_qualify_io import read, reference, require, save
from native_run_v2_auto_qualify_process import node
from native_run_v2_auto_qualify_restore import Request, qualify, selection
from native_run_v2_auto_qualify_receipts import restored
from auto_recovery_manifest import capture


def stopped(operation):
    require(operation.node is None or operation.node.process is None, "source_owned_child_stopped")
    home = operation.homes / "s"
    require(all(not os.path.lexists(home / name) for name in
                ("current-session.json", "data/folddb.sock", "data/folddb-full.sock")), "source_stays_stopped")


def recover(operation, flow, kind):
    operation.summary["stage"] = kind + "-source-free-recovery"
    accepted = flow[{"base": "snapshot", "log": "log", "later": "later"}[kind]]
    initial = kind == "base"
    expected = operation.data.initial if initial else operation.data.expected
    files = operation.data.initial_files if initial else operation.data.files
    destination = operation.homes / {"base": "b", "log": "r", "later": "t"}[kind]
    output = operation.output / (kind + "-recovery")
    labels = ("restored-first", "restored-second") if kind == "log" else (kind + "-restored-first", kind + "-restored-second")
    request = Request(operation.candidate, accepted, operation.endpoint, operation.account,
                      operation.credentials, operation.phrase, destination, output,
                      compiled_profile=operation.root / "source/folddb_profile/environments.json")
    chosen = {"account": operation.account, **selection(accepted, operation.account)}
    baseline = dict(chosen)
    replay = {"base": flow["snapshot"], "minimum": flow["minimum"]} if kind == "log" else None

    def product_proof(report, actual):
        require(actual["commit_sha256"] == accepted["commit_sha256"], "frozen_recovery_point")
        return restored(operation.helpers.restore, destination, report, baseline, replay,
                        operation.source.observe_accepted if replay else None)

    def boot(number):
        return node(operation, destination, operation.candidate, labels[number])

    def observe(current, number):
        result = operation.data.reads(current, labels[number], expected, files, accepted)
        if kind == "log" and number == 1:
            operation.memory = memory(operation, current)
            operation.memory["read"] = result
        return result

    result = qualify(request, boot, observe, capture, lambda: stopped(operation), product_proof)
    require(result["restored_boots"] == result["strict_clean_stops"] == 2, "two_real_restore_boots")
    if kind == "log":
        operation.memory["stop"] = operation.consumers["restored-second"]["stop"]
        operation.memory_ref = save(operation.output / "memory-guard.json", operation.memory)
    return result


def all_points(operation, flow):
    result = {kind: recover(operation, flow, kind) for kind in ("base", "log", "later")}
    provider = {"source": operation.plan["source"], "environment": "dev",
        "scope": "selected-accepted-closures", "all_selected_object_hashes_verified": True,
        "routes_verified": True, "whole_account_reconciled": False, "provider_deletions": 0,
        "restores": result}
    for kind, item in result.items():
        proof = read(item["native_proof"]["path"])
        require(reference(item["native_proof"]["path"]) == item["native_proof"]
                and proof["accepted_commit_sha256"] == item["accepted_backup"]["commit_sha256"]
                and proof["product_inventory_closure_verified"] is True, "selected_provider_restore_proof")
        if kind == "log":
            routes = proof["mutation_log_routes"]
            require(proof["selected_log_chain_verified"] is True
                    and all(routes[name] is True for name in
                        ("main_r2", "cas_b2", "metadata_r2", "product_validated_routes", "written_prefix_verified")),
                    "complete_selected_log_routes")
        else:
            require(item["snapshot_manifest"] is not None, "original_snapshot_native_manifest")
    original = save(operation.output / "provider-accounting.json", provider)
    return result, original
