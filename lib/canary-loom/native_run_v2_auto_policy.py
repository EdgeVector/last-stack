"""Preserve the exact automatic policy and admit only a fully covered stopped cut."""

from pathlib import Path
import re
import uuid

from native_upgrade_common import call, require
from native_run_v2_inputs import uint

POLICY = ("revision", "log_interval_seconds", "snapshot_interval_seconds")


def frontiers(value):
    require(isinstance(value, dict) and set(value) == {"main", "cas"},
            "The automatic backup needs both native frontiers")
    return {key: uint(value[key]) for key in ("main", "cas")}


def head(value):
    require(isinstance(value, dict) and set(value) == {"epoch", "sequence", "sha256", "frontiers"},
            "The automatic journal head differs")
    epoch = value["epoch"]
    require(isinstance(epoch, str) and str(uuid.UUID(epoch)) == epoch and uuid.UUID(epoch).int != 0
            and isinstance(value["sha256"], str) and re.fullmatch(r"[0-9a-f]{64}", value["sha256"]),
            "The automatic journal identity is invalid")
    return {"epoch": epoch, "sequence": uint(value["sequence"]),
            "sha256": value["sha256"], "frontiers": frontiers(value["frontiers"])}


def contract(approval):
    from native_run_v2_profiles import automatic
    require(automatic(approval), "The automatic policy requires its exact profile")
    value = approval.get("automatic_backup")
    require(isinstance(value, dict) and set(value) == {*POLICY, "journal_head"},
            "The exact automatic backup contract is absent")
    for key in POLICY:
        uint(value[key], True)
    require(all(60 <= value[key] <= 604800 for key in POLICY[1:]),
            "The automatic backup intervals exceed the product bounds")
    head(value["journal_head"])
    return value


def observe(approval, *, exact_snapshot=False):
    expected = contract(approval)
    home = Path(approval["primary_home"])
    status = call(home / "data/folddb.sock", "/api/sync/byte-backup-v2", {"action": "status"})
    automatic = status.get("automatic_backup")
    journal = status.get("mutation_log")
    require(status.get("enabled") is True and status.get("automatic_backup_enabled") is True
            and status.get("user_hash") == approval["recovery"]["account_id"]
            and isinstance(automatic, dict) and automatic.get("enabled") is True
            and all(type(automatic.get(key)) is int and automatic[key] == expected[key] for key in POLICY),
            "The original account or automatic backup policy changed")
    require(automatic.get("paused") is None and automatic.get("attempts") == 0
            and automatic.get("retry_at") == 0 and status.get("blocked_reason") is None,
            "The automatic backup is paused, blocked, or retries a failed request")
    accepted = status.get("last_accepted_backup")
    recovery = approval["recovery"]["accepted_backup"]
    from native_run_v2_final_manifest import decimal
    require(isinstance(accepted, dict) and accepted.get("version") == 2
            and accepted.get("begin", {}).get("job", {}).get("stream") == recovery["begin"]["job"]["stream"]
            and decimal(accepted["ordinal"]) >= decimal(recovery["ordinal"])
            and (accepted["ordinal"] != recovery["ordinal"] or accepted == recovery),
            "The accepted automatic recovery stream changed or moved backwards")
    require(isinstance(journal, dict) and journal.get("enabled") is True
            and journal.get("gap") is None and journal.get("snapshot_required") is False,
            "The automatic journal has a gap or requires a new snapshot")
    current = head(journal.get("head"))
    minimum = expected["journal_head"]
    acknowledged = uint(journal.get("acknowledged_through"))
    require(current["epoch"] == minimum["epoch"] and current["sequence"] >= minimum["sequence"]
            and minimum["sequence"] <= acknowledged <= current["sequence"]
            and all(current["frontiers"][key] >= minimum["frontiers"][key] for key in ("main", "cas"))
            and (current["sequence"] != minimum["sequence"] or current == minimum),
            "The automatic journal identity or acknowledged boundary moved backwards")
    backed = frontiers(automatic.get("last_backed_up_frontiers"))
    require(all(minimum["frontiers"][key] <= backed[key] <= current["frontiers"][key] for key in backed),
            "The automatic backup lost the original covered frontier")
    result = {**{key: automatic[key] for key in POLICY}, "journal_head": current,
              "acknowledged_through": acknowledged, "last_backed_up_frontiers": backed,
              "request_id": status.get("request_id"), "running": status.get("running")}
    if exact_snapshot:
        accepted = approval["recovery"]["accepted_backup"]
        request = accepted["begin"]["job"]["commit_id"]
        require(status.get("backup_kind") == "snapshot" and status.get("phase") == "published"
                and status.get("running") is False and status.get("retained_source_bytes") == 0
                and status.get("last_accepted_backup") == accepted and status.get("request_id") == request
                and automatic.get("last_completed_request_id") == request
                and automatic.get("pending_request_id") is None and current == minimum
                and acknowledged == current["sequence"] and journal.get("retained_bytes") == 0
                and backed == current["frontiers"],
                "The exact automatic snapshot does not cover every current mutation")
        from native_run_v2_recovery import local
        saved = local(home / "data/cloud-byte-backup-v2/jobs" / request / "state.json")
        revision = uint(saved.get("automatic_revision"), True)
        require(revision <= expected["revision"] and saved.get("accepted") == accepted,
                "The selected snapshot lacks its real automatic consent revision")
        result["snapshot_automatic_revision"] = revision
    return result


def before_stop(approval, state):
    from native_run_v2_recovery import before_stop as snapshot_before_stop
    first = observe(approval, exact_snapshot=True)
    snapshot = snapshot_before_stop(approval, state)
    last = observe(approval, exact_snapshot=True)
    require(first == last, "The covered automatic snapshot changed during its final read bookends")
    return {**snapshot, "automatic_backup": last}
