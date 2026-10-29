"""Qualify only the exact current-format4 automatic-backup maintenance pair."""

import time

from native_upgrade_common import require
from native_run_v2_inputs import digest
from native_run_v2_auto_source import BASELINE, BASELINE_PROGRAMS, SOURCE, check as source_check
from native_run_v2_auto_ci import Metadata, check as ci_check
from native_run_v2_auto_artifact import check as artifact_check
from native_run_v2_auto_dev import check as development_check
from native_run_v2_auto_writer_policy import approved as writer_policy

PROFILE = "run-v2-format4-auto-maintenance-v1"


def check(candidate, evidence, approval):
    require(evidence.get("schema") == "lastdb.run-v2-maintenance-evidence.v3"
            and approval.get("schema") == "lastdb.run-v2-maintenance-approval.v3"
            and evidence.get("profile") == approval.get("profile") == PROFILE
            and approval.get("mode") == "native-run-v2-ci"
            and evidence.get("source_git_oid") == approval.get("source_git_oid") == SOURCE
            and evidence.get("accepted_main_commit") == approval.get("accepted_main_commit") == SOURCE,
            "The exact automatic format4 profile, schema, or accepted source differs")
    require(approval.get("baseline_source_git_oid") == BASELINE
            and approval.get("baseline_programs_sha256") == BASELINE_PROGRAMS,
            "The automatic format4 baseline differs from the exact installed pair")
    proofs = {name: digest(evidence[name]) for name in (
        "artifact_receipt_sha256", "development_sha256", "compatibility_sha256")}
    require(approval.get("proofs") == proofs, "The automatic format4 approval binds another proof")
    source = source_check(evidence)
    metadata = Metadata()
    ci = ci_check(evidence, metadata)
    package = artifact_check(candidate, evidence, metadata)
    writer = writer_policy(approval)
    development = development_check(candidate, evidence, approval["memory_limit_mb"], writer)
    require(development.get("baseline_ordinary_reopen") is True,
            "The actual baseline did not reopen ordinary candidate-written DEV data")
    return {"profile": PROFILE, "source_review": source, **ci, "artifact": package,
            "development": development, "baseline_writer_policy": writer["result"], "checked_at": int(time.time())}
