"""Select the exact restore destination while retaining the frozen receipt checks."""
import os


def selection(original, home, baseline):
    matches = []
    for name in original.names(home.parent):
        if not name.startswith(".byte-cloud-restore-"):
            continue
        identifier = name[len(".byte-cloud-restore-"):]
        original.require(original.UUID.fullmatch(identifier) and identifier != original.NIL,
                         "restore_session_name")
        root = home.parent / name
        selected = original.read_json(original.owned(root, "selection.json"))
        if selected.get("destination") == str(home):
            matches.append((root, identifier, selected))
    original.require(len(matches) == 1, "restore_destination_session_count")
    root, identifier, selected = matches[0]
    original.require(selected["version"] == 2 and selected["session_id"] == identifier
            and selected["destination"] == str(home)
            and selected["endpoint"] == original.dev_endpoint() + "/api/cloud/backups/v2/", "restore_selection")
    accepted = selected["accepted"]
    begin = accepted["begin"]
    stream = begin["job"]["stream"]
    original.require(accepted["version"] == 2 and begin["version"] == 2 and begin["descriptor"] is None
            and begin["required_destinations"] == ["r2", "b2"]
            and stream["scope"]["account_id"] == baseline["account"]
            and stream["scope"]["account_generation"] == baseline["account_generation"]
            and stream["stream_id"] == baseline["stream_id"]
            and begin["job"]["commit_id"] == baseline["commit_id"]
            and original.digest(accepted["commit_sha256"]) == baseline["commit_sha256"], "accepted_restore_selection")
    return root, identifier


def restored(original, home, report, baseline, replay=None, observe=None, node=None, profile=(2, 4)):
    """`node` names a closed route marker; the frozen route helper then returns its match."""
    root, identifier = selection(original, home, baseline)
    commit = original.digest(baseline["commit_sha256"])
    original.require(report["commit_sha256"] == commit and report["destination"] == str(home)
            and report["file_dependencies_verified"] is True
            and original.nonnegative(report["native_files"]) > 0
            and original.nonnegative(report["native_bytes"]) > 0
            and original.nonnegative(report["verified_atoms"]) >= 0
            and original.nonnegative(report["verified_external_files"]) == 0, "restore_report_binding")
    receipt_path = original.owned(home, "byte-cloud-restore-receipt.json")
    receipt = original.read_json(receipt_path, max_bytes=65536)
    original.require(isinstance(receipt, dict) and set(receipt) == {"version", "session_id", "report"}
            and receipt["version"] == 2 and receipt["report"] == report
            and receipt["session_id"] == identifier
            and original.read_json(original.owned(root, "result.json")) == report, "restore_receipt")
    original.require(not os.path.lexists(original.owned(home, "native-cloud-restore-receipt.json"))
            and not os.path.lexists(original.owned(home, "current-session.json"))
            and not os.path.lexists(original.owned(home, "data/folddb.sock")), "restore_before_normal_boot")
    routes = None
    if replay is None and node is None:
        files = original.inventory(home, root)
    elif replay is None:
        files, matched = original.inventory(home, root, node_markers=(node,))
        original.require(matched == node, "route_node_marker")
    else:
        files, routes = original.replayed_inventory(home, root, replay,
            original.read_json(original.owned(root, "selection.json"))["accepted"], observe)
    original.require(len(files) == report["native_files"]
            and sum(item["native_bytes"] for item in files) == report["native_bytes"], "restore_native_totals")
    result = {"schema": "lastdb.run-v2-restored-files.v1", "accepted_commit_sha256": commit,
            "native_files": len(files), "native_bytes": report["native_bytes"], "files": files,
            "receipt_sha256": original.hash_file(receipt_path), "profile_version": profile[0],
            "node_format": profile[1],
            "required_destinations": ["r2", "b2"], "product_inventory_closure_verified": True,
            "independent_native_file_hashes_verified": replay is None,
            "final_native_file_hashes_recorded": True, "selected_log_chain_verified": replay is not None,
            "native_file_closure_verified": True,
            "before_first_normal_boot": True}
    if routes is not None:
        result["mutation_log_routes"] = routes
    return result
