"""Bind original RunV2 DEV publication, restore, and ordinary backward reads."""

import hashlib
import json
import os
from pathlib import Path
import re
import time
import uuid

from native_upgrade_common import alive, require
from native_run_v2_compatibility import BASELINE, BASELINE_PROGRAMS
from native_run_v2_inputs import digest, external, read, reference, uint, unwrap

LOGICAL_BYTES = 8 * 1024 * 1024
READS = 16
FILE = re.compile(r"disk-(run|cas)/(?:CURRENT|laststore-run-home-v2|runs/[0-9a-f-]{36}\.ldrun)")


def decimal(value):
    require(isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]{0,19}", value) is not None
            and int(value) < 2**64, "A native decimal counter is invalid")
    return int(value)


def canonical_uuid(value):
    require(isinstance(value, str), "A native UUID is absent")
    parsed = uuid.UUID(value)
    require(parsed.int != 0 and str(parsed) == value, "A native UUID is not canonical")
    return value


def owned_home(path):
    path = external(path)
    require(path.resolve() == path and path.is_dir() and path.stat().st_uid == os.getuid()
            and not path.stat().st_mode & 0o077, "A retained DEV home is absent or unsafe")
    return path


def stopped(value, expected):
    require(isinstance(expected, dict) and set(expected) == {"pid", "start_ts"}
            and all(uint(expected[name], True) for name in expected),
            "A DEV stopped session is invalid")
    require(value.get("receipt") == {"version": 1, **expected, "flush_ok": True}
            and type(value["receipt"]["version"]) is int and value["receipt"]["flush_ok"] is True
            and isinstance(value.get("session"), dict)
            and all(value["session"].get(name) == item for name, item in expected.items())
            and value["session"].get("exit") == "clean"
            and uint(value["session"].get("end_ts"), True) >= expected["start_ts"]
            and not alive(expected["pid"]), "The original DEV session is not cleanly stopped")


def profile(value, root):
    require(isinstance(value, dict) and set(value) == {"version", "main", "cas"}
            and type(value["version"]) is int and value["version"] == 1,
            "The original RunV2 profile is invalid")
    for home in (value["main"], value["cas"]):
        require(set(home) == {"home_id", "generation", "frontier", "descriptor_sha256",
                              "current_sha256", "files", "bytes"}, "A RunV2 home profile differs")
        canonical_uuid(home["home_id"])
        require(decimal(home["generation"]) > 0
                and decimal(home["frontier"]) <= decimal(home["generation"])
                and uint(home["files"], True) >= 2 and uint(home["bytes"], True) >= 64,
                "A RunV2 home counter is invalid")
        digest(home["descriptor_sha256"])
        digest(home["current_sha256"])
    require(value["main"]["home_id"] != value["cas"]["home_id"], "DEV run homes share an identity")
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    require(root["home_id"] == value["main"]["home_id"]
            and root["generation"] == value["main"]["generation"]
            and root["frontier"] == value["main"]["frontier"]
            and root["current_sha256"] == value["main"]["current_sha256"]
            and root["home_digest"] == hashlib.sha256(encoded).hexdigest()
            and decimal(root["required_features"]) == 176, "The full RunV2 root binding differs")


def native_manifest(value, accepted, run, root):
    require(value.get("schema") == "lastdb.run-v2-native-files.v1"
            and value.get("begin") == accepted["begin"] and value.get("run_profile") == run
            and value.get("native_root") == root, "The original native manifest names another cut")
    files, seen, totals = value.get("files"), set(), {"disk-run": [0, 0], "disk-cas": [0, 0]}
    require(isinstance(files, list) and bool(files), "The original native manifest is empty")
    for file in files:
        name, length = file["path"], decimal(file["native_bytes"])
        digest(file["native_sha256"])
        require(name not in seen and length > 0, "The original native manifest repeats a file")
        seen.add(name)
        if name == "laststore-pack-node-v1":
            require(length == 36, "The original node marker has another length")
            continue
        require(FILE.fullmatch(name) is not None, "The native manifest has an unsupported path")
        if "/runs/" in name:
            canonical_uuid(name.split("/")[-1].removesuffix(".ldrun"))
        home = name.split("/")[0]
        totals[home][0] += 1
        totals[home][1] += length
        label = name.split("/")[-1]
        if label in ("CURRENT", "laststore-run-home-v2"):
            key = "current_sha256" if label == "CURRENT" else "descriptor_sha256"
            require(file["native_sha256"] == run["main" if home == "disk-run" else "cas"][key],
                    "The manifest selector or descriptor digest differs")
    require("laststore-pack-node-v1" in seen, "The node marker is absent")
    for home, key in (("disk-run", "main"), ("disk-cas", "cas")):
        require({home + "/CURRENT", home + "/laststore-run-home-v2"} <= seen
                and totals[home] == [run[key]["files"], run[key]["bytes"]],
                "The original paired file totals differ")
    return len(files), sum(decimal(file["native_bytes"]) for file in files)


def read_pass(value, records_sha, file_sha):
    require(value.get("records") == READS and type(value.get("records")) is int
            and value.get("records_sha256") == records_sha
            and value.get("file_bytes") == LOGICAL_BYTES and type(value.get("file_bytes")) is int
            and value.get("file_sha256") == file_sha,
            "The ordinary known-key or complete logical file read differs")


def backward(evidence, proof, accepted, run):
    value = read(evidence["baseline_reopen_proof"], 1024 * 1024, evidence["baseline_reopen_sha256"])
    require(value.get("schema") == "lastdb.run-v2-baseline-reopen.v1"
            and value.get("baseline_source") == BASELINE
            and value.get("baseline_programs_sha256") == BASELINE_PROGRAMS
            and value.get("home_path") == proof["restored_home_path"]
            and value.get("accepted_commit_sha256") == accepted["commit_sha256"]
            and value.get("home_ids") == {name: run[name]["home_id"] for name in ("main", "cas")}
            and value.get("ordinary_product_read") is True and value.get("schema_initialized") is False
            and value.get("record_mutations") == 0 and type(value.get("record_mutations")) is int
            and value.get("primary_data_copy") is False and value.get("daemon_stopped") is True,
            "The ordinary baseline reopen proof is incomplete")
    require(proof["completed_at"] <= uint(value.get("completed_at"), True) <= time.time(),
            "The baseline reopen predates the complete candidate restore proof")
    read_pass(reference(value["read_receipt"]), proof["records_sha256"], proof["logical_file_sha256"])
    stopped(reference(value["stop_receipt"]), value["session"])
    return {"source": BASELINE, "receipt_sha256": evidence["baseline_reopen_sha256"],
            "records": READS, "logical_file_bytes": LOGICAL_BYTES}


def check(candidate, evidence):
    proof = read(evidence["development_proof"], 1024 * 1024, evidence["development_sha256"])
    require(proof.get("schema") == "lastdb.run-v2-development.v1"
            and proof.get("environment") == "dev" and proof.get("client_source") == evidence["source_git_oid"]
            and proof.get("client_programs_sha256") == {k: v["sha256"] for k, v in candidate.items()},
            "The original DEV proof names another environment or exact CI pair")
    completed = uint(proof.get("completed_at"), True)
    require(completed <= time.time(), "The completed RunV2 DEV proof is in the future")
    source, restored = owned_home(proof["source_home_path"]), owned_home(proof["restored_home_path"])
    require(source != restored and source not in restored.parents and restored not in source.parents,
            "The source and restored DEV homes overlap")
    for name in ("source_stopped", "restored_stopped", "source_free_restore",
                 "restored_without_cloud_credentials", "provider_routes_verified",
                 "transport_integrity_verified", "raw_native_files_verified"):
        require(proof.get(name) is True, "A required RunV2 DEV operation is incomplete")
    for name in ("records_sha256", "logical_file_sha256"):
        digest(proof[name])
    accepted, run, root = proof["accepted_backup"], proof["run_profile"], proof["native_root"]
    profile(run, root)
    scope = accepted["begin"]["job"]["stream"]["scope"]
    require(accepted["begin"].get("descriptor") is None
            and accepted["begin"].get("required_destinations") == ["r2", "b2"]
            and scope["account_id"] == proof["account_id"]
            and scope["account_generation"] == proof["account_generation"],
            "The routed DEV authority or native source identity differs")
    stream = reference(proof["source_binding"])
    require(set(stream) == {"source_home", "stream"}
            and stream["source_home"] == run["main"]["home_id"]
            and stream["stream"] == accepted["begin"]["job"]["stream"],
            "The original transport stream names another native source")
    canonical_uuid(stream["stream"]["stream_id"])
    decimal(proof["account_generation"])
    status = unwrap(reference(proof["backup_status"]))
    recorded = status.get("last_accepted_backup", status.get("accepted_backup"))
    require(recorded == accepted and type(accepted.get("version")) is int and accepted["version"] == 2
            and accepted["begin"]["job"]["commit_id"] == proof["request_id"]
            and status.get("request_id") == proof["request_id"] and status.get("phase") == "published"
            and status.get("running") is False and status.get("retained_source_bytes") == 0
            and type(status.get("retained_source_bytes")) is int and status.get("blocked_reason") is None,
            "The DEV job is not the exact published and released operation")
    canonical_uuid(proof["request_id"])
    digest(accepted["commit_sha256"])
    manifest = reference(proof["native_manifest"])
    count, length = native_manifest(manifest, accepted, run, root)
    raw_files = reference(proof["raw_file_verification"])
    require(raw_files.get("schema") == "lastdb.run-v2-restored-files.v1"
            and raw_files.get("home_path") == proof["restored_home_path"]
            and raw_files.get("accepted_commit_sha256") == accepted["commit_sha256"]
            and raw_files.get("before_first_boot") is True and raw_files.get("files") == manifest["files"],
            "The original pre-boot complete file hash proof differs")
    restore = unwrap(reference(proof["restore_report"]))
    require(restore.get("commit_sha256") == accepted["commit_sha256"]
            and restore.get("destination") == proof["restored_home_path"]
            and restore.get("native_files") == status.get("native_files") == count
            and restore.get("native_bytes") == status.get("native_bytes") == length
            and restore.get("file_dependencies_verified") is True
            and uint(restore.get("verified_atoms"), True) > 0
            and uint(status.get("objects_verified"), True) > 0
            and uint(status.get("metadata_pack_objects"), True) > 0
            and uint(status.get("multi_file_pack_objects"), True) > 0,
            "The exact restored cut, native bytes, or transport packing proof differs")
    reads = reference(proof["read_restart"])
    require(reads.get("restart_count") == 1 and type(reads.get("restart_count")) is int
            and isinstance(reads.get("passes"), list) and len(reads["passes"]) == 2,
            "The ordinary restored restart proof is incomplete")
    for result in reads["passes"]:
        read_pass(result, proof["records_sha256"], proof["logical_file_sha256"])
    stopped(reference(proof["source_stop"]), proof["source_session"])
    stopped(reference(proof["restored_stop"]), proof["restored_session"])
    reopened = backward(evidence, proof, accepted, run)
    return {"source": evidence["source_git_oid"], "receipt_sha256": evidence["development_sha256"],
            "accepted_sha256": accepted["commit_sha256"], "native_files": count, "native_bytes": length,
            "records": READS, "logical_file_bytes": LOGICAL_BYTES, "baseline_reopen": reopened,
            "completed_at": completed}
