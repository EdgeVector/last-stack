"""Dispatch exact maintenance profiles without mixing their recovery contracts."""

from native_upgrade_common import require
import native_run_v2_maintenance as maintenance
import native_run_v2_final_gate as final
import native_run_v2_auto_gate as automatic_policy

PAIRS = {
    ("lastdb.run-v2-maintenance-approval.v3", automatic_policy.PROFILE):
        ("lastdb.run-v2-maintenance-evidence.v3", automatic_policy),
    ("lastdb.run-v2-maintenance-approval.v2", final.PROFILE):
        ("lastdb.run-v2-maintenance-evidence.v2", final),
    ("lastdb.run-v2-maintenance-approval.v1", maintenance.PROFILE):
        ("lastdb.run-v2-maintenance-evidence.v1", maintenance),
}

PROTOCOLS = {
    "lastdb.run-v2-maintenance-approval.v1": "12",
    "lastdb.run-v2-maintenance-approval.v2": "13",
    "lastdb.run-v2-maintenance-approval.v3": "14",
}


def selected(approval):
    pair = PAIRS.get((approval.get("schema"), approval.get("profile")))
    require(pair is not None, "Unknown or mixed RunV2 approval schema and profile")
    return pair


def protocol(approval):
    selected(approval)
    return PROTOCOLS[approval["schema"]]


def automatic(approval):
    return selected(approval)[1] is automatic_policy


def check(candidate, evidence, approval):
    schema, policy = selected(approval)
    require(evidence.get("schema") == schema and evidence.get("profile") == policy.PROFILE,
            "Unknown or mixed RunV2 evidence schema and profile")
    return policy.check(candidate, evidence, approval)
