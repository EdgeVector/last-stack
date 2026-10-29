"""The new stopped-cut profile starts with a proved temporary automatic pause."""
from pathlib import Path

from native_upgrade_common import call, require
from native_run_v2_inputs import uint


def contract(approval):
    value = approval.get("automatic_restore")
    require(isinstance(value, dict) and set(value) == {
        "disabled_revision", "log_interval_seconds", "snapshot_interval_seconds", "after_success"}
        and uint(value["disabled_revision"], True) and value["log_interval_seconds"] == 60
        and value["snapshot_interval_seconds"] == 86400
        and value["after_success"] == "separate-product-action",
        "The stopped-cut profile needs its explicit original automatic schedule restoration")
    return value


def observe_off(approval, *, admission=True):
    expected = contract(approval)
    home = Path(approval["primary_home"])
    value = call(home / "data/folddb.sock", "/api/sync/byte-backup-v2", {"action": "status"})
    policy = value.get("automatic_backup", {})
    require(value.get("user_hash") == approval["recovery"]["account_id"] and value.get("enabled") is True
            and value.get("automatic_backup_enabled") is False and policy.get("enabled") is False
            and type(policy.get("revision")) is int and policy["revision"] == expected["disabled_revision"]
            and policy.get("log_interval_seconds") == 60 and policy.get("snapshot_interval_seconds") == 86400
            and policy.get("pending_request_id") is None and policy.get("paused") is None
            and policy.get("attempts") == policy.get("retry_at") == 0
            and value.get("mutation_log", {}).get("enabled") is False,
            "The stopped-cut profile requires its exact direct automatic-off policy")
    if admission:
        require(value.get("phase") == "published" and value.get("running") is False
                and value.get("retained_source_bytes") == 0 and value.get("blocked_reason") is None
                and value.get("last_accepted_backup") == approval["recovery"]["accepted_backup"],
                "The stopped-cut profile requires its exact idle automatic-off admission")
    return {"revision": policy["revision"], "log_interval_seconds": 60,
            "snapshot_interval_seconds": 86400, "enabled": False, "pending_request_id": None}


def before_stop(approval, state):
    from native_run_v2_recovery import before_stop as snapshot_before_stop
    first = observe_off(approval)
    snapshot = snapshot_before_stop(approval, state)
    last = observe_off(approval)
    require(first == last, "The disabled automatic policy changed during the final recovery check")
    return {**snapshot, "automatic_pause": last}
