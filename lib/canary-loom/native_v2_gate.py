"""Exact CI, operational proof, and reviewed native format compatibility gates."""

import hashlib
import json
from pathlib import Path
import re
import stat
import os
import time

from native_upgrade_common import path_id, regular, require, sha
from native_v2_artifact import verify as verify_archive
from native_v2_release import accepted_release, command_json, git
from native_v2_source import root as native_root

BASELINE = "0a9d8cf48470c21f0b7b9fef250a2d5598ca2b09"
PROTECTED = ("vendor/", "fold_db/", "lastdb_storage_policy/", "app_identity_crypto/",
             "lastdb_identity/", "schema_service/", "cloud_backup_protocol/", "lastdb_app_sdk/")
# SHA-256 of each reviewed format-neutral path (native_upgrade_common.path_id).
NEUTRAL = frozenset({
    "7489bf2201c35a4519450a1b921e4559788dab5b6854f99eda45211906fa5761",
    "d813d30f9ed25d18d8e34268716fb0cb094dcc63a84f709238428d30dc0a5056",
    "c5d5d2c7fbfbb0de55c74fd19c8fa065d0effe89a5d4163ae61a0666ddb6133d",
    "c20a42afc388cb33d2b0bffc6577d2fb4a6092c02bfcc45e1ecd801511803538",
    "1e35870a3910611cf9334a2a72687502e49a660fe23bf4d97952d0b3f890f88c",
    "f75147ac4d86b36db4c4a0ce887ba46e89baf6c6b64054f7363c8c2f377c6db9",
    "a5bbfdc353081ba2ae89d6b72f943268823256fd68a21831b99fb8373932f5bf",
    "b7da32d6dea181fc802f224811548baba87834f300b1253c700699a5ffedda56",
    "4327bef86664be3360514e516b46b7d674f39c00d0b10055e0010cbeab22a84d",
    "0a1b7a3ffe9717d8ec940ff778ed218a86dcfae02901440578ce5101525469b3",
    "403030fb4be965b12db55662c9259ae85251067efa62b5356004463dbebdb222",
    "5a193ffa4d8866a69a34a19b53d6b5b910271f6883e127e3b6d131968c36e1d9",
    "75008e107f88f75b84f6798db65ea96e648ef3388e1f66d65b8fcd58b05be715",
    "845ddd4f1701547ac2291a99e42fdfc278b46facb7e3fb645149b3979e5bdaf2",
    "2076c3ba6ac5cb3fc58e07f14db355262fb6dd561dc22eadd54fa7a031c00155",
    "7587be9ebc43e079640b16937f6750bdb8dbbe828d2dce6a46fc847af240c792",
    "616566b9698028caf6e1772512bac56ab53bbd04899c8182deae8c8f829d8e98",
    "e13fce2e68742a03315b43dfbf8f3bed430e2d54ebca78db636c933ef1942bca",
    "c3facd7379c4e430efafb7ea80102f8f8408baa87de4d969f3db9bd68bc608e8",
    "3d21090641f3af3660ec6e5583bb46157f92465aee7451098f54d192a3358959",
    "83fd6b36598a5ff5b15d153dbdb4fa91046b5a1d14b1d0e08ea26c557b623d07",
    "56e0714bea478073bc5d5b60b8d5f1a8dbd8872e3571f8fad91c7c48b79b2268",
    "c54489f77a1e73a0e24388967663547d1f859e265d30a281d221d2e29a8ac497",
    "5e39cdaeb97fef5687a0e8a4f9c993b95cf447f928bfe83d4f12d9aa61f4c11d",
    "dfaf10a3157d15b4eed38a78ac6bad9976b857149c07143a0227f38862f68702",
    "6a95e7cf4ef1136b74729a9674f8629bb8af4d2946b8d020578b8646a5492a49",
    "2e2024afa32edc0cf8bbde01e2824d07f86d46da48d1706acc16672d8d9afd9b",
    "e53f8c5c533a0cd1f1c4369d38b262007c2e56d4c132738660bd8667d78d7998",
    "bfcc5b53604fecb730365857afd538d64c7e0ea1283a9bc996f48f75830bcdeb",
    "653eef86398c39bcf50b33001ab3e10c23b1949c8915903a5eca7618687f4d6a",
    "de6a368b7f0469599e6e8c76d3bbbcac415a0ad5b487ebcd014a5282460a57d4",
    "03441c08d80ae179673da84e90c8bc6f60d467f71730202caf31b9a2f97946a6",
    "2f17a52877388578e93d4ca6a76d1e0f7164a1c4d8d5ee59b570f1d498384a2b",
    "05e78417a8d57685a640621b35b50bdc31dedf5135c95f563b50402e2861dc95",
    "1c84b591800b05cec26ea93a7b1acce5304cedc6dd98df34a11fb00e6f09af71",
    "a5d3aa13752570ea41e6487afa48497d12f4a4dc9f9eec3596238804f54b1cde",
    "76a784ced386a5b40d5105b9d8f87ecba11bfa9aa0bdfd67f379f091027a5d2d",
    "da953c05df04f42a86b625763844a08878f12e1511df9f5304d2c303519807fd",
    "4a346b45622452d0e96e62df71f61b3ecc0fbaad1edab02ace3ec856cc987800",
    "13d70be557479a4e9e8b2f16203b88902666ccdc443e02ba8c46c0e063a7da7f",
    "fcabe583e76b1bad808542c8d815d366b75476b493db7f5feaac9049bdd78640",
    "6ce121a763ef6d9e325380a7b52522c36081a9671efad3636dbfc67abdfc4da2",
    "7779f4a585503e1d16324e4fb51a60c4d0ee7e75fb6cb1b9bd7c80d8ac10cbbf",
    "9415b57fb1326a354c49f8e2fbfab5a7b3a14f656e7c2a2650229961a6c4242f",
    "b6088304ab848a6bccd302ae14f8bfead241f2e0772e2fe56abf1c1f0057cc2f",
})


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
            and type(restored["verified_records"]) is int and restored["verified_records"] >= 0
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
            require(path_id(name) in NEUTRAL or name.startswith("fold_db/crates/core/src/storage/disk_pack/byte_backup/"),
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
