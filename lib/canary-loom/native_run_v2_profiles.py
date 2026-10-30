"""Dispatch exact maintenance profiles without mixing their recovery contracts."""

from native_upgrade_common import require
import native_run_v2_maintenance as maintenance
import native_run_v2_final_gate as final
import native_run_v2_auto_gate as automatic_policy
import native_run_v2_auto_final_gate as stopped_format4
import native_run_v2_route_gate as route_gate
from native_run_v2_routes import APPROVAL as ROUTE_APPROVAL, EVIDENCE as ROUTE_EVIDENCE
from native_run_v2_routes import PROTOCOL as ROUTE_PROTOCOL, route

PAIRS = {
    **{(ROUTE_APPROVAL, name): (ROUTE_EVIDENCE, route_gate) for name in route_gate.PROFILES},
    ("lastdb.run-v2-maintenance-approval.v4", stopped_format4.PROFILE):
        ("lastdb.run-v2-maintenance-evidence.v4", stopped_format4),
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
    "lastdb.run-v2-maintenance-approval.v4": "13",
    ROUTE_APPROVAL: ROUTE_PROTOCOL,
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


def closed_route(approval):
    """A pinned protein-removal route: the format4 final stopped policy with a route pair."""
    if selected(approval)[1] is not route_gate:
        return None
    return route(approval)


def modern_stopped(approval):
    return selected(approval)[1] in (stopped_format4, route_gate)


def final_stopped(approval):
    return selected(approval)[1] in (final, stopped_format4, route_gate)


def typed_recovery(approval):
    return selected(approval)[1] in (automatic_policy, stopped_format4, route_gate)


def baseline(approval):
    """The exact baseline source; a route binds its baseline pair in the gate."""
    policy = selected(approval)[1]
    if policy is route_gate:
        return route(approval)["baseline"], approval.get("baseline_programs_sha256")
    return policy.BASELINE, policy.BASELINE_PROGRAMS


def check(candidate, evidence, approval):
    schema, policy = selected(approval)
    profile = approval["profile"] if policy is route_gate else policy.PROFILE
    require(evidence.get("schema") == schema and evidence.get("profile") == profile,
            "Unknown or mixed RunV2 evidence schema and profile")
    return policy.check(candidate, evidence, approval)
