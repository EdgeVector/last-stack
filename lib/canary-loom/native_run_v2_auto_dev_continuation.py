"""Bind one DEV continuation to its original completed operations and frozen cuts."""

from pathlib import Path
import hashlib
import json
import re

from native_upgrade_common import require
from native_run_v2_auto_qualify_io import hash_file
from native_run_v2_auto_source import BASELINE, BASELINE_PROGRAMS, SOURCE
from native_run_v2_auto_policy import head
from native_run_v2_inputs import digest, external, reference, uint, unwrap

ORIGINAL_BOOTS = ("baseline-source", "source-first", "source-second", "baseline-after-candidate",
                  "base-restored-first", "base-restored-second")
NEW_BOOTS = ("restored-first", "restored-second", "later-restored-first", "later-restored-second")
ORIGINAL_READS = ("candidate-reads-baseline-data", "source-after-two-logs", "baseline-reopens-candidate-data",
                  "base-restored-first", "base-restored-second")
NEW_READS = NEW_BOOTS
METADATA = ("snapshot_status", "log_status", "restarted_status", "later_status", "before_log_restart",
            "after_log_restart", "written_minimum", "base_qualification", "log_report", "log_observation",
            "initial_expected", "final_expected", "catalog_load", "post_restart_minimum")
ACTIONS = {"new_backup_requests": 0, "new_connections": 0, "new_captures": 0, "new_enrollments": 0,
           "new_log_restores": 0, "new_snapshot_restores": 1, "new_owned_boots": 4, "strict_clean_stops_required": 4}
SAME = ("source", "baseline_source", "programs", "baseline_programs", "homes", "account", "writer_policy")


def expected_operation(operation, label):
    # V2 keeps the existing single-intent operation identity without another check.
    return operation if isinstance(operation, str) else operation[label]


def code_sources(parent, intent, original):
    recorded = reference(parent["operator_code"])
    files = recorded.get("files")
    require(isinstance(files, dict) and 0 < len(files) <= 128 and uint(recorded.get("bytes"), True)
            and recorded.get("primary_data_copy") is False, "The original DEV source record is incomplete")
    folder = Path(recorded["source"])
    require(folder.is_absolute() and folder.resolve() == folder, "The original DEV source path is not canonical")
    sources = original.get("qualifier_sources")
    require(isinstance(sources, dict) and 0 < len(sources) <= 32
            and intent.get("qualifier_sources") == sources,
            "The continuation changes the original qualifier source identities")
    for name, checksum in sources.items():
        require(re.fullmatch(r"[a-z][a-z0-9_]*\.py", name) is not None
                and files.get(name) == digest(checksum),
                "An original qualifier source differs from its retained code record")
    added = intent.get("continuation_sources")
    require(isinstance(added, dict) and 0 < len(added) <= 128,
            "The continuation lacks its own bounded source identities")
    module_root = Path(__file__).resolve().parent
    for name, checksum in added.items():
        path = Path(name)
        if path.parent != module_root:
            external(path)
        require(path.is_absolute() and path.resolve() == path and path.suffix == ".py"
                and hash_file(path, 1048576) == digest(checksum), "A continuation source changed")


def original_inputs(proof, intent, summary):
    parent = proof.get("parent")
    require(isinstance(parent, dict) and set(parent) == {"plan", "intent", "failure", "operator_code"}
            and intent.get("parent") == summary.get("parent") == parent
            and summary.get("continuation_intent") == proof["intent"]
            and digest(parent["intent"]["sha256"]) != digest(proof["intent"]["sha256"]),
            "The continuation must retain a distinct original intent and failure")
    plan, original, failed = [reference(parent[name]) for name in ("plan", "intent", "failure")]
    require(plan.get("schema") == "lastdb.format4-auto-qualification-plan.v1"
            and original.get("plan") == parent["plan"]
            and all(original.get(key) == value for key, value in plan.items())
            and failed.get("status") == "failed" and failed.get("failure_class") == "OperationError"
            and failed.get("failure_code") == "restore_session_count"
            and failed.get("primary_access") is False and failed.get("cleanup_failure_class") is None,
            "The continuation does not follow the original observer-only session-count failure")
    require(intent.get("schema") == "lastdb.mac-dev-qualification-continuation-intent.v1"
            and all(intent.get(key) == plan.get(key) for key in SAME)
            and all(summary.get(key) == plan.get(key) for key in SAME if key not in ("programs", "baseline_programs"))
            and plan["source"] == SOURCE and plan["baseline_source"] == BASELINE
            and plan["baseline_programs"] == BASELINE_PROGRAMS
            and plan.get("primary_access") is intent.get("primary_access") is summary.get("primary_access") is False
            and intent.get("action_bounds") == ACTIONS
            and all(type(value) is int for value in intent["action_bounds"].values())
            and intent.get("original_boots") == list(ORIGINAL_BOOTS)
            and intent.get("continuation_boots") == list(NEW_BOOTS),
            "The continuation changes the approved pair, scope, roles, or permitted actions")
    code_sources(parent, intent, original)
    return parent, original


def checkpoints(intent, summary):
    metadata, cuts = intent.get("original_metadata"), intent.get("cuts")
    require(isinstance(metadata, dict) and set(metadata) == set(METADATA)
            and isinstance(cuts, dict) and set(cuts) == {"base", "log", "restarted", "later"},
            "The continuation lacks its exact original metadata and four cuts")
    loaded = {name: reference(value, 32 * 1024 * 1024 if name == "log_observation" else 1048576)
              for name, value in metadata.items()}
    for name, label in (("base", "snapshot_status"), ("log", "log_status"),
                        ("restarted", "restarted_status"), ("later", "later_status")):
        status, point = loaded[label], cuts[name]
        automatic = status.get("automatic_backup", {})
        require(status.get("last_accepted_backup") == point and status.get("phase") == "published"
                and status.get("running") is False and status.get("retained_source_bytes") == 0
                and status.get("request_id") == automatic.get("last_completed_request_id")
                == point["begin"]["job"]["commit_id"]
                and status.get("backup_kind") == ("snapshot" if name in ("base", "later") else "mutation_log"),
                "A frozen continuation cut lacks its original completed automatic status")
    require(summary.get("checkpoints") == {name: cuts[name] for name in ("base", "log", "later")}
            and summary.get("accepted_backup") == cuts["log"]
            and all(point in summary.get("observed_accepted", []) for point in cuts.values()),
            "The continuation retargets or omits an original accepted cut")
    stream = cuts["base"]["begin"]["job"]["stream"]
    require(all(point["begin"]["job"]["stream"] == stream for point in cuts.values())
            and stream["scope"]["account_id"] == intent["account"]
            and all(int(cuts[a]["ordinal"]) < int(cuts[b]["ordinal"])
                    for a, b in (("base", "log"), ("log", "restarted"), ("restarted", "later"))),
            "The original automatic cuts do not share one ordered DEV stream")
    return metadata, loaded, cuts


def check(proof, intent, summary):
    require(proof.get("schema") == "lastdb.run-v2-automatic-development.v3",
            "The explicit continuation development schema is required")
    parent, original = original_inputs(proof, intent, summary)
    metadata, loaded, cuts = checkpoints(intent, summary)
    require(proof.get("before_log_restart") == metadata["before_log_restart"]
            and proof.get("after_log_restart") == metadata["after_log_restart"]
            and intent.get("original_consumers") == {name: proof["consumers"][name] for name in ORIGINAL_BOOTS}
            and intent.get("original_reads") == {name: proof["reads"][name] for name in ORIGINAL_READS},
            "The continuation substitutes an original restart, boot, or read receipt")
    operation = Path(original["output"]) / "operation"
    for label in ORIGINAL_BOOTS:
        stage = proof["consumers"][label]
        require(stage["owner"]["path"] == str(operation / label / "owner.json")
                and stage["stop"]["path"] == str(operation / label / "stop.json"),
                "An original DEV boot or stop reference has another location")
    for label in ORIGINAL_READS:
        require(proof["reads"][label]["path"] == str(operation / (label + "-reads.json")),
                "An original DEV read reference has another location")
    for field, label in (("initial_expected", "candidate-reads-baseline-data"),
                         ("final_expected", "source-after-two-logs")):
        expected = hashlib.sha256(json.dumps(loaded[field], sort_keys=True, separators=(",", ":"),
                                             allow_nan=False).encode()).hexdigest()
        require(reference(proof["reads"][label]).get("records_sha256") == expected,
                "The continued DEV reads do not bind the original expected values")
    provider = reference(proof["provider_accounting"])
    restores = provider.get("restores", {})
    require(restores.get("base") == loaded["base_qualification"]
            and restores.get("log", {}).get("report") == loaded["log_observation"]["originals"]["report"]
            and restores.get("log", {}).get("native_observation") == metadata["log_observation"]
            and unwrap(reference(restores["log"]["report"])) == unwrap(loaded["log_report"])
            and unwrap(loaded["log_report"]).get("commit_sha256") == cuts["log"]["commit_sha256"],
            "The continuation replaces the completed base or log SDK restore")
    log_proof = reference(restores["log"]["native_proof"], 32 * 1024 * 1024)
    minimum = head(loaded["written_minimum"]["mutation_log"]["head"])
    rewritten = head(loaded["post_restart_minimum"]["after"])
    require(log_proof.get("written_minimum") == minimum and rewritten["epoch"] == minimum["epoch"]
            and rewritten["sequence"] > minimum["sequence"]
            and summary.get("catalog_load") == metadata["catalog_load"],
            "The selected log minimum or original catalog proof changed")
    old, new = digest(parent["intent"]["sha256"]), digest(proof["intent"]["sha256"])
    return {**{label: old for label in (*ORIGINAL_BOOTS, *ORIGINAL_READS)},
            **{label: new for label in (*NEW_BOOTS, *NEW_READS, "memory_guard")}}
