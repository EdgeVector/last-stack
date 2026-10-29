"""The exact old/new DEV sequence with one frozen accepted log selection."""

import copy

from native_run_v2_auto_qualify_data import NOTE_FIELD, SCHEMA
from native_run_v2_auto_qualify_io import BASELINE, SOURCE, read, reference, require, save
from native_run_v2_auto_qualify_process import node

POLICY_FIELDS = ("revision", "enabled", "log_interval_seconds", "snapshot_interval_seconds",
                 "last_snapshot_at", "next_snapshot_at")


def _start(operation, active, pair, label):
    require(active[0] is None, "one_owned_qualification_child")
    current = node(operation, operation.homes / "s", pair, label, source=True)
    active[0] = current
    current.start()
    return current


def _stop(active):
    require(active[0] is not None, "owned_qualification_child")
    active[0].stop()
    active[0] = None


def _accepted(status, kind):
    require(status["backup_kind"] == kind and status["phase"] == "published"
            and status["running"] is False and status["retained_source_bytes"] == 0,
            "complete_qualification_publication")
    accepted = status["last_accepted_backup"]
    require(accepted["begin"]["job"]["commit_id"] == status["request_id"],
            "qualification_publication_request")
    return copy.deepcopy(accepted)


def _policy(value):
    require(isinstance(value, dict) and all(name in value for name in POLICY_FIELDS),
            "complete_restart_policy")
    return {name: copy.deepcopy(value[name]) for name in POLICY_FIELDS}


def _seed(operation, active):
    operation.summary["stage"] = "baseline-write-and-candidate-read"
    old = _start(operation, active, operation.baseline, "baseline-source")
    operation.data.populate(old)
    _stop(active)
    current = _start(operation, active, operation.candidate, "source-first")
    operation.data.reads(current, "candidate-reads-baseline-data",
                         expected=operation.data.initial, files=operation.data.initial_files)
    expected = {"schema": SCHEMA, "records": copy.deepcopy(operation.plan["records"])}
    source = operation.helpers.source.Source(current, expected, operation.plan["source"],
                                              operation.summary)
    source.connect(operation.api_key)
    operation.summary["stage"] = "automatic-initial-snapshot"
    source.configure(snapshot=86400)
    snapshot = source.published("snapshot")
    snapshot_ref = save(operation.output / "initial-snapshot.json", snapshot)
    source.caught_up(snapshot)
    return source, snapshot, snapshot_ref


def _selected_log(operation, source):
    operation.summary["stage"] = "candidate-update-delete-and-log"
    operation.data.update(source.node)
    written = copy.deepcopy(source.cloud("status")["mutation_log"]["head"])
    require(isinstance(written, dict) and isinstance(written.get("frontiers"), dict)
            and set(written["frontiers"]) == {"main", "cas"}
            and all(type(value) is int and value >= 0 for value in written["frontiers"].values()),
            "written_mutation_frontiers")
    return written


def _restart(operation, active, source, selected):
    operation.summary["stage"] = "normal-automatic-restart"
    accepted = _accepted(selected, "mutation_log")
    before = {"selected_log": accepted, "automatic_policy": _policy(selected["automatic_backup"])}
    before_ref = save(operation.output / "before-log-restart.json", before)
    _stop(active)
    source.node = _start(operation, active, operation.candidate, "source-second")
    status = source.cloud("status")
    policy = source.policy(status)
    require(reference(before_ref["path"]) == before_ref, "unchanged_original_restart_record")
    original = read(before_ref["path"])
    require(original == before and _policy(policy) == original["automatic_policy"],
            "automatic_policy_survives_normal_restart")
    after_ref = save(operation.output / "after-log-restart.json",
                     {"selected_log": accepted, "automatic_policy": _policy(policy)})
    rewrite = operation.plan["post_restart_rewrite"]
    fields = operation.data.expected[rewrite["id"]]
    require(rewrite["same_value"] is True and rewrite["field"] == NOTE_FIELD
            and fields[NOTE_FIELD] == rewrite["note"], "declared_post_restart_rewrite")
    prior_head = copy.deepcopy(source.cloud("status")["mutation_log"]["head"])
    require(isinstance(prior_head, dict), "post_restart_prewrite_head")
    operation.data.mutations(source.node, {rewrite["id"]: fields})
    written = source.cloud("status")["mutation_log"]["head"]
    require(isinstance(written, dict) and written["epoch"] == prior_head["epoch"]
            and written["sequence"] > prior_head["sequence"]
            and written["frontiers"]["main"] > prior_head["frontiers"]["main"], "actual_post_restart_mutation")
    save(operation.output / "post-restart-written-minimum.json", {"before": prior_head, "after": written})
    restarted = source.published("mutation_log", previous=accepted["commit_sha256"], through=written["frontiers"])
    restarted_ref = save(operation.output / "restarted-log-backup.json", restarted)
    source.caught_up(restarted)
    next_accepted = _accepted(restarted, "mutation_log")
    logs = {accepted["commit_sha256"], next_accepted["commit_sha256"]}
    observed = {value["commit_sha256"]: value for value in source.completed.values()}
    require(len(logs) == 2 and all(value in observed for value in logs)
            and observed[accepted["commit_sha256"]] == accepted
            and observed[next_accepted["commit_sha256"]] == next_accepted,
            "two_distinct_completed_mutation_logs")
    operation.data.reads(source.node, "source-after-two-logs", accepted=accepted)
    return restarted_ref, before_ref, after_ref


def _later(operation, active, source, snapshot, selected, written):
    operation.summary["stage"] = "automatic-later-snapshot-and-old-reopen"
    source.configure(snapshot=60)
    later = source.published("snapshot", previous=snapshot["last_accepted_backup"]["commit_sha256"],
                             snapshot=60, through=written["frontiers"])
    later_ref = save(operation.output / "later-snapshot.json", later)
    source.caught_up(later, snapshot=60)
    require(later["automatic_backup"]["last_snapshot_at"]
            > snapshot["automatic_backup"]["last_snapshot_at"], "later_snapshot_timer")
    source.configure(snapshot=86400)
    source.disable()
    _stop(active)
    old = _start(operation, active, operation.baseline, "baseline-after-candidate")
    operation.data.reads(old, "baseline-reopens-candidate-data", accepted=selected)
    _stop(active)
    return later, later_ref


def run(operation):
    require(operation.plan["source"] == SOURCE and operation.candidate.source == SOURCE
            and operation.baseline.source == BASELINE
            and operation.account == operation.helpers.support.ACCOUNT,
            "exact_qualification_pair_and_dev_account")
    active = [None]
    try:
        source, snapshot, snapshot_ref = _seed(operation, active)
        operation.source = source
        snapshot_accepted = _accepted(snapshot, "snapshot")
        written = _selected_log(operation, source)
        selected = source.published("mutation_log", previous=snapshot_accepted["commit_sha256"],
                                    through=written["frontiers"])
        selected_ref = save(operation.output / "selected-log-backup.json", selected)
        source.caught_up(selected)
        selected_accepted = _accepted(selected, "mutation_log")
        restarted_ref, before_ref, after_ref = _restart(operation, active, source, selected)
        later, later_ref = _later(operation, active, source, snapshot, selected_accepted, written)
        later_accepted = _accepted(later, "snapshot")
        return {"snapshot": snapshot_accepted, "log": selected_accepted, "later": later_accepted,
                "minimum": written, "before_log_restart": before_ref,
                "after_log_restart": after_ref, "observed": copy.deepcopy(list(source.completed.values())),
                "statusrefs": {"snapshot": snapshot_ref, "log": selected_ref,
                               "restarted": restarted_ref, "later": later_ref}}
    finally:
        if active[0] is not None and active[0].process is not None:
            active[0].cleanup_stop()
