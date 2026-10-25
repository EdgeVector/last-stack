"""A closed second-upgrade baseline from the completed exact native5 CI release."""

import hashlib
from pathlib import Path
import re
import time

from native_upgrade_common import require
from native_v2_gate import private_json

SOURCE = "96f32b2ade27927019179fb57dc60f9c00a0ae68"
BOOTSTRAP_SOURCE = "0a9d8cf48470c21f0b7b9fef250a2d5598ca2b09"
JOURNAL_SHA256 = "192486fae6a63e000b1ed841692aecde103f4d5f9885c6d2ddde01b969d1826b"
APPROVAL_SHA256 = "1f189b9cf4abec3389124129dc5fe4aadff0c60d1cb862b3f36f763404352131"


def evidence_path(value):
    require(isinstance(value, str) and 0 < len(value) <= 4096, "The prior proof path is absent")
    path = Path(value)
    require(path.is_absolute() and path.resolve() == path, "The prior proof path is not canonical")
    return path


def check(evidence, current, current_approval):
    proof = evidence.get("baseline_provenance")
    require(isinstance(proof, dict) and set(proof) == {
        "schema", "journal_path", "journal_sha256", "approval_path", "approval_sha256"},
        "The exact96 baseline requires its closed completed predecessor")
    require(proof["schema"] == "lastdb.completed-native-v2-baseline.v1"
            and proof["journal_sha256"] == JOURNAL_SHA256 and proof["approval_sha256"] == APPROVAL_SHA256,
            "The exact96 completed predecessor binding differs")
    journal_path, approval_path = evidence_path(proof["journal_path"]), evidence_path(proof["approval_path"])
    journal = private_json(journal_path, expected_sha256=JOURNAL_SHA256)
    approval = private_json(approval_path, 65536, expected_sha256=APPROVAL_SHA256)
    binding = journal["binding"]
    require(journal.get("schema") == "lastdb.native-v2-ci-upgrade.v1" and journal.get("phase") == "complete"
            and binding.get("source_git_oid") == SOURCE and binding.get("upgrade_mode") == "native-v2-ci"
            and binding.get("safe_upgrade_protocol_version") == "10" and binding.get("native_reopen") is False
            and binding.get("native_approval") == str(approval_path)
            and binding.get("native_approval_sha256") == APPROVAL_SHA256,
            "The exact96 prior operation did not complete through mode10")
    digest = hashlib.sha256("\0".join(str(binding[k]) for k in (
        "source_git_oid", "candidate", "candidate_cli", "lastdbd_sha256", "lastdb_sha256",
        "lastdbd_version", "lastdb_version")).encode()).hexdigest()
    require(digest == binding["candidate_artifact_digest"], "The prior CI pair digest differs")
    key = hashlib.sha256((digest + APPROVAL_SHA256).encode()).hexdigest()
    expected = Path.home() / ".local/state/last-stack/lastdb-safe-upgrade/native-v2-ci" / key / "state.json"
    require(journal_path == expected, "The completed predecessor is not its original journal")
    require(approval.get("schema") == "lastdb.native-v2-ci-approval.v1"
            and approval.get("source_git_oid") == SOURCE and approval.get("approved_by") == "Tom"
            and approval.get("mode") == "native-v2-ci" and approval.get("primary_data_copy") is False
            and approval.get("primary_restore_or_migration") is False
            and approval.get("baseline_source_git_oid") == BOOTSTRAP_SOURCE,
            "The prior approval does not authorize the exact native5 release")
    require(isinstance(current_approval, dict) and current_approval.get("baseline_source_git_oid") == SOURCE
            and current_approval.get("primary_home") == approval["primary_home"]
            and current_approval.get("launchd_plist") == approval["launchd_plist"]
            and all(current_approval["recovery"].get(key) == approval["recovery"][key] for key in (
                "account_id", "identity_public_key", "home_id", "home_digest", "environment")),
            "The new recovery authority does not bind the original account and native home")
    pair = journal["candidate"]
    require(set(pair) == {"lastdb", "lastdbd"} and approval.get("candidate") == pair
            and all(pair[name]["sha256"] == binding[name + "_sha256"]
                    and pair[name]["version"] == binding[name + "_version"] for name in pair),
            "The prior approved and completed program pairs differ")
    directory = Path(journal["candidate_directory"])
    expected_pair = {name: {**value, "path": str(directory / name)} for name, value in pair.items()}
    require(isinstance(current, dict) and current.get("pair") == expected_pair
            and current.get("stable") == journal["baseline"]["stable"]
            and current.get("plist_sha256") == journal["candidate_plist_sha256"],
            "The installed exact96 pair, primary configuration or native identity differs")
    compatibility = journal["gates"]["compatibility"]
    require(compatibility.get("baseline") == BOOTSTRAP_SOURCE and compatibility.get("candidate") == SOURCE
            and journal["live"]["health"]["version"] == pair["lastdbd"]["version"]
            and journal["live"]["health"].get("cloud_off") is True
            and isinstance(journal.get("execution"), str) and 0 < len(journal["execution"]) <= 256,
            "The completed predecessor source or final health binding differs")
    completed = journal.get("completed_at")
    require(type(completed) is int and 0 < completed <= time.time(), "The predecessor completion time is invalid")
    require(all(re.fullmatch(r"[0-9a-f]{64}", value["sha256"]) is not None for value in pair.values()),
            "The prior program hashes are invalid")
    return {"source": SOURCE, "prior_execution": journal["execution"], "prior_completed_at": completed,
            "journal_sha256": JOURNAL_SHA256, "approval_sha256": APPROVAL_SHA256,
            "programs_sha256": {name: value["sha256"] for name, value in pair.items()}}
