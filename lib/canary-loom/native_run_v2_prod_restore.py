#!/usr/bin/env python3
"""Restore a frozen current PROD point without a primary lifecycle or backup action."""

import argparse
import os
from pathlib import Path
import stat
from types import SimpleNamespace

from mnemonic import Mnemonic

from auto_recovery_manifest import capture
from native_run_v2_auto_qualify_io import (BASELINE, BASELINE_PROGRAMS, SOURCE, freeze, hash_file,
    imports, private_dir, read, reference, require, save)
from native_run_v2_auto_qualify_process import Pair, node
from native_run_v2_auto_qualify_restore import Request, names, qualify, selection
from native_run_v2_prod_observe import ACCOUNT, PRIMARY, primary, records, snapshot_base, specifications
from native_run_v2_inputs import external

BASELINE_VERSION = "nightly-20261027-297e4b039-71-g1d4b205bb"


def sources():
    folder = Path(__file__).resolve().parent
    paths = [folder / name for name in ("native_run_v2_auto_qualify_io.py",
        "native_run_v2_auto_qualify_process.py", "native_run_v2_auto_qualify_health.py",
        "native_run_v2_auto_qualify_http.py", "native_run_v2_auto_qualify_restore.py",
        "native_run_v2_prod_restore.py", "native_run_v2_prod_observe.py", "native_run_v2_prod_chain.py",
        "auto_recovery_manifest.py", "auto_recovery_files.py", "native_run_v2_inputs.py",
        "native_upgrade_common.py", "native_run_v2_state.py", "native_run_v2_recovery.py",
        "native_v2_read.py", "native_run_v2_auto_policy.py")]
    require(0 < len(paths) <= 32, "bounded_restore_operator_sources")
    return {path.name: hash_file(path) for path in paths}


def candidate(receipt):
    value = read(receipt, 65536)
    require(value.get("schema") == "lastdb.private-candidate-verification.v1"
            and value.get("source_git_oid") == SOURCE and value.get("workflow_run") == 40819457325
            and value.get("run_attempt") == 1 and value.get("artifact_id") == 12874018346
            and value.get("target") == "aarch64-apple-darwin", "verified_exact_prod_candidate_receipt")
    binaries = value["binaries"]
    programs = {item["name"]: item["sha256"] for item in binaries}
    versions = {item["version"] for item in binaries}
    require(len(binaries) == 2 and set(programs) == {"lastdb", "lastdbd"} and len(versions) == 1
            and all(item["architecture"] == "arm64" and item["strict_codesign"] is True for item in binaries),
            "matched_verified_prod_candidate")
    return programs, next(iter(versions))


def prepare(args):
    root, homes = external(args.output), external(args.homes)
    require(not os.path.lexists(root) and not os.path.lexists(homes), "fresh_prod_restore_paths")
    require(len(os.fsencode(homes / "r/data/folddb-full.sock.tmp")) <= 103, "prod_restore_socket_path")
    programs, version = candidate(args.candidate_receipt)
    expected = BASELINE_PROGRAMS if args.primary_source == BASELINE else programs
    current_version = BASELINE_VERSION if args.primary_source == BASELINE else version
    specs = specifications(args.keyed_read_input)
    before = primary(expected, current_version)
    values = records(PRIMARY / "data/folddb.sock", specs)
    core, base = snapshot_base(before["accepted"])
    require(primary(expected, current_version) == before, "unchanged_primary_selection_read_bookends")
    private_dir(root)
    plan = {"schema": "lastdb.current-prod-restore-plan.v1", "candidate_source": SOURCE,
        "candidate_receipt": reference(args.candidate_receipt), "programs": programs, "version": version,
        "candidate_bin_dir": str(Path(args.candidate_receipt).parent / "bin"),
        "primary_source": args.primary_source, "primary_programs": expected, "primary_version": current_version,
        "before": before, "base": base, "original_snapshot_core": core,
        "queries": specs, "expected_read_digests": values, "output": str(root), "homes": str(homes),
        "credential_home": str(external(args.credential_home)),
        "source_repository": str(args.source_repository), "operator_sources": sources(),
        "frozen_helpers": freeze(args.source_repository, root),
        "primary_lifecycle_actions": 0, "cloud_backup_requests": 0, "primary_data_copy": False}
    return save(root / "plan.json", plan)


def environment(root):
    profile = read(root / "source/folddb_profile/environments.json", 65536)["environments"]["prod"]
    endpoint = profile["exemem_api"]
    require(endpoint.startswith("https://") and profile["region"] == "us-east-1", "compiled_prod_environment")
    values = {"PATH": str(Path.home() / ".local/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin",
        "HOME": str(Path.home()), "LANG": "C", "TZ": "UTC", "TMPDIR": str(root / "tmp"),
        "ENVIRONMENT": "prod", "EXEMEM_ENV": "prod", "EXEMEM_API_URL": endpoint,
        "FOLD_SCHEMA_SERVICE_URL": profile["schema_service"], "LASTDB_DISK_FORMAT": "2",
        "LASTDB_BYTE_BACKUP_V2_ENABLED": "false", "LASTDB_NATIVE_BACKUP_ENABLED": "false",
        "LASTDB_SELF_METRICS_TO_DB": "false", "LASTDB_SUPPRESS_RECOVERY_PHRASE": "1",
        "LASTDB_TTL_SWEEP": "0", "RUST_LOG": "warn", "OBS_SENTRY_DSN": "", "POSTHOG_API_KEY": ""}
    return values, endpoint


def recovery_phrase(home, endpoint):
    require(home.resolve() == home and not (home / "data").exists()
            and not (home / "current-session.json").exists(), "existing_prod_credentials_only_home")
    credentials = read(home / "cloud_sync.json.paused", 65536)
    require(set(credentials) == {"api_url", "api_key"} and credentials["api_url"] == endpoint,
            "existing_prod_credentials_endpoint")
    del credentials
    path = home / "identity.key"
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        info = os.fstat(descriptor)
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid()
                and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size == 32, "protected_prod_identity_seed")
        seed = os.read(descriptor, 33)
        require(len(seed) == 32 and os.fstat(descriptor).st_ino == info.st_ino
                and os.fstat(descriptor).st_mtime_ns == info.st_mtime_ns
                and path.lstat().st_ino == info.st_ino, "stable_prod_identity_seed")
        return Mnemonic("english").to_mnemonic(seed).encode()
    finally:
        os.close(descriptor)


def discovery(pair, credentials, phrase, accepted):
    stream = accepted["begin"]["job"]["stream"]
    cursor, selected = None, []
    for _page in range(1024):
        arguments = ["cloud", "backup-v2", "discover", "--recovery-phrase-stdin", "--generation",
                     stream["scope"]["account_generation"], "--json"]
        if cursor is not None:
            arguments += ["--cursor", cursor]
        value = pair.command(credentials, arguments, phrase)
        require(value.get("scope") == stream["scope"] and isinstance(value.get("streams"), list),
                "authenticated_prod_stream_discovery")
        selected += [item for item in value["streams"] if item.get("stream") == stream]
        next_cursor = value.get("next_cursor")
        if next_cursor is None:
            break
        require(isinstance(next_cursor, str) and next_cursor != cursor and len(next_cursor) <= 4096,
                "prod_discovery_cursor_progress")
        cursor = next_cursor
    else:
        require(False, "prod_discovery_page_bound")
    require(len(selected) == 1 and selected[0].get("accepted") == accepted
            and selected[0].get("active_commit_id") is None, "frozen_prod_head_is_current_in_cloud")
    return selected[0]


def run(plan_path, expected):
    require(reference(plan_path)["sha256"] == expected, "original_prod_restore_plan_hash")
    plan = read(plan_path)
    require(plan["schema"] == "lastdb.current-prod-restore-plan.v1" and plan["candidate_source"] == SOURCE
            and plan["operator_sources"] == sources(), "unchanged_prod_restore_operator")
    root, homes = external(plan["output"]), external(plan["homes"])
    output = root / "operation"
    require(not os.path.lexists(output) and not os.path.lexists(homes), "one_fresh_prod_restore")
    output.mkdir(mode=0o700)
    homes.mkdir(mode=0o700)
    private_dir(root / "tmp")
    context = SimpleNamespace(root=root, homes=homes, owned_homes={homes / "r"}, output=output,
        account=ACCOUNT, operation_sha256=expected, helpers=None, consumers={}, node=None)
    result, words = {"status": "failed", "primary_lifecycle_actions": 0, "cloud_backup_requests": 0}, None
    try:
        context.helpers = imports(root, plan["frozen_helpers"])
        values, endpoint = environment(root)
        pair = Pair(context.helpers, plan["candidate_bin_dir"], plan["version"], values,
                    SOURCE, plan["programs"], private_dir(output / "cli"))
        require(reference(plan["candidate_receipt"]["path"]) == plan["candidate_receipt"],
                "original_prod_candidate_verification")
        require(candidate(plan["candidate_receipt"]["path"]) == (plan["programs"], plan["version"]),
                "original_prod_candidate_pair_binding")
        credentials = Path(plan["credential_home"])
        words = recovery_phrase(credentials, endpoint)
        cloud = discovery(pair, credentials, words, plan["before"]["accepted"])
        save(output / "cloud-head.json", cloud)
        require(primary(plan["primary_programs"], plan["primary_version"]) == plan["before"],
                "same_frozen_covered_primary_before_restore")
        request = Request(pair, plan["before"]["accepted"], endpoint, ACCOUNT, credentials, words,
            homes / "r", output / "recovery", environment_name="prod",
            compiled_profile=root / "source/folddb_profile/environments.json")

        def observe(current, number):
            found = records(current.socket, plan["queries"])
            require(found == plan["expected_read_digests"], "restored_prod_application_values_equal_primary")
            return save(output / ("restored-read-" + str(number) + ".json"), {
                "owner": current.owner, "accepted": request.accepted, "read_digests": found})

        def product_proof(report, accepted):
            from native_run_v2_prod_chain import verified
            sessions = [p for p in homes.iterdir() if p.name.startswith(".byte-cloud-restore-")]
            require(len(sessions) == 1, "one_owned_prod_restore_session")
            if (sessions[0] / "chain/plan.json").exists():
                return verified(sessions[0], accepted, plan["before"]["journal_head"],
                                lambda path: read(path, 262144),
                                lambda path: names(path, 65538), expected_base=plan["base"])
            return {"kind": "snapshot", "accepted_backup": accepted,
                    "product_inventory_closure_verified": True, "file_dependencies_verified": report["file_dependencies_verified"]}

        restored = qualify(request, lambda n: node(context, homes / "r", pair, "restored-" + str(n)),
                           observe, capture, product_proof=product_proof)
        final = primary(plan["primary_programs"], plan["primary_version"])
        require(final["session"] == plan["before"]["session"], "primary_process_unchanged_during_cloud_restore")
        result.update(status="passed", restore=restored, frozen_primary=plan["before"], primary_after=final,
                      primary_native_payload_files_read=False, provider_scope="selected-accepted-closure")
        return save(output / "verified.json", result)
    except BaseException as error:
        result["failure_class"] = type(error).__name__
        raise
    finally:
        if context.node is not None and context.node.process is not None:
            context.node.cleanup_stop()
        if context.node is not None and context.node.forced:
            result.update(status="failed", forced_owned_restore_stop=True)
        save(output / "result.json", result)
        words = None


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    plan = sub.add_parser("plan")
    for name in ("output", "homes", "source-repository", "candidate-receipt", "credential-home", "keyed-read-input"):
        plan.add_argument("--" + name, type=Path, required=True)
    plan.add_argument("--primary-source", choices=(BASELINE, SOURCE), required=True)
    execute = sub.add_parser("run")
    execute.add_argument("--plan", type=Path, required=True)
    execute.add_argument("--approved-plan-sha256", required=True)
    execute.add_argument("--execute", action="store_true", required=True)
    args = parser.parse_args()
    value = prepare(args) if args.action == "plan" else run(args.plan, args.approved_plan_sha256)
    print("PROD restore record: " + value["path"] + " SHA256 " + value["sha256"])


if __name__ == "__main__":
    main()
