"""Exact typed-format4 maintenance with a full backup after the strict stop."""
from native_upgrade_common import require
from native_run_v2_auto_gate import qualification
from native_run_v2_auto_source import BASELINE, BASELINE_PROGRAMS
from native_run_v2_auto_final_policy import contract
from native_run_v2_stopped_writer import check as writer
from native_run_v2_auto_stopped_dev import check as stopped_development
from native_run_v2_final_recovery import request_id

PROFILE = "run-v2-format4-final-stopped-maintenance-v1"


def check(candidate, evidence, approval):
    require(evidence.get("schema") == "lastdb.run-v2-maintenance-evidence.v4"
            and approval.get("schema") == "lastdb.run-v2-maintenance-approval.v4"
            and evidence.get("profile") == approval.get("profile") == PROFILE
            and approval.get("mode") == "native-run-v2-ci" and approval.get("cloud_off") is True
            and "automatic_backup_enabled" not in approval,
            "The exact stopped typed-format4 profile differs")
    request_id(approval)
    contract(approval)
    current = writer(approval)["current"]["observation"]
    shared = qualification(candidate, evidence, approval, development_maximum_age_seconds=86400)
    stopped = stopped_development(candidate, evidence)
    return {"profile": PROFILE, **shared, "current_writer_policy": approval["current_writer_policy"],
            "baseline_recovery_state": approval["baseline_recovery_state"],
            "current_baseline_session": current["session"], "stopped_development": stopped}
