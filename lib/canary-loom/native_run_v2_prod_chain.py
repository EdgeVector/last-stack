"""Bind original product receipts for one completed PROD mutation-log restore.

The caller first verifies the exact client, compiled PROD endpoint and completed
restore report. This check reads only original private metadata through supplied
bounded readers. It does not decrypt manifests or independently verify providers.
"""

from pathlib import Path
import re
import uuid

from native_upgrade_common import require
from native_run_v2_auto_source import SOURCE

# Exact a1c product limits: logs/mod.rs, byte_cloud_log/mod.rs and LogEntry.
MAX_CHAIN = 32768
MAX_ENTRIES = 128
MAX_PARTS = 3
MAX_PAGES = 1024
PAGE_ENTRIES = 512
CONTROL_BYTES = 256 * 1024
U64_MAX = 2**64 - 1
COUNTERS = ("native_files", "native_bytes", "objects", "metadata_objects",
            "main_files", "cas_add_files", "cas_delete_files")


def integer(value):
    require(type(value) is int and 0 <= value <= U64_MAX, "prod_chain_integer")
    return value


def decimal(value):
    require(isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]{0,19}", value)
            and int(value) <= U64_MAX, "prod_chain_decimal")
    return int(value)


def digest(value):
    require(isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value), "prod_chain_digest")
    return value


def identifier(value):
    require(isinstance(value, str), "prod_chain_uuid")
    try:
        parsed = uuid.UUID(value)
    except (ValueError, AttributeError) as error:
        raise RuntimeError("prod_chain_uuid") from error
    require(str(parsed) == value and parsed.int != 0, "prod_chain_uuid")
    return value


def stream(value):
    require(isinstance(value, dict) and set(value) == {"scope", "stream_id"},
            "prod_chain_stream")
    scope = value["scope"]
    require(isinstance(scope, dict) and set(scope) == {"account_id", "account_generation"}
            and isinstance(scope["account_id"], str) and re.fullmatch(r"[0-9a-f]{32}", scope["account_id"]),
            "prod_chain_scope")
    decimal(scope["account_generation"])
    identifier(value["stream_id"])


def head(value):
    require(isinstance(value, dict) and set(value) == {"commit_id", "ordinal", "commit_sha256"},
            "prod_chain_head")
    identifier(value["commit_id"])
    require(decimal(value["ordinal"]) > 0, "prod_chain_ordinal")
    digest(value["commit_sha256"])
    return value


def point_head(value):
    return {"commit_id": value["begin"]["job"]["commit_id"],
            "ordinal": value["ordinal"], "commit_sha256": value["commit_sha256"]}


def accepted_point(value):
    require(isinstance(value, dict) and set(value) == {
        "version", "begin", "commit_sha256", "ordinal", "root_receipt_id", "inventory_root"}
        and integer(value["version"]) == 2, "prod_chain_accepted")
    begin = value["begin"]
    required = {"version", "job", "descriptor", "required_destinations", "predecessor"}
    require(isinstance(begin, dict) and required <= set(begin)
            and set(begin) <= required | {"r2_multipart", "recovery_dependencies"}
            and integer(begin["version"]) == 2 and begin["descriptor"] is None
            and begin["required_destinations"] == ["r2", "b2"]
            and ("r2_multipart" not in begin or begin["r2_multipart"] is True), "prod_chain_begin")
    job = begin["job"]
    require(isinstance(job, dict) and set(job) == {"stream", "commit_id"}, "prod_chain_job")
    stream(job["stream"])
    identifier(job["commit_id"])
    current = head(point_head(value))
    predecessor = begin["predecessor"]
    require(decimal(current["ordinal"]) == (0 if predecessor is None else decimal(head(predecessor)["ordinal"])) + 1
            and (predecessor is None or predecessor["commit_id"] != job["commit_id"]),
            "prod_chain_publication_ordinal")
    digest(value["root_receipt_id"])
    inventory = value["inventory_root"]
    require(isinstance(inventory, dict)
            and set(inventory) == {"sha256", "page_count", "object_count", "stored_bytes"},
            "prod_chain_inventory")
    digest(inventory["sha256"])
    pages, objects, stored = [decimal(inventory[name]) for name in ("page_count", "object_count", "stored_bytes")]
    require(0 < pages <= MAX_PAGES and pages <= objects <= pages * PAGE_ENTRIES and stored >= objects,
            "prod_chain_inventory_bounds")
    return value


def position(value):
    require(isinstance(value, dict) and set(value) == {"epoch", "sequence", "sha256", "frontiers"},
            "prod_chain_position")
    identifier(value["epoch"])
    integer(value["sequence"])
    digest(value["sha256"])
    require(isinstance(value["frontiers"], dict) and set(value["frontiers"]) == {"main", "cas"},
            "prod_chain_frontiers")
    for number in value["frontiers"].values():
        integer(number)
    return value


def prefix(proof, minimum):
    before, after = position(proof["from"]), position(proof["through"])
    hashes = proof["entry_sha256s"]
    require(before["epoch"] == after["epoch"] == minimum["epoch"]
            and isinstance(hashes, list) and 1 <= len(hashes) <= MAX_ENTRIES
            and after["sequence"] - before["sequence"] == len(hashes)
            and all(digest(item) for item in hashes) and hashes[-1] == after["sha256"]
            and all(after["frontiers"][key] >= before["frontiers"][key] for key in ("main", "cas")),
            "prod_chain_authenticated_range")
    number = minimum["sequence"]
    if not before["sequence"] <= number <= after["sequence"]:
        return False
    require(all(before["frontiers"][key] <= minimum["frontiers"][key] <= after["frontiers"][key]
                for key in ("main", "cas")), "prod_chain_minimum_frontiers")
    if number == before["sequence"]:
        require(minimum == before, "prod_chain_minimum_from")
    elif number == after["sequence"]:
        require(minimum == after, "prod_chain_minimum_through")
    else:
        # The product-authenticated entry hash commits its exact after-frontiers.
        require(hashes[number - before["sequence"] - 1] == minimum["sha256"], "prod_chain_minimum_hash")
    return True


def totals(proof, accepted, index):
    require(isinstance(proof, dict) and set(proof) == {
        "version", "link_index", "commit_sha256", "root_receipt_id", "inventory_root",
        "from", "through", "entry_sha256s", *COUNTERS}
        and integer(proof["version"]) == 1 and integer(proof["link_index"]) == index
        and proof["commit_sha256"] == accepted["commit_sha256"]
        and proof["root_receipt_id"] == accepted["root_receipt_id"]
        and proof["inventory_root"] == accepted["inventory_root"], "prod_chain_route_binding")
    values = {name: integer(proof[name]) for name in COUNTERS}
    before, after = position(proof["from"]), position(proof["through"])
    entries = after["sequence"] - before["sequence"]
    require(1 <= entries <= MAX_ENTRIES
            and entries <= values["native_files"] <= entries * MAX_PARTS
            and values["native_bytes"] > 0
            and 2 <= values["metadata_objects"] <= MAX_PAGES + 1
            and values["metadata_objects"] <= values["objects"]
            and values["objects"] == decimal(accepted["inventory_root"]["object_count"])
            and sum(values[name] for name in ("main_files", "cas_add_files", "cas_delete_files")) == values["native_files"]
            and after["frontiers"]["main"] - before["frontiers"]["main"] == values["main_files"]
            and after["frontiers"]["cas"] - before["frontiers"]["cas"]
                == values["cas_add_files"] + values["cas_delete_files"], "prod_chain_complete_route_totals")
    return values


def completed(session, accepted, read_json):
    require(session.is_absolute() and ".." not in session.parts
            and session.name.startswith(".byte-cloud-restore-"), "prod_chain_session")
    selected = read_json(session / "selection.json")
    require(integer(selected["version"]) == 2 and selected["accepted"] == accepted
            and identifier(selected["session_id"]) == session.name.removeprefix(".byte-cloud-restore-"),
            "prod_chain_selection")
    destination = Path(selected["destination"])
    require(destination.is_absolute() and ".." not in destination.parts
            and destination.parent == session.parent, "prod_chain_destination")
    report = read_json(session / "result.json")
    receipt = read_json(destination / "byte-cloud-restore-receipt.json")
    # Exact a1c V2 ClientRoot/page admission forbids external dependencies;
    # logs.finish likewise publishes NativeInventory { dependencies: 0 }.
    require(receipt == {"version": 2, "session_id": selected["session_id"], "report": report}
            and integer(receipt["version"]) == 2 and report["commit_sha256"] == accepted["commit_sha256"]
            and report["destination"] == str(destination) and report["file_dependencies_verified"] is True
            and integer(report["native_files"]) > 0 and integer(report["native_bytes"]) > 0
            and integer(report["verified_records"]) >= 0 and integer(report["verified_external_files"]) == 0,
            "prod_chain_completed_restore")


def successor(point, previous, base, chosen_stream):
    accepted_point(point)
    require(point["begin"]["job"]["stream"] == chosen_stream
            and point["begin"]["predecessor"] == point_head(previous), "prod_chain_exact_predecessor")
    dependencies = point["begin"].get("recovery_dependencies")
    expected = [point_head(base)] + ([] if previous == base else [point_head(previous)])
    require(dependencies is None or dependencies == expected, "prod_chain_recovery_dependencies")


def verified(session, accepted, minimum, read_json, names, expected_base=None):
    """Read original metadata after the exact product restore completes.

    Both callbacks receive a Path. The reader must enforce private regular files
    and a 256KiB per-file cap. The names callback must enforce a private directory
    and at most 2*MAX_CHAIN+2 entries. The caller owns those I/O guards.
    """
    session, accepted, minimum = Path(session), accepted_point(accepted), position(minimum)
    completed(session, accepted, read_json)
    plan, cursor = read_json(session / "chain/plan.json"), read_json(session / "chain/cursor.json")
    require(set(plan) == {"version", "head", "base", "links"}
            and set(cursor) == {"version", "head", "remaining", "previous", "position", "entry", "part"},
            "prod_chain_saved_shapes")
    links = integer(plan["links"])
    require(integer(plan["version"]) == integer(cursor["version"]) == 1 and 1 <= links <= MAX_CHAIN
            and plan["head"] == cursor["head"] == accepted["commit_sha256"]
            and cursor["previous"] == accepted
            and integer(cursor["remaining"]) == integer(cursor["entry"]) == integer(cursor["part"]) == 0,
            "prod_chain_completed_cursor")
    expected_names = {"plan.json", "cursor.json"}
    expected_names.update(f"{kind}-{index:08}.json" for kind in ("link", "routes") for index in range(links))
    observed_names = names(session / "chain")
    require(len(observed_names) == len(expected_names) and set(observed_names) == expected_names,
            "prod_chain_exhaustive_metadata")
    base, final = accepted_point(plan["base"]), position(cursor["position"])
    chosen_stream = accepted["begin"]["job"]["stream"]
    require(base["begin"]["job"]["stream"] == chosen_stream
            and base["begin"].get("recovery_dependencies") in (None, [])
            and (expected_base is None or base == expected_base), "prod_chain_exact_snapshot_base")
    previous, first, through, covered = base, None, None, False
    sums, entries = dict.fromkeys(COUNTERS, 0), 0
    seen = {base["begin"]["job"]["commit_id"]}
    for index in reversed(range(links)):
        point = read_json(session / f"chain/link-{index:08}.json")
        proof = read_json(session / f"chain/routes-{index:08}.json")
        successor(point, previous, base, chosen_stream)
        commit_id = point["begin"]["job"]["commit_id"]
        require(commit_id not in seen, "prod_chain_repeated_commit")
        seen.add(commit_id)
        values = totals(proof, point, index)
        covered = prefix(proof, minimum) or covered
        require(through is None or proof["from"] == through, "prod_chain_continuous_positions")
        first = proof["from"] if first is None else first
        through, previous = proof["through"], point
        entries += through["sequence"] - proof["from"]["sequence"]
        for name, count in values.items():
            sums[name] = integer(sums[name] + count)
    require(previous == accepted and through == final and covered and entries > 0
            and first["sequence"] == 0 and entries == final["sequence"]
            and final["sequence"] >= minimum["sequence"]
            and all(final["frontiers"][key] >= minimum["frontiers"][key] for key in ("main", "cas"))
            and sums["native_files"] > 0 and sums["native_bytes"] > 0 and sums["metadata_objects"] > 0,
            "prod_chain_complete_written_prefix")
    cas = sums["cas_add_files"] + sums["cas_delete_files"] > 0
    return {"schema": "lastdb.prod-mutation-log-chain.v1", "source": SOURCE,
            "scope": "selected-accepted-log-chain", "accepted": point_head(accepted), "base": point_head(base),
            "stream_id": chosen_stream["stream_id"],
            "account_generation": chosen_stream["scope"]["account_generation"],
            "from": first, "through": final, "minimum": minimum, "accepted_log_links": links,
            "mutation_entries": entries, **sums,
            "main_r2": {"applicable": sums["main_files"] > 0, "verified": sums["main_files"] > 0},
            "cas_b2": {"applicable": cas, "verified": cas},
            "metadata_r2": {"applicable": True, "verified": True},
            "product_validated_routes": True, "written_prefix_verified": True,
            "independent_manifest_or_provider_validation": False}
