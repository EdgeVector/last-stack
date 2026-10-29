#!/usr/bin/env python3
"""Prepare, then execute one explicitly approved exact-pair Mac DEV qualification."""
import argparse
import hashlib
import os
from pathlib import Path
import re
import time
import uuid

from native_run_v2_auto_qualify_data import Data, FIELD_MAP, NOTE_FIELD, file_spec
from native_run_v2_auto_qualify_catalog import binding as catalog_binding
from native_run_v2_inputs import external
from native_run_v2_auto_qualify_io import (BASELINE, BASELINE_PROGRAMS, SOURCE, freeze, hash_file,
    imports, private_dir, read, reference, require, save, secret)
from native_run_v2_auto_qualify_process import Pair

PROFILE = "run-v2-format4-auto-maintenance-v1"
MODULES = ("native_run_v2_auto_qualify", "native_run_v2_auto_qualify_io",
    "native_run_v2_auto_qualify_process", "native_run_v2_auto_qualify_data",
    "native_run_v2_auto_qualify_health",
    "native_run_v2_auto_qualify_http",
    "native_run_v2_auto_qualify_cloud", "native_run_v2_auto_qualify_catalog", "native_run_v2_auto_qualify_restore",
    "native_run_v2_auto_qualify_recoveries", "auto_recovery_manifest", "auto_recovery_files", "native_run_v2_inputs")
CANDIDATE_RECEIPT = "cd6d0e5e710f48524f127e25a67f1ef8d3f9c9777d16f37a3c9f18dca7891a82"
WRITER_POLICY_RECEIPT = "af1f22e02e694e883d06d28e45a2ac244e267626b0865dfbb9514f808b6b9cce"
WRITER_SETTINGS = {"LASTDB_AT_REST_RAW": "1", "LASTDB_KV_AT_REST_COMPRESS": "1", "LASTDB_KV_AT_REST_RAW": "1"}


def outside_primary(path):
    path = Path(path)
    require(path.is_absolute() and path.parent.resolve() == path.parent, "exact_named_path")
    primary = Path.home() / ".lastdb"
    archive = Path.home() / ".primary-lastdb-archive-20261014"
    for protected in (primary, archive):
        require(path != protected and protected not in path.parents and path not in protected.parents,
                "no_primary_or_archive")
    return path


def own_hashes():
    folder = Path(__file__).resolve().parent
    return {name + ".py": hash_file(folder / (name + ".py")) for name in MODULES}


def candidate(receipt):
    require(hash_file(receipt, 65536) == CANDIDATE_RECEIPT, "original_verified_candidate_receipt")
    value = read(receipt, 65536)
    require(value["schema"] == "lastdb.private-candidate-verification.v1"
            and value["source_git_oid"] == SOURCE and value["workflow_run"] == 40819457325
            and value["run_attempt"] == 1 and value["artifact_id"] == 12874018346
            and value["target"] == "aarch64-apple-darwin", "verified_exact_candidate_receipt")
    programs = {item["name"]: item["sha256"] for item in value["binaries"]}
    versions = {item["version"] for item in value["binaries"]}
    require(len(value["binaries"]) == 2 and set(programs) == {"lastdb", "lastdbd"}
            and len(versions) == 1 and all(item["architecture"] == "arm64"
            and item["strict_codesign"] is True for item in value["binaries"]), "matched_verified_candidate")
    return value, programs, next(iter(versions))


def writer_policy(path):
    original = reference(path)
    require(original["sha256"] == WRITER_POLICY_RECEIPT, "original_primary_writer_policy_receipt")
    value = read(path, 65536)
    require(value["schema"] == "lastdb.primary-writer-policy-observation.v1"
            and value["source"] == BASELINE and value["programs"] == BASELINE_PROGRAMS
            and value["settings"] == WRITER_SETTINGS and value["effective_process_matches_plist"] is True
            and value["primary_effects"] == 0
            and re.fullmatch(r"[0-9a-f]{64}", value["launchd_plist"]["sha256"])
            and type(value["session"]["pid"]) is int and value["session"]["pid"] > 0
            and type(value["session"]["start_ts"]) is int and value["session"]["start_ts"] > 0,
            "observed_primary_enb_writer_policy")
    return {"result": original, "observation": value,
            "scope": "primary-observed ENB writer profile; default and legacy CAS formats are not qualified"}


def prepare(args):
    root, homes = outside_primary(args.output), external(outside_primary(args.homes))
    require(not os.path.lexists(root) and not os.path.lexists(homes), "fresh_qualification_paths")
    for name in ("s", "r", "b", "t"):
        require(len(os.fsencode(homes / name / "data/folddb-full.sock.tmp")) <= 103, "socket_temporary_path")
    require(args.memory_limit_mb > 0 and bool(args.baseline_version), "explicit_baseline_and_memory_limit")
    for locator in (args.api_key_ref, args.phrase_ref):
        require(re.fullmatch(r"lastsecrets://[A-Za-z0-9][A-Za-z0-9._-]{0,127}", locator), "secret_locator_only")
    private_dir(root)
    _verified, programs, version = candidate(args.candidate_receipt)
    catalog = catalog_binding(args.catalog_read_result)
    policy = writer_policy(args.writer_policy_result)
    nonce = str(uuid.uuid4())
    records = [{"id": hashlib.sha256((nonce + ":" + str(number)).encode()).hexdigest(),
                "note": "application/x-lastdb-baseline-" + str(number),
                "final_note": "application/x-lastdb-candidate-" + str(number)}
               for number in range(16)]
    plan = {"schema": "lastdb.format4-auto-qualification-plan.v1", "profile": PROFILE, "protocol": 14,
        "environment": "dev", "source": SOURCE, "baseline_source": BASELINE,
        "programs": programs, "candidate_version": version,
        "baseline_programs": BASELINE_PROGRAMS, "baseline_version": args.baseline_version,
        "baseline_bin_dir": str(Path(args.baseline_bin_dir).resolve()),
        "candidate_bin_dir": str(Path(args.candidate_receipt).parent / "bin"),
        "candidate_receipt": reference(args.candidate_receipt), "source_repository": str(args.source_repository),
        "output": str(root), "homes": str(homes), "credential_home": str(outside_primary(args.credential_home)),
        "api_key_ref": args.api_key_ref, "phrase_ref": args.phrase_ref,
        "nonce": nonce, "records": records, "field_map": FIELD_MAP, "catalog": catalog, "writer_policy": policy,
        "files": [file_spec(nonce, n) for n in (1, 2)],
        "post_restart_rewrite": {"id": records[0]["id"], "note": records[0]["final_note"],
                                 "field": NOTE_FIELD, "same_value": True},
        "memory_limit_mb": args.memory_limit_mb, "frozen_helpers": freeze(Path(args.source_repository), root),
        "qualifier_sources": own_hashes(), "primary_access": False,
        "provider_scope": "selected-accepted-closures", "whole_account_reconciliation": False,
        "baseline_timestamp_policy": "exact-1d-boot-current-session-ledger; host-timestamp-recorded-separately",
        "candidate_timestamp_policy": "host-boot-current-session-ledger-equal",
        "operations": ["old exact accepted catalog load, fresh writes and clean stop", "candidate read/write/delete",
            "automatic snapshot and log", "normal restart with unchanged policy",
            "predeclared same-value rewrite and covered second log", "later snapshot",
            "old ordinary reopen and clean stop", "three source-free restores with two clean boots each"]}
    return save(root / "plan.json", plan)


def environment(operation):
    profiles = read(operation.root / "source/folddb_profile/environments.json", 65536)
    dev = profiles["environments"]["dev"]
    require(dev["region"] == "us-west-2" and dev["exemem_api"].startswith("https://"), "compiled_dev_only")
    policy = operation.plan["writer_policy"]
    require(policy == writer_policy(policy["result"]["path"]), "frozen_observed_writer_policy")
    operation.endpoint = dev["exemem_api"]
    return {**policy["observation"]["settings"],
        "PATH": str(Path.home() / ".local/bin") + ":/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "TZ": "UTC",
        "HOME": os.environ["HOME"], "TMPDIR": str(operation.root / "tmp"),
        "ENVIRONMENT": "dev", "EXEMEM_ENV": "dev", "EXEMEM_API_URL": dev["exemem_api"],
        "FOLD_SCHEMA_SERVICE_URL": dev["schema_service"], "LASTDB_DISK_FORMAT": "2",
        "LASTDB_BYTE_BACKUP_V2_ENABLED": "false", "LASTDB_NATIVE_BACKUP_ENABLED": "false",
        "LASTDB_SELF_METRICS_TO_DB": "false", "LASTDB_SUPPRESS_RECOVERY_PHRASE": "1",
        "LASTDB_TTL_SWEEP": "0", "RUST_LOG": "warn", "OBS_SENTRY_DSN": "", "POSTHOG_API_KEY": ""}


class Operation:
    def __init__(self, path, expected):
        require(reference(path)["sha256"] == expected, "approved_plan_hash")
        self.plan = read(path)
        require(self.plan["schema"] == "lastdb.format4-auto-qualification-plan.v1"
                and self.plan["profile"] == PROFILE and self.plan["protocol"] == 14
                and self.plan["source"] == SOURCE and self.plan["baseline_source"] == BASELINE
                and self.plan["qualifier_sources"] == own_hashes(), "unchanged_approved_qualification")
        self.root, self.homes = Path(self.plan["output"]), outside_primary(self.plan["homes"])
        private_dir(self.root)
        output = self.root / "operation"
        require(not os.path.lexists(output) and not os.path.lexists(self.homes), "one_new_qualification")
        output.mkdir(mode=0o700)
        self.output = output
        self.intent = save(self.output / "intent.json", {**self.plan, "plan": reference(path),
            "account": "2a81c95623f2445854a794b5b48471d6", "started_at": int(time.time())})
        self.operation_sha256 = self.intent["sha256"]
        self.helpers = imports(self.root, self.plan["frozen_helpers"])
        self.account = self.helpers.support.ACCOUNT
        self.homes.mkdir(mode=0o700)
        private_dir(self.root / "tmp")
        self.consumers, self.reads, self.summary, self.node = {}, {}, {}, None
        self.credentials = self.homes / "k"
        child_env = environment(self)
        for name in ("baseline-cli", "candidate-cli"):
            private_dir(self.output / name)
        self.baseline = Pair(self.helpers, self.plan["baseline_bin_dir"], self.plan["baseline_version"],
            child_env, BASELINE, BASELINE_PROGRAMS, self.output / "baseline-cli")
        receipt = self.plan["candidate_receipt"]
        require(reference(receipt["path"]) == receipt, "original_candidate_receipt")
        _, programs, version = candidate(receipt["path"])
        require(programs == self.plan["programs"] and version == self.plan["candidate_version"], "candidate_plan_binding")
        self.candidate = Pair(self.helpers, self.plan["candidate_bin_dir"], version, child_env, SOURCE,
                              programs, self.output / "candidate-cli")
        self.data = Data(self)

    def prepare_credentials(self):
        original = Path(self.plan["credential_home"])
        require(not (original / "data").exists() and not (original / "current-session.json").exists(),
                "existing_credential_only_dev_home")
        self.api_key, self.phrase = secret(self.plan["api_key_ref"]), secret(self.plan["phrase_ref"])
        for target in (self.homes / "s", self.credentials):
            result = self.candidate.command(original, ["cloud", "prepare-recovery-home", "--into", str(target),
                "--env", "dev", "--api-key-stdin", "--json"], self.api_key)
            require(result["identity_matches_source"] is True and result["data_directory_created"] is False,
                    "official_dev_credentials_only_preparation")

    def run(self):
        from native_run_v2_auto_qualify_cloud import run as automatic
        from native_run_v2_auto_qualify_recoveries import all_points
        self.prepare_credentials()
        flow = automatic(self)
        restores, provider = all_points(self, flow)
        self.summary.update(source=SOURCE, account=self.account, homes=str(self.homes), baseline_source=BASELINE,
            initial_automatic_snapshot=True, automatic_policy_survives_restart=True, separate_later_snapshot=True,
            source_free_restore=True, baseline_ordinary_reopen=True, exact_keyed_values_and_deletes=True,
            automatic_log_checkpoints=2, restored_boots=2, full_CAS_file_bytes=self.data.files,
            checkpoints={"base": flow["snapshot"], "log": flow["log"], "later": flow["later"]},
            catalog_load=self.catalog_load,
            writer_policy=self.plan["writer_policy"], default_cas_formats_qualified=False,
            observed_accepted=list(self.source.completed.values()),
            accepted_backup=flow["log"], primary_access=False, provider_bytes_scope="selected-accepted-closures")
        summary = save(self.output / "summary.json", self.summary)
        proof = {"schema": "lastdb.run-v2-automatic-development.v2", "profile": PROFILE, "protocol": 14,
            "environment": "dev", "source": SOURCE, "programs": self.plan["programs"],
            "baseline_source": BASELINE, "baseline_programs": BASELINE_PROGRAMS,
            "candidate_version": self.candidate.version, "completed_at": int(time.time()),
            "intent": self.intent, "summary": summary, "consumers": self.consumers,
            "reads": self.reads, "before_log_restart": flow["before_log_restart"],
            "after_log_restart": flow["after_log_restart"], "restore": restores["log"]["report"],
            "provider_accounting": provider, "memory_guard": self.memory_ref}
        return save(self.output / "development-proof.json", proof)


def arguments():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    plan = sub.add_parser("plan")
    for name in ("output", "homes", "source-repository", "baseline-bin-dir", "candidate-receipt", "credential-home",
                 "catalog-read-result", "writer-policy-result"):
        plan.add_argument("--" + name, required=True, type=Path)
    for name in ("baseline-version", "api-key-ref", "phrase-ref"):
        plan.add_argument("--" + name, required=True)
    plan.add_argument("--memory-limit-mb", type=int, required=True)
    run = sub.add_parser("run")
    run.add_argument("--plan", type=Path, required=True)
    run.add_argument("--approved-plan-sha256", required=True)
    run.add_argument("--execute", action="store_true", required=True)
    return parser.parse_args()


def main():
    os.umask(0o077)
    args = arguments()
    if args.action == "plan":
        result = prepare(args)
        print("Qualification plan: " + result["path"] + " SHA256 " + result["sha256"])
        return
    operation, result = Operation.__new__(Operation), {"status": "failed", "primary_access": False}
    operation.output, operation.node = None, None
    try:
        Operation.__init__(operation, args.plan, args.approved_plan_sha256)
        result = {"status": "passed", "primary_access": False, "proof": operation.run()}
    except BaseException as error:
        result["failure_class"] = type(error).__name__
        code = str(error)
        if re.fullmatch(r"[a-z][a-z0-9_]{0,99}", code):
            result["failure_code"] = code
        raise
    finally:
        if operation.output is not None:
            try:
                if operation.node is not None and operation.node.process is not None:
                    operation.node.cleanup_stop()
                require(operation.node is None or not operation.node.forced, "no_forced_qualification_stop")
            except BaseException as error:
                result.update(status="failed", cleanup_failure_class=type(error).__name__)
            if result["status"] == "failed":
                result["partial_summary"] = save(operation.output / "partial-summary.json",
                                                  getattr(operation, "summary", {}))
            save(operation.output / "result.json", result)
            operation.api_key, operation.phrase = None, None


if __name__ == "__main__":
    main()
