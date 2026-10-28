"""Dispatch only the two exact approval/evidence profile pairs."""

from native_upgrade_common import require
import native_run_v2_gate as first
import native_run_v2_gate_v2 as second
import native_run_v2_maintenance as maintenance
import native_run_v2_final_gate as final

PAIRS = {
    ("lastdb.run-v2-maintenance-approval.v2", final.PROFILE):
        ("lastdb.run-v2-maintenance-evidence.v2", final),
    ("lastdb.run-v2-maintenance-approval.v1", maintenance.PROFILE):
        ("lastdb.run-v2-maintenance-evidence.v1", maintenance),
    ("lastdb.run-v2-ci-bootstrap-approval.v1", first.PROFILE):
        ("lastdb.run-v2-ci-evidence.v1", first),
    ("lastdb.run-v2-ci-bootstrap-approval.v2", second.PROFILE):
        ("lastdb.run-v2-ci-evidence.v2", second),
}


def selected(approval):
    pair = PAIRS.get((approval.get("schema"), approval.get("profile")))
    require(pair is not None, "Unknown or mixed RunV2 approval schema and profile")
    return pair


def check(candidate, evidence, approval):
    schema, policy = selected(approval)
    require(evidence.get("schema") == schema and evidence.get("profile") == policy.PROFILE,
            "Unknown or mixed RunV2 evidence schema and profile")
    return policy.check(candidate, evidence, approval)
