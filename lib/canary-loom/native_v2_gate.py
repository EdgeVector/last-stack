"""Exact CI, operational proof, and reviewed native format compatibility gates."""

import hashlib
import json
from pathlib import Path
import re
import stat
import os
import time

from native_upgrade_common import regular, require, sha
from native_v2_artifact import verify as verify_archive
from native_v2_release import accepted_release, command_json, git
from native_v2_source import root as native_root

BASELINE = "0a9d8cf48470c21f0b7b9fef250a2d5598ca2b09"
PROTECTED = ("vendor/", "fold_db/", "lastdb_storage_policy/", "app_identity_crypto/",
             "lastdb_identity/", "schema_service/", "cloud_backup_protocol/", "lastdb_app_sdk/")
NEUTRAL = {
    "vendor/laststore/src/disk_pack/backup/export.rs",
    "fold_db/crates/core/src/storage/disk_pack/mod.rs",
    "fold_db/crates/core/src/fold_db_core/query/hash_range_query/pending_values.rs",
    "lastdb_storage_policy/src/lib.rs",
    "vendor/laststore/src/disk_pack/home.rs",
    "vendor/laststore/src/disk_pack/home/boundary.rs",
    "vendor/laststore/src/disk_pack/maintenance/cache.rs",
    "fold_db/crates/core/src/db_operations/atom_store/conflict_record/mod.rs",
    "fold_db/crates/core/src/db_operations/atom_store/counter/mod.rs",
    "fold_db/crates/core/src/db_operations/atom_store/counter/molecule.rs",
    "fold_db/crates/core/src/db_operations/atom_store/counter/recount/blobs.rs",
    "fold_db/crates/core/src/db_operations/atom_store/counter/restore_validation.rs",
    "fold_db/crates/core/src/db_operations/atom_store/counter/restore_validation/reader.rs",
    "fold_db/crates/core/src/db_operations/atom_store/counter/verify/state.rs",
    "fold_db/crates/core/src/db_operations/atom_store/delete_replay.rs",
    "fold_db/crates/core/src/db_operations/atom_store/locks.rs",
    "fold_db/crates/core/src/db_operations/atom_store/mod.rs",
    "fold_db/crates/core/src/fold_db_core/factory/local.rs",
    "fold_db/crates/core/src/fold_db_core/fold_db/init.rs",
    "fold_db/crates/core/src/storage/current_keys.rs",
    "fold_db/crates/core/src/storage/disk_pack/initialization.rs",
    "fold_db/crates/core/src/storage/disk_pack/read.rs",
    "fold_db/crates/core/src/storage/disk_pack/restore.rs",
    "fold_db/crates/core/src/storage/disk_pack/restore_safety.rs",
    "fold_db/crates/core/src/storage/disk_pack/transaction/request.rs",
    "fold_db/crates/core/src/storage/disk_pack/write.rs",
    "fold_db/crates/core/src/sync/auth/byte_backup/publication.rs",
    "fold_db/crates/core/src/sync/engine/bootstrap/snapshot.rs",
    "fold_db/crates/core/src/sync/engine/helpers/record_keys.rs",
    "fold_db/crates/core/src/sync/engine/replay/apply.rs",
    "fold_db/crates/core/src/sync/engine/replay/counter_writer.rs",
    "fold_db/crates/core/src/sync/engine/replay/decode.rs",
    "fold_db/crates/core/src/sync/engine/replay/entry.rs",
    "fold_db/crates/core/src/sync/engine/replay/fence.rs",
    "fold_db/crates/core/src/sync/engine/replay/merge.rs",
    "fold_db/crates/core/src/sync/engine/replay/mod.rs",
    "fold_db/crates/core/src/sync/engine/replay/records.rs",
    "fold_db/crates/core/src/sync/policy.rs",
    "fold_db/crates/core/src/sync/replay_diagnosis.rs",
    "fold_db/crates/core/src/sync/snapshot/current_format.rs",
    "fold_db/crates/core/src/sync/snapshot/mod.rs",
    "fold_db/crates/core/src/sync/snapshot/restore.rs",
    "fold_db/crates/core/src/sync/snapshot/restore_guard.rs",
    "fold_db/crates/core/src/sync/snapshot/restore_scan.rs",
    "fold_db/crates/core/src/sync/snapshot/restore_scan/clear.rs",
}


def private_json(path, maximum=1024 * 1024, expected_sha256=None):
    """Read one bounded owner-only FD snapshot, including an atomic rename race."""
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        before = os.fstat(fd)
        require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
                and not before.st_mode & 0o077 and before.st_size <= maximum,
                "Evidence must be a bounded private regular file")
        chunks, size = [], 0
        while True:
            part = os.read(fd, min(65536, maximum + 1 - size))
            if not part:
                break
            chunks.append(part)
            size += len(part)
            require(size <= maximum, "Evidence exceeds its bound")
        after = os.fstat(fd)
        require((before.st_ino, before.st_size, before.st_mtime_ns) ==
                (after.st_ino, after.st_size, after.st_mtime_ns), "Evidence changed during the read")
        data = b"".join(chunks)
        require(expected_sha256 is None or hashlib.sha256(data).hexdigest() == expected_sha256,
                "The exact private input hash differs")
        return json.loads(data)
    finally:
        os.close(fd)


def ci(candidate, evidence):
    source = evidence["source_git_oid"]
    release = accepted_release(evidence)
    value = command_json(["gh", "api", "repos/EdgeVector/lastdb/commits/" + source
                          + "/check-runs?filter=latest&per_page=100"])
    require(value["total_count"] <= 100, "CI check set exceeds its bound")
    for name in ("ci-required", "benchmark-complete"):
        matches = [v for v in value["check_runs"] if v["name"] == name]
        require(len(matches) == 1 and matches[0]["head_sha"] == source
                and matches[0]["status"] == "completed" and matches[0]["conclusion"] == "success"
                and matches[0]["app"]["slug"] == "github-actions", "Exact source CI gate failed: " + name)
    receipt = private_json(evidence["artifact_receipt"], 16384)
    require(receipt["source"] == source and receipt["programs"] ==
            {"bin/" + k: v["sha256"] for k, v in candidate.items()}, "CI artifact and pair differ")
    artifact = command_json(["gh", "api", "repos/EdgeVector/lastdb/actions/artifacts/"
                             + str(receipt["artifact_id"])])
    require(not artifact["expired"] and artifact["digest"] == receipt["github_archive_sha256"]
            and artifact["workflow_run"]["head_sha"] == source, "Mac artifact provenance differs")
    require(artifact["workflow_run"]["id"] == receipt["run"]
            and artifact["name"] == "lastdb-native-dev-arm64-" + source
            and 0 < artifact["size_in_bytes"] <= 512 * 1024 * 1024,
            "The exact CI artifact identity or size differs")
    run = command_json(["gh", "api", "repos/EdgeVector/lastdb/actions/runs/" + str(receipt["run"])])
    require(run["head_sha"] == source and run["conclusion"] == "success"
            and run["status"] == "completed"
            and run["path"] == ".github/workflows/native-dev-artifact.yml", "Mac artifact CI differs")
    regular(evidence["artifact_archive"], private=True, maximum=512 * 1024 * 1024)
    require(Path(evidence["artifact_archive"]).stat().st_size == artifact["size_in_bytes"]
            and sha(evidence["artifact_archive"]) == artifact["digest"].removeprefix("sha256:"),
            "Verified CI archive bytes differ")
    require(Path(receipt["bin_dir"]) == Path(candidate["lastdb"]["path"]).parent,
            "Candidate is not the verified CI pair")
    verify_archive(evidence["artifact_archive"], source, candidate)
    return release


def development(candidate, evidence):
    root = Path(evidence["dev_proof_root"])
    state = private_json(root / "run-state.json")
    proof = root / "proof"
    status = private_json(proof / "standalone-terminal-report.json")
    manifest_path = proof / "expected-native-files.json"
    require(str(manifest_path) == state["expected_native_files"], "DEV manifest path differs")
    manifest = private_json(manifest_path, expected_sha256=state["expected_native_manifest_sha256"])
    restored = private_json(proof / "source-free-restore.stdout")
    selection = private_json(proof / "source-free-selection.json")
    boundary = private_json(proof / "source-stopped-boundary.stdout")
    accepted = status["accepted_backup"]
    captured = native_root(status["captured_native_root"])
    require(state["client_source"] == evidence["source_git_oid"] and state["client_programs_sha256"] ==
            {k: v["sha256"] for k, v in candidate.items()}, "DEV proof used another program pair")
    require(state["standalone_dev_proof_complete"] is True and state["standalone_one_start_zero_resume"] is True
            and state["standalone_start_requests"] == 1 and state["standalone_resume_requests"] == 0
            and state["standalone_dev_proof_client"] == evidence["source_git_oid"]
            and state["source_free_restore_completed"] is True and state["stopped_boundary_exact"] is True
            and state["source_running"] is False and state["restored_running"] is False
            and state["restored_restart_verified"] is True and state["restored_read_passes"] == 2,
            "The exact candidate DEV backup, restore, and restart proof is incomplete")
    require(status["version"] == 1 and status["phase"] == "published" and status["terminal_clean"] is True
            and status["retained_source_bytes"] == state["source_held_bytes"] == 0
            and status["request_id"] == state["backup_request_id"]
            == accepted["begin"]["job"]["commit_id"] and status["blocked_reason"] is None
            and status["close_requested"] is False and accepted == state["dev_accepted_backup"]
            and accepted["begin"] == manifest["begin"] and accepted["version"] == 2
            and status["account_id"] == state["dev_account_id"]
            == accepted["begin"]["job"]["stream"]["scope"]["account_id"]
            and captured == manifest["native_root"] == state["captured_native_root"] == boundary["native_root"]
            and status["source_home"] == captured["home_id"]
            and boundary["version"] == 1 and boundary["metadata_only"] is True
            and boundary["writer_fence_held"] is False and boundary["account_id"] == status["account_id"]
            and boundary["identity_public_key"] == status["identity_public_key"],
            "DEV accepted result does not bind the frozen source")
    files = {f["path"]: f for f in manifest["files"]}
    require(len(files) == len(manifest["files"]) and files["CURRENT"]["native_sha256"] == captured["current_sha256"],
            "DEV native manifest has duplicate files or a different CURRENT")
    require(len(manifest["files"]) == restored["native_files"] == status["native_files"] > 0
            and sum(int(f["native_bytes"]) for f in manifest["files"]) ==
            restored["native_bytes"] == status["native_bytes"] > 0
            and restored["native_files"] == state["restored_native_files_exact"] == state["frozen_native_files"]
            and restored["native_bytes"] == state["restored_native_bytes_exact"] == state["frozen_native_bytes"]
            and restored["file_dependencies_verified"] is True
            and type(restored["verified_atoms"]) is int and restored["verified_atoms"] >= 0
            and status["objects_verified"] == state["frozen_transport_objects"] > 0
            and status["metadata_pack_objects"] > 0 and status["multi_file_pack_objects"] > 0,
            "DEV native bytes or packing proof differs")
    require(selection["commit_sha256"] == restored["commit_sha256"] == accepted["commit_sha256"]
            and selection["commit"] == state["backup_request_id"]
            and selection["generation"] == accepted["begin"]["job"]["stream"]["scope"]["account_generation"]
            and selection["stream"] == accepted["begin"]["job"]["stream"]["stream_id"],
            "DEV source-free restore selected another accepted backup")
    return {"request_id": state["backup_request_id"], "native_files": restored["native_files"],
            "native_bytes": restored["native_bytes"], "accepted_sha256": accepted["commit_sha256"]}


def tree(repo, source):
    result = {}
    for record in git(repo, "ls-tree", "-r", "-z", source).split(b"\0"):
        if record:
            header, name = record.decode().split("\t", 1)
            result[name] = header.split()[2]
    return result


def compatibility(evidence, baseline_source):
    require(sha(evidence["compatibility_record"]) == evidence["compatibility_sha256"],
            "Reviewed compatibility record changed")
    proof = private_json(evidence["compatibility_record"], 256 * 1024)
    source = evidence["source_git_oid"]
    require(baseline_source == BASELINE and proof["schema"] == "lastdb.native-source-compatibility.v1"
            and proof["baseline"] == BASELINE and proof["candidate"] == source,
            "Reviewed source compatibility binds another baseline or candidate")
    old, new = tree(evidence["source_repository"], BASELINE), tree(evidence["source_repository"], source)
    changes = {}
    for name in old.keys() | new.keys():
        protected = name.startswith(PROTECTED) or Path(name).name in (
            "Cargo.toml", "Cargo.lock", "rust-toolchain.toml") or name.startswith(".cargo/")
        if protected and old.get(name) != new.get(name):
            require(name in NEUTRAL or name.startswith("fold_db/crates/core/src/storage/disk_pack/byte_backup/"),
                    "An unreviewed writer, codec, feature or dependency changed: " + name)
            changes[name] = {"before": old.get(name), "after": new.get(name)}
    require(proof["reviewed_format_neutral_changes"] == changes,
            "The exact reviewed format-neutral source blobs differ")
    require(proof["source_reviewed"] is True
            and proof["no_native_format_change"] is True
            and proof["restore_migration_disallowed"] is True,
            "Normal-serving source compatibility review is absent")
    return {"baseline": BASELINE, "candidate": source, "format_neutral_changes": len(changes),
            "record_sha256": sha(evidence["compatibility_record"]), "backward_reopen_exercised": False}


def check(candidate, evidence, baseline_source, current=None, approval=None):
    require(re.fullmatch(r"[0-9a-f]{40}", evidence["source_git_oid"]) is not None,
            "Evidence requires the full candidate source")
    if baseline_source == "96f32b2ade27927019179fb57dc60f9c00a0ae68":
        from native_v2_maintenance import check as maintenance_check
        return maintenance_check(candidate, evidence, current, approval)
    return {"release_acceptance": ci(candidate, evidence), "development": development(candidate, evidence),
            "compatibility": compatibility(evidence, baseline_source), "checked_at": int(time.time())}
