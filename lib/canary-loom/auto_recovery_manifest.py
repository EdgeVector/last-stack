"""Bind an actual preboot snapshot restore to the exact accepted recovery cut."""

import hashlib
import os
import time
import uuid

from native_upgrade_common import require, save
from native_run_v2_inputs import digest, external, reference, uint, unwrap
from auto_recovery_files import ABSENT, MAXIMUM, closure, destination, files, names, original, recorded_closure

ORIGIN = "completed-source-free-snapshot-restore"
SCHEMA = "lastdb.completed-snapshot-native-manifest.v1"
OBSERVATION = "lastdb.snapshot-before-first-boot.v1"
REFS = ("restore_selection", "restore_report", "restore_result", "restore_receipt")


def chain_state(session):
    path = session / "chain"
    present = os.path.lexists(path)
    entries = names(path) if present else []
    require(not entries, "A snapshot proof must not contain a mutation-log replay chain")
    return {"directory_present": present, "entries": entries}


def binding(session, restored, accepted, endpoint, references):
    selected, report, result, receipt = [unwrap(reference(references[name], MAXIMUM)) for name in REFS]
    identifier = session.name.removeprefix(".byte-cloud-restore-")
    parsed = uuid.UUID(identifier)
    require(session.name == ".byte-cloud-restore-" + str(parsed) and parsed.int != 0
            and session.parent == restored.parent and session.resolve() == session,
            "The original snapshot session does not own the fresh destination")
    require(references["restore_selection"]["path"] == str(session / "selection.json")
            and references["restore_result"]["path"] == str(session / "result.json")
            and references["restore_receipt"]["path"] == str(restored / "byte-cloud-restore-receipt.json"),
            "The snapshot original proof references have another location")
    require(selected.get("version") == 2 and selected.get("session_id") == identifier
            and selected.get("destination") == str(restored) and selected.get("endpoint") == endpoint
            and selected.get("accepted") == accepted and accepted.get("version") == 2
            and accepted["begin"].get("descriptor") is None
            and accepted["begin"].get("required_destinations") == ["r2", "b2"],
            "The original snapshot selection differs from the accepted recovery cut")
    require(report == result and receipt == {"version": 2, "session_id": identifier, "report": report}
            and report.get("commit_sha256") == accepted["commit_sha256"]
            and report.get("destination") == str(restored)
            and report.get("file_dependencies_verified") is True
            and uint(report.get("native_files"), True) > 0
            and uint(report.get("native_bytes"), True) > 0
            and uint(report.get("verified_atoms"), True) > 0
            and uint(report.get("verified_external_files")) == 0,
            "The original completed snapshot report or receipt differs")
    return identifier, report


def capture(session, restored, accepted, endpoint, output, report_ref):
    """Record the actual preboot state; never call this after any restored boot."""
    session, restored, output = external(session), destination(restored), external(output)
    observed_path = output.with_name(output.stem + ".before-first-boot.json")
    require(not os.path.lexists(output) and not os.path.lexists(observed_path),
            "The original snapshot observation must not overwrite prior evidence")
    references = {name: original(path)[0] for name, path in (
        ("restore_selection", session / "selection.json"), ("restore_result", session / "result.json"),
        ("restore_receipt", restored / "byte-cloud-restore-receipt.json"))}
    references["restore_report"] = report_ref
    identifier, report = binding(session, restored, accepted, endpoint, references)
    chain = chain_state(session)
    require(all(not os.path.lexists(restored / name) for name in ABSENT),
            "The snapshot proof requires a never-started destination and no log replay")
    native = files(session, restored)
    native_closure, homes = closure(restored, native)
    require(len(native) == report["native_files"]
            and sum(item["native_bytes"] for item in native) == report["native_bytes"],
            "The complete snapshot native hashes do not match the restore totals")
    require(all(not os.path.lexists(restored / name) for name in ABSENT)
            and chain_state(session) == chain, "The restored home started during its preboot proof")
    observation = {"schema": OBSERVATION, "origin": ORIGIN, "observed_at": int(time.time()),
                   "session_id": identifier, "session": str(session), "destination": str(restored),
                   "accepted_backup": accepted, **references, "native_files": native,
                   "native_home_ids": homes, "native_closure": native_closure,
                   "absent": list(ABSENT), "log_chain": chain, "before_first_boot": True}
    save(observed_path, observation)
    observed_ref = original(observed_path)[0]
    manifest = {"schema": SCHEMA, "origin": ORIGIN, "accepted_backup": accepted,
                "session": str(session), "destination": str(restored), **references,
                "before_first_boot_observation": observed_ref, "native_files": native}
    save(output, manifest)
    return original(output)[0]


def observation(manifest, accepted, endpoint):
    session, restored = external(manifest["session"]), destination(manifest["destination"])
    identifier, report = binding(session, restored, accepted, endpoint, manifest)
    value = reference(manifest["before_first_boot_observation"], MAXIMUM)
    require(value.get("schema") == OBSERVATION and value.get("origin") == ORIGIN
            and value.get("session_id") == identifier and value.get("session") == str(session)
            and value.get("destination") == str(restored) and value.get("accepted_backup") == accepted
            and all(value.get(name) == manifest[name] for name in REFS)
            and value.get("native_files") == manifest["native_files"]
            and value.get("absent") == list(ABSENT)
            and isinstance(value.get("log_chain"), dict)
            and set(value["log_chain"]) == {"directory_present", "entries"}
            and type(value["log_chain"]["directory_present"]) is bool and value["log_chain"]["entries"] == []
            and value.get("before_first_boot") is True
            and 0 < uint(value.get("observed_at"), True) <= time.time(),
            "The immutable original pre-first-boot snapshot observation differs")
    return value, report


def profile(native, observed, expected, version=2):
    require(expected.get("version") == version, "The recovery snapshot has another native profile")
    by_path = {item["path"]: item for item in native}
    require(len(by_path) == len(native) and by_path, "The snapshot native proof repeats or omits its files")
    for folder, label in (("disk-run", "main"), ("disk-cas", "cas")):
        home = expected[label]
        members = [item for item in native if item["path"].startswith(folder + "/")]
        require(observed["native_home_ids"][folder] == home["home_id"]
                and by_path[folder + "/CURRENT"]["native_sha256"] == home["current_sha256"]
                and by_path[folder + "/laststore-run-home-v2"]["native_sha256"] == home["descriptor_sha256"]
                and len(members) == home["files"]
                and sum(item["native_bytes"] for item in members) == home["bytes"],
                "The original restored snapshot files do not bind the captured source profile")


def check(approval, core):
    recovery = approval["recovery"]
    accepted = recovery["accepted_backup"]
    manifest = reference(recovery["native_manifest"], MAXIMUM)
    require(manifest.get("schema") == SCHEMA and manifest.get("origin") == ORIGIN
            and manifest.get("accepted_backup") == accepted and core.get("begin") == accepted["begin"]
            and core.get("terminal", {}).get("status") == {"state": "published", "backup": accepted},
            "The recovery manifest does not bind the original accepted snapshot and captured source")
    observed, report = observation(manifest, accepted, recovery["endpoint"])
    native = manifest["native_files"]
    require(isinstance(native, list) and 0 < len(native) <= 1000000
            and len(native) == report["native_files"] == core["native_files"]
            and sum(uint(item["native_bytes"], True) for item in native)
                == report["native_bytes"] == core["native_bytes"], "The original snapshot file list is incomplete")
    session = external(manifest["session"])
    for item in native:
        digest(item["native_sha256"])
        proof = reference(item["native_proof"], 4096)
        require(proof == {"path": item["path"], "sha256": item["native_sha256"], "bytes": item["native_bytes"]}
                and item["native_proof"]["path"] == str(session / "entries" / hashlib.sha256(item["path"].encode()).hexdigest()),
                "An original snapshot native proof changed or names another file")
    from native_run_v2_routes import run_version, stopped_marker
    recorded_closure(native, observed, stopped_marker(approval))
    profile(native, observed, core["run"], run_version(approval))
    return {**manifest, "begin": core["begin"], "run_profile": core["run"], "native_root": core["native_root"],
            "profile_origin": "captured-source-profile-bound-by-complete-restored-native-hashes"}
