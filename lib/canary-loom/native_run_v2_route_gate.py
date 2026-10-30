"""Qualify one closed protein-removal route with the final stopped backup policy.

The gate keeps every check of the format4 final stopped profile: the reviewed
source map, exact CI and benchmark-complete, the Linux DEV operation, the
verified Mini pair, the observed ENB writer, the exact Mac DEV operation, and
a separate stopped DEV extension. Only the pinned pair and native marker change.
"""

import time

from native_upgrade_common import require
from native_run_v2_auto_final_policy import contract
from native_run_v2_final_recovery import request_id
from native_run_v2_inputs import digest
from native_run_v2_routes import APPROVAL, EVIDENCE, ROUTES, development, route
import native_run_v2_route_ci as ci
import native_run_v2_route_dev as dev_proofs
from native_run_v2_route_source import check as source_check
from native_run_v2_route_writer import baseline as baseline_writer, development as development_writer

PROFILES = tuple(ROUTES)
PROOFS = ("artifact_receipt_sha256", "development_sha256", "compatibility_sha256", "stopped_development_sha256")


def recovery_policy(selected):
    if selected["kind"] == "activation":
        return "accepted-stopped-native-cut-offline-activation-and-saved-pair"
    return "accepted-stopped-native-cut-and-saved-pair"


def activation_contract(approval, selected):
    value = approval.get("format_activation")
    if selected["kind"] != "activation":
        require(value is None, "A program route cannot name a format activation")
        return None
    require(value == {"from": selected["marker"].decode(), "to": selected["after"].decode(),
                      "command": "db enable-alternate-keys --i-know-this-is-primary --json",
                      "recovery": "same-pair-restart-forward-only"},
            "The activation route needs its exact offline activation contract")
    return value


def baseline_pair(candidate, evidence, approval, selected, metadata):
    """Bind the installed baseline pair to reviewed bytes without a new pin."""
    programs = approval.get("baseline_programs_sha256")
    require(isinstance(programs, dict) and set(programs) == {"lastdb", "lastdbd"}
            and all(digest(value) for value in programs.values()), "The baseline program pair is incomplete")
    if selected["baseline_programs"] is not None:
        require(programs == selected["baseline_programs"], "The baseline differs from the exact installed pair")
        return {"programs": programs, "binding": "pinned"}
    if selected["kind"] == "activation":
        require(programs == {name: value["sha256"] for name, value in candidate.items()},
                "An activation keeps the exact verified candidate pair")
        return {"programs": programs, "binding": "verified-candidate-pair"}
    pair = ci.receipt_pair(evidence["baseline_artifact_receipt"], evidence["baseline_artifact_receipt_sha256"], programs)
    verified = ci.artifact(pair, evidence["baseline_artifact_receipt"], evidence["baseline_artifact_receipt_sha256"],
                           evidence["baseline_artifact_archive"], metadata, evidence["source_repository"],
                           selected["baseline"])
    return {"programs": programs, "binding": "verified-baseline-mini-artifact", "artifact": verified}


def check(candidate, evidence, approval):
    selected = route(approval)
    require(evidence.get("schema") == EVIDENCE and approval.get("schema") == APPROVAL
            and evidence.get("profile") == approval.get("profile") == selected["profile"]
            and approval.get("mode") == "native-run-v2-ci" and approval.get("cloud_off") is True
            and "automatic_backup_enabled" not in approval
            and "current_writer_policy" not in approval and "baseline_recovery_state" not in approval,
            "The exact closed route profile differs")
    require(evidence.get("source_git_oid") == approval.get("source_git_oid") == selected["source"]
            and evidence.get("accepted_main_commit") == approval.get("accepted_main_commit") == selected["source"]
            and approval.get("baseline_source_git_oid") == selected["baseline"]
            and approval.get("recovery_policy") == recovery_policy(selected),
            "The closed route source, baseline, or recovery policy differs")
    request_id(approval)
    contract(approval)
    activation = activation_contract(approval, selected)
    proofs = {name: digest(evidence[name]) for name in PROOFS}
    require(approval.get("proofs") == proofs, "The route approval binds another proof")
    metadata = ci.Metadata()
    baseline = baseline_pair(candidate, evidence, approval, selected, metadata)
    writer = baseline_writer(approval)
    source = source_check(evidence, selected)
    checked = ci.check(evidence, metadata, selected["source"])
    package = ci.artifact(candidate, evidence["artifact_receipt"], evidence["artifact_receipt_sha256"],
                          evidence["artifact_archive"], metadata, evidence["source_repository"], selected["source"])
    dev = development(selected)
    dev_baseline = dev["baseline_programs"] if dev["baseline_programs"] is not None else baseline["programs"]
    dev_writer = development_writer(approval, dev, dev_baseline)
    developed = dev_proofs.main(candidate, evidence, approval["memory_limit_mb"], dev_writer, dev, dev_baseline)
    if selected["kind"] == "activation":
        stopped = dev_proofs.activation(candidate, evidence, selected, dev, dev_baseline)
    else:
        stopped = dev_proofs.stopped(candidate, evidence, selected, dev, dev_baseline)
    return {"profile": selected["profile"], "kind": selected["kind"], "source_review": source, **checked,
            "artifact": package, "baseline_pair": baseline, "baseline_writer_policy": writer["result"],
            "development_writer_policy": dev_writer["result"], "development": developed,
            "stopped_development": stopped, "format_activation": activation, "checked_at": int(time.time())}
