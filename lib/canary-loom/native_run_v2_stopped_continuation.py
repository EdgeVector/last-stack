"""Preserve one failed stopped attempt and authorize only two new current-file reads."""
import time
from pathlib import Path

from native_upgrade_common import require
from native_run_v2_inputs import reference, uint
from native_run_v2_stopped_files import current, diagnostic

ACTIONS = {"new_backup_requests": 0, "new_automatic_requests": 0, "new_source_free_restores": 0,
           "source_boots": 0, "owned_u_boots": 2, "user_mutations": 0, "primary_effects": 0}
SDK = ("accepted_backup", "destination", "session", "selection", "report", "result", "receipt",
       "native_observation", "native_proof", "snapshot_manifest")
SAME = ("parent_development", "source", "baseline_source", "programs", "baseline_programs", "account", "homes", "budget")


def original_records(proof, intent, observed):
    diagnostic_intent = reference(observed["intent"])
    prior = diagnostic_intent["prior"]
    old_owner, exit_record = [reference(prior[name]) for name in (
        "stopped-restored-first/owner.json", "stopped-restored-first/failed-child-exit.json")]
    require(old_owner.get("operation_sha256") == proof["original_attempt"]["intent"]["sha256"]
            and old_owner.get("home") == proof["restore"]["destination"]
            and exit_record.get("pid") == old_owner["pid"] and exit_record.get("returncode") == 0
            and exit_record.get("forced") is False and exit_record.get("strict_stop") is False,
            "The failed original child must retain its actual non-qualifying exit record")
    sdk = intent["original_sdk"]
    require(sdk["native_observation"] == prior["manual-recovery/before-first-boot.json"],
            "The continuation must use the original SDK preboot observation")
    native = reference(sdk["native_observation"], 32 * 1024 * 1024)
    require(all(sdk[name] == native["originals"][name] for name in ("selection", "report", "result", "receipt"))
            and sdk["accepted_backup"] == native["accepted_backup"]
            and sdk["destination"] == native["destination"] and sdk["session"] == native["session"],
            "The continuation changes the original completed SDK restore or its destination")
    folder = Path(proof["original_attempt"]["intent"]["path"]).parent
    paths = {"native_proof": folder / "manual-recovery/product-native-proof.json",
             "snapshot_manifest": folder / "manual-recovery/snapshot-native-manifest.json"}
    require(all(sdk[name]["path"] == str(path) for name, path in paths.items())
            and proof["stopped_backup"]["manifest"]["path"] == str(folder / "final-stopped-source.json")
            and proof["stopped_backup"]["stopped_files"]["path"] == str(folder / "verified-stopped-files.json"),
            "The original manual and SDK proof locations changed")


def check(proof, parent, summary, source_identity):
    attempt = proof.get("original_attempt")
    require(isinstance(attempt, dict) and set(attempt) == {"plan", "intent", "result"},
            "The stopped continuation lacks the exact original attempt")
    plan, original, failed = [reference(attempt[name]) for name in ("plan", "intent", "result")]
    intent = reference(proof["intent"])
    prepared = reference(intent["plan"])
    require(prepared.get("schema") == "lastdb.format4-stopped-current-plan.v1"
            and all(intent.get(key) == value for key, value in prepared.items() if key != "schema"),
            "The new continuation intent differs from its own original plan")
    require(plan.get("schema") == "lastdb.format4-stopped-development-plan.v1"
            and original.get("schema") == "lastdb.format4-stopped-development-intent.v1"
            and original.get("plan") == attempt["plan"]
            and all(original.get(key) == value for key, value in plan.items() if key != "schema")
            and failed.get("status") == "failed" and failed.get("failure_class") == "RuntimeError"
            and failed.get("failure_code") == "socket_http_status" and failed.get("intent") == attempt["intent"]
            and failed.get("primary_access") is False and failed.get("cleanup_failure_class") is None
            and proof["intent"] != attempt["intent"]
            and 0 <= time.time() - uint(original.get("started_at"), True) <= 3600,
            "The original stopped attempt or its actual file-read failure differs")
    require(intent.get("schema") == "lastdb.format4-stopped-development-continuation-intent.v1"
            and intent.get("profile") == proof["profile"] and intent.get("protocol") == 13
            and intent.get("original_attempt") == attempt and intent.get("diagnostic") == proof.get("diagnostic")
            and all(intent.get(name) == original.get(name) == proof.get(name) for name in SAME)
            and intent.get("no_user_writes") is True and intent.get("primary_access") is False
            and intent.get("action_bounds") == ACTIONS
            and all(type(value) is int for value in intent["action_bounds"].values())
            and intent.get("original_stopped_backup") == proof["stopped_backup"]
            and intent.get("original_adoption") == proof["adoption"]
            and set(intent.get("original_sdk", {})) == set(SDK)
            and all(proof["restore"].get(name) == intent["original_sdk"][name] for name in SDK),
            "The stopped continuation changes a source operation, SDK restore, or permitted action")
    required, expected = current(parent, summary)
    require(intent.get("current_expected") == proof.get("current_expected") == expected
            and intent.get("current_files") == proof.get("current_files") == required,
            "The current files do not derive from the original final expected record pointers")
    source_identity(intent)
    expected_sha = original["parent_final_records_sha256"]
    observed = diagnostic(proof, original, summary, required, expected_sha)
    original_records(proof, intent, observed)
    stop = reference(observed["strict_stop"]["stop"])
    require(intent.get("stop") == observed["strict_stop"]["stop"]
            and uint(intent.get("started_at"), True) >= uint(observed["finished_at"], True)
            and uint(proof["completed_at"], True) >= intent["started_at"],
            "The continuation does not start after the actual diagnostic clean stop")
    for refs in proof["consumers"].values():
        owner = reference(refs["owner"])
        require(uint(owner.get("start_ts"), True) >= max(stop["session"]["end_ts"], intent["started_at"])
                and (owner["pid"], owner["start_ts"]) != (stop["owner"]["pid"], stop["owner"]["start_ts"]),
                "A continuation consumer predates the diagnostic stopped session")
    return original, required
