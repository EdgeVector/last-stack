"""Qualify one exact source-free restore before two caller-owned normal boots."""
from dataclasses import dataclass, field
import hashlib
import os
from pathlib import Path
import re
import stat

from native_run_v2_auto_qualify_io import hash_file, native_file_hash, read, reference, require, save

NODE = b"format=4\nhome=disk-run\ncas=disk-cas\nranges=typed-v1\n"
UUID = re.compile(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}")
MAX_FILES = 65552
PROFILE_SHA256 = "125896bca694dfbe3814ade693052312ae8498a973df5598e63ac1c80002011c"


@dataclass(frozen=True)
class Request:
    programs: object
    accepted: dict
    endpoint: str
    account: str
    credential_home: Path
    phrase: bytes = field(repr=False)
    destination: Path = None
    output: Path = None
    environment_name: str = "dev"
    compiled_profile: Path = None
    resume_session: Path = None
    # A closed route names its own marker and its frozen compiled profile.
    marker: bytes = NODE
    profile_sha256: str = PROFILE_SHA256


def names(path, maximum):
    metadata = path.lstat()
    require(path.resolve() == path and stat.S_ISDIR(metadata.st_mode) and metadata.st_uid == os.getuid()
            and stat.S_IMODE(metadata.st_mode) == 0o700, "private_exact_restore_directory")
    result = []
    with os.scandir(path) as entries:
        for entry in entries:
            require(len(result) < maximum and not entry.is_symlink(), "bounded_owned_directory")
            result.append(entry.name)
    return set(result)


def selection(accepted, account):
    job = accepted["begin"]["job"]
    stream, scope = job["stream"], job["stream"]["scope"]
    require(scope["account_id"] == account, "selected_account")
    return {"stream_id": stream["stream_id"], "account_generation": scope["account_generation"],
            "commit_id": job["commit_id"], "commit_sha256": accepted["commit_sha256"]}


def stable_identity(accepted):
    return {"job": accepted["begin"]["job"], "commit_sha256": accepted["commit_sha256"],
        "ordinal": accepted["ordinal"], "root_receipt_id": accepted["root_receipt_id"],
        "inventory_root": accepted["inventory_root"]}


def originals(request, report, before):
    parent = request.destination.parent
    added = names(parent, 64) - before
    if request.resume_session is None:
        sessions = [name for name in added if name.startswith(".byte-cloud-restore-")]
        require(len(sessions) == 1 and added == {request.destination.name, sessions[0]}, "fresh_restore_session")
    else:
        require(request.resume_session.parent == parent and request.resume_session.name in before
                and added == {request.destination.name}, "same_saved_restore_session")
        sessions = [request.resume_session.name]
    identifier = sessions[0][len(".byte-cloud-restore-"):]
    require(UUID.fullmatch(identifier) and identifier != "00000000-0000-0000-0000-000000000000",
            "restore_session_uuid")
    session = parent / sessions[0]
    selected = read(session / "selection.json")
    accepted = selected["accepted"]
    require(selected["version"] == 2 and selected["session_id"] == identifier
            and selected["destination"] == str(request.destination)
            and selected["endpoint"] == request.endpoint.rstrip("/") + "/api/cloud/backups/v2/"
            and stable_identity(accepted) == stable_identity(request.accepted), "exact_restore_selection")
    require(report["commit_sha256"] == accepted["commit_sha256"]
            and report["destination"] == str(request.destination)
            and report["file_dependencies_verified"] is True
            and report["native_files"] > 0 and report["native_bytes"] > 0
            and report["verified_external_files"] == 0, "complete_native_restore_report")
    receipt = read(request.destination / "byte-cloud-restore-receipt.json", 65536)
    require(receipt == {"version": 2, "session_id": identifier, "report": report}
            and read(session / "result.json") == report, "original_completed_restore_receipts")
    return session, accepted, {"selection": reference(session / "selection.json"),
        "result": reference(session / "result.json"),
        "receipt": reference(request.destination / "byte-cloud-restore-receipt.json")}


def native_files(destination, node=NODE):
    data = destination / "data"
    marker = data / "laststore-pack-node-v1"
    require(marker.stat().st_size == len(node)
            and hash_file(marker, len(node)) == hashlib.sha256(node).hexdigest(), "typed_format4_marker")
    paths = ["laststore-pack-node-v1"]
    for home in ("disk-run", "disk-cas"):
        root = data / home
        require(names(root, 8) == {"CURRENT", "laststore-run-home-v2", "LOCK", "runs"}, "native_home_closure")
        require((root / "LOCK").stat().st_size == 0, "native_lock_marker")
        paths.extend(home + "/" + name for name in ("CURRENT", "laststore-run-home-v2"))
        for name in sorted(names(root / "runs", MAX_FILES)):
            require(name.endswith(".ldrun") and UUID.fullmatch(name[:-6])
                    and name[:-6] != "00000000-0000-0000-0000-000000000000", "native_run_name")
            paths.append(home + "/runs/" + name)
    require(len(paths) <= MAX_FILES, "native_format_file_bound")
    files = []
    for relative in sorted(paths):
        path = data / relative
        size = path.stat().st_size
        require(size > 0, "native_file_length")
        files.append({"path": relative, "native_bytes": size, "native_sha256": native_file_hash(path, size)})
    return files


def snapshot_entries(session, files):
    expected = {item["path"]: item for item in files}
    entries = names(session / "entries", MAX_FILES)
    require(len(entries) == len(expected), "complete_snapshot_entry_proofs")
    result = []
    for name in sorted(entries):
        original = session / "entries" / name
        item = read(original)
        require(set(item) == {"path", "sha256", "bytes"} and item["path"] in expected
                and name == hashlib.sha256(item["path"].encode()).hexdigest(), "snapshot_entry_identity")
        file = expected.pop(item["path"])
        require(item["sha256"] == file["native_sha256"] and item["bytes"] == file["native_bytes"],
                "snapshot_entry_full_file_hash")
        result.append({**file, "native_proof": reference(original)})
    require(not expected, "snapshot_entry_closure")
    return result


def before_boot(request, session, accepted, originals_ref):
    home = request.destination
    forbidden = ("current-session.json", "boot-error.json", "data/folddb.sock", "data/folddb-full.sock",
                 "sessions.jsonl", ".shutdown_flush_ready")
    require(all(not os.path.lexists(home / name) for name in forbidden), "restore_precedes_first_boot")
    files = native_files(home, request.marker)
    report = read(request.output / "report.json")
    require(len(files) == report["native_files"] and sum(f["native_bytes"] for f in files) == report["native_bytes"],
            "restored_native_totals")
    has_chain = os.path.lexists(session / "chain/plan.json")
    value = {"schema": "lastdb.source-free-restore-native-observation.v1", "accepted_backup": accepted,
        "destination": str(home), "session": str(session), "before_first_boot": True,
        "originals": originals_ref, "files": files, "absent": list(forbidden),
        "native_file_closure_verified": True, "product_inventory_closure_verified": True,
        "independent_snapshot_native_hashes_verified": not has_chain}
    if not has_chain:
        value["native_files"] = snapshot_entries(session, files)
    else:
        plan, cursor = read(session / "chain/plan.json"), read(session / "chain/cursor.json")
        require(plan["head"] == cursor["head"] == accepted["commit_sha256"]
                and 1 <= plan["links"] <= 32768 and cursor["remaining"] == cursor["entry"] == cursor["part"] == 0
                and stable_identity(cursor["previous"]) == stable_identity(accepted), "complete_log_cursor")
        value.update(plan=reference(session / "chain/plan.json"), cursor=reference(session / "chain/cursor.json"))
    return save(request.output / "before-first-boot.json", value)


def qualify(request, node_factory, read_values, before_boot_capture=None, source_stopped=None, product_proof=None):
    """No source path is read; a caller may assert its separately owned source stop."""
    require(hash_file(request.compiled_profile, 65536) == request.profile_sha256, "exact_candidate_compiled_profile")
    profiles = read(request.compiled_profile, 65536)["environments"]
    require(hash_file(request.compiled_profile, 65536) == request.profile_sha256, "unchanged_compiled_profile")
    require(request.environment_name in ("dev", "prod")
            and request.endpoint == profiles[request.environment_name]["exemem_api"]
            and re.fullmatch(r"[0-9a-f]{32}", request.account)
            and request.programs.environment["ENVIRONMENT"] == request.environment_name
            and request.programs.environment["EXEMEM_ENV"] == request.environment_name
            and request.programs.environment["EXEMEM_API_URL"] == request.endpoint,
            "compiled_environment_and_account")
    require(request.destination.is_absolute() and request.destination.parent.resolve() == request.destination.parent
            and not os.path.lexists(request.destination), "absent_exact_restore_destination")
    request.output.mkdir(mode=0o700)
    if source_stopped is not None:
        source_stopped()
    before = names(request.destination.parent, 64)
    selected = selection(request.accepted, request.account)
    if request.resume_session is None:
        report = request.programs.restore(request.credential_home, request.destination, selected, request.phrase)
    else:
        report = request.programs.resume(request.credential_home, request.resume_session, request.phrase)
    report_ref = request.programs.last_response_ref
    require(read(report_ref["path"]) == report and reference(report_ref["path"]) == report_ref,
            "original_cli_restore_report")
    save(request.output / "report.json", report)
    session, accepted, refs = originals(request, report, before)
    refs["report"] = report_ref
    native = before_boot(request, session, accepted, refs)
    manifest = None
    if before_boot_capture is not None and not os.path.lexists(session / "chain/plan.json"):
        manifest = before_boot_capture(session, request.destination, accepted,
                                       request.endpoint.rstrip("/") + "/api/cloud/backups/v2/",
                                       request.output / "snapshot-native-manifest.json", report_ref)
    proof_ref = native
    if product_proof is not None:
        proof_ref = save(request.output / "product-native-proof.json", product_proof(report, accepted))
    reads, stops = [], []
    for number in range(2):
        if source_stopped is not None:
            source_stopped()
        node = node_factory(number)
        try:
            node.start()
            reads.append(read_values(node, number))
            node.stop()
            stops.append(True)
        finally:
            if node.process is not None:
                node.cleanup_stop()
        require(not node.forced and node.clean_stops == 1, "strict_owned_restore_stop")
    result = {"accepted_backup": accepted, "destination": str(request.destination), "session": str(session),
        **refs, "native_observation": native, "native_proof": proof_ref, "snapshot_manifest": manifest,
        "read_receipts": reads, "restored_boots": 2, "strict_clean_stops": len(stops)}
    save(request.output / "qualification.json", result)
    return result
