#!/usr/bin/env python3
"""Continue one retained PROD restore without a new selection or backup request."""

import argparse
import os
from pathlib import Path
import time
from types import SimpleNamespace

from native_upgrade_common import call, session, sha
from native_run_v2_auto_qualify_io import (SOURCE, hash_file, imports, private_dir, read,
                                          reference, require, save)
from native_run_v2_auto_qualify_process import Pair, node
from native_run_v2_auto_qualify_restore import Request, names, qualify
from native_run_v2_prod_chain import verified
from native_run_v2_prod_continue_state import admission, operator_owner, owner_probe, snapshot
from native_run_v2_prod_observe import ACCOUNT, PRIMARY, records
from native_run_v2_prod_restore import candidate, environment, recovery_phrase, sources as original_sources
from native_run_v2_inputs import external

ORIGINAL_PLAN = "38dfae0a58b23c593b942111841acd23e26fb0f4460309beae0adfe80c6e274a"
ORIGINAL_FAILURE = "eda9480829a739e19bbf59bf83ee69409098f6fc0845b0b2c20aa4685df8a43b"
GRANT_EVIDENCE = "55930eb4ff6ec007c18714f1285c2e95e30f47eef2e2624e6c982febeb459627"
SESSION_ID = "f3b08bcb-73db-49d4-b456-73fff2a2c368"


def sources():
    result = original_sources()
    folder = Path(__file__).resolve().parent
    for name in ("native_run_v2_prod_continue.py", "native_run_v2_prod_continue_state.py",
                 "native_run_v2_dev_session.py", "native_run_v2_auto_source.py"):
        result[name] = hash_file(folder / name)
    return result


def original(path):
    require(reference(path)["sha256"] == ORIGINAL_PLAN, "exact_original_prod_plan")
    value = read(path)
    failure = Path(value["output"]) / "operation/result.json"
    require(value.get("schema") == "lastdb.current-prod-restore-plan.v1"
            and value.get("candidate_source") == SOURCE and value["before"]["accepted"]["ordinal"] == "13"
            and value.get("primary_lifecycle_actions") == value.get("cloud_backup_requests") == 0
            and value.get("primary_data_copy") is False, "original_prod_plan_scope")
    require(reference(failure)["sha256"] == ORIGINAL_FAILURE
            and read(failure).get("status") == "failed", "immutable_original_prod_failure")
    return value, reference(failure)


def primary_owner(before):
    identity = session(PRIMARY)
    boot = call(PRIMARY / "data/folddb.sock", "/api/system/boot-identity")
    require(identity == before["before"]["session"] and boot.get("pid") == identity["pid"]
            and boot.get("process_start_ts") == identity["start_ts"]
            and boot.get("build") == before["primary_version"] and (PRIMARY / "current").is_symlink(),
            "same_original_primary_process")
    directory = (PRIMARY / "current").resolve()
    require({name: sha(directory / name) for name in ("lastdb", "lastdbd")} == before["primary_programs"]
            and session(PRIMARY) == identity, "same_original_primary_program_pair")
    return {"session": identity, "programs": before["primary_programs"], "version": before["primary_version"]}


def prepare(args):
    original_plan, failure = original(args.original_plan)
    target, retained = external(args.output), external(args.session)
    require(retained.name == ".byte-cloud-restore-" + SESSION_ID
            and retained.parent == Path(original_plan["homes"])
            and not os.path.lexists(target), "exact_retained_session_and_new_output")
    require(reference(args.grant_evidence)["sha256"] == GRANT_EVIDENCE, "exact_actual_grant_admission")
    require(reference(original_plan["candidate_receipt"]["path"]) == original_plan["candidate_receipt"]
            and candidate(original_plan["candidate_receipt"]["path"])
                == (original_plan["programs"], original_plan["version"]), "original_candidate_pair")
    owner = primary_owner(original_plan)
    with owner_probe(retained):
        before = snapshot(original_plan, retained)
        grant = admission(args.grant_evidence, before)
    private_dir(target)
    observed = save(target / "saved-before.json", before)
    current_sources = sources()
    value = {"schema": "lastdb.prod-restore-continuation-plan.v1", "created_at": int(time.time()),
             "source": SOURCE, "original_plan": reference(args.original_plan), "original_failure": failure,
             "session": str(retained), "before_state": observed, "grant_admission": grant,
             "primary_owner": owner, "output": str(target), "sources": current_sources,
             "source_changes": {name: {"original": digest, "continuation": current_sources.get(name)}
                                for name, digest in original_plan["operator_sources"].items()
                                if current_sources.get(name) != digest},
             "selected_commit_sha256": before["selection"]["accepted"]["commit_sha256"],
             "selected_ordinal": "13", "retarget_current_head": False, "new_restore_sessions": 0,
             "primary_lifecycle_actions": 0, "cloud_backup_requests": 0, "original_error_cause_known": False}
    return save(target / "plan.json", value)


class RetainedPair(Pair):
    def bind_resume(self, original_plan, retained, before):
        self.original_plan, self.retained, self.before = original_plan, retained, before

    def resume(self, home, retained, phrase):
        require(retained == self.retained, "unchanged_product_resume_path")
        with owner_probe(retained):
            require(snapshot(self.original_plan, retained) == self.before, "saved_state_changed_before_resume")
        # The product must obtain its own authoritative owner/native locks.
        # A competing owner after this probe makes the official CLI refuse.
        return super().resume(home, retained, phrase)


def proof(original_plan, retained, report, accepted):
    require(accepted == original_plan["before"]["accepted"]
            and report["commit_sha256"] == accepted["commit_sha256"], "unchanged_continued_restore_cut")
    return verified(retained, accepted, original_plan["before"]["journal_head"],
                    lambda path: read(path, 262144), lambda path: names(path, 65538),
                    expected_base=original_plan["base"])


def execute_plan(plan, original_plan, path, output):
    original_root, retained = Path(original_plan["output"]), Path(plan["session"])
    before = read(plan["before_state"]["path"], 32 * 1024 * 1024)
    require(reference(plan["before_state"]["path"]) == plan["before_state"], "retained_actual_before_state")
    values, endpoint = environment(original_root)
    context = SimpleNamespace(root=original_root, homes=Path(original_plan["homes"]),
        owned_homes={Path(before["destination"])}, output=output, account=ACCOUNT,
        operation_sha256=reference(path)["sha256"], helpers=None, consumers={}, node=None)
    words = None
    result = {"schema": "lastdb.prod-restore-continuation-result.v1", "status": "failed",
              "selected_ordinal": "13", "new_restore_sessions": 0, "cloud_backup_requests": 0,
              "primary_lifecycle_actions": 0, "original_error_cause_known": False,
              "original_failure": plan["original_failure"], "grant_admission": plan["grant_admission"]}
    try:
        context.helpers = imports(original_root, original_plan["frozen_helpers"])
        pair = RetainedPair(context.helpers, original_plan["candidate_bin_dir"], original_plan["version"],
                            values, SOURCE, original_plan["programs"], private_dir(output / "cli"))
        pair.bind_resume(original_plan, retained, before)
        require(primary_owner(original_plan) == plan["primary_owner"], "primary_owner_before_continuation")
        credentials = Path(original_plan["credential_home"])
        words = recovery_phrase(credentials, endpoint)
        request = Request(pair, original_plan["before"]["accepted"], endpoint, ACCOUNT, credentials, words,
            Path(before["destination"]), output / "recovery", environment_name="prod",
            compiled_profile=original_root / "source/folddb_profile/environments.json", resume_session=retained)

        def observe(current, number):
            found = records(current.socket, original_plan["queries"])
            require(found == original_plan["expected_read_digests"], "continued_restored_values_equal_original_cut")
            return save(output / ("restored-read-" + str(number) + ".json"),
                        {"owner": current.owner, "accepted": request.accepted, "read_digests": found})

        restored = qualify(request, lambda number: node(context, request.destination, pair, "restored-" + str(number)),
                           observe, product_proof=lambda report, accepted: proof(original_plan, retained, report, accepted))
        require(primary_owner(original_plan) == plan["primary_owner"], "primary_owner_after_continuation")
        require(context.node is not None and context.node.process is None and not context.node.forced,
                "continued_restore_children_strictly_stopped")
        result.update(status="passed", restore=restored, consumers=context.consumers,
                      selected_commit_sha256=restored["accepted_backup"]["commit_sha256"],
                      frozen_prefix=original_plan["before"]["journal_head"], current_head_coverage_claimed=False)
    except BaseException as error:
        result["failure_class"] = type(error).__name__
        raise
    finally:
        try:
            if context.node is not None and context.node.process is not None:
                context.node.cleanup_stop()
            if context.node is not None and context.node.forced:
                result.update(status="failed", forced_owned_restore_stop=True)
        finally:
            save(output / "result.json", result)
            words = None
    require(result["status"] == "passed", "continued_restore_failed")
    return save(output / "verified.json", result)


def run(path, expected):
    require(reference(path)["sha256"] == expected, "approved_continuation_plan_hash")
    plan = read(path)
    require(plan.get("schema") == "lastdb.prod-restore-continuation-plan.v1" and plan.get("source") == SOURCE
            and plan["sources"] == sources() and 0 <= time.time() - plan["created_at"] <= 3600,
            "unchanged_current_continuation_plan")
    original_plan, failure = original(plan["original_plan"]["path"])
    require(reference(plan["original_plan"]["path"]) == plan["original_plan"]
            and failure == plan["original_failure"]
            and reference(original_plan["candidate_receipt"]["path"]) == original_plan["candidate_receipt"]
            and candidate(original_plan["candidate_receipt"]["path"])
                == (original_plan["programs"], original_plan["version"]), "unchanged_original_continuation_inputs")
    root = external(plan["output"])
    output = root / "operation"
    with operator_owner(root / "owner.lock"):
        require(not os.path.lexists(output), "continuation_is_one_use")
        output.mkdir(mode=0o700)
        descriptor = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
        save(output / "intent.json", {"plan": reference(path), "session": plan["session"],
             "selected_commit_sha256": plan["selected_commit_sha256"], "grant_admission": plan["grant_admission"],
             "new_restore_sessions": 0, "product_resume_calls_authorized": 1, "original_error_cause_known": False})
        before = read(plan["before_state"]["path"], 32 * 1024 * 1024)
        require(reference(plan["before_state"]["path"]) == plan["before_state"]
                and reference(plan["grant_admission"]["summary"]["path"])["sha256"] == GRANT_EVIDENCE,
                "unchanged_saved_and_grant_evidence")
        with owner_probe(Path(plan["session"])):
            require(snapshot(original_plan, Path(plan["session"])) == before
                    and admission(plan["grant_admission"]["summary"]["path"], before) == plan["grant_admission"],
                    "current_saved_restore_preflight")
        return execute_plan(plan, original_plan, path, output)


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    plan = sub.add_parser("plan")
    for name in ("original-plan", "session", "grant-evidence", "output"):
        plan.add_argument("--" + name, type=Path, required=True)
    execution = sub.add_parser("run")
    execution.add_argument("--plan", type=Path, required=True)
    execution.add_argument("--approved-plan-sha256", required=True)
    execution.add_argument("--execute", action="store_true", required=True)
    args = parser.parse_args()
    result = prepare(args) if args.action == "plan" else run(args.plan, args.approved_plan_sha256)
    print("PROD continuation record: " + result["path"] + " SHA256 " + result["sha256"])


if __name__ == "__main__":
    main()
