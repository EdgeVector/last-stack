#!/usr/bin/env python3
"""Loom's explicit CI-validated, native V2 recovery-point upgrade policy."""

import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import signal
import sys
import time

sys.dont_write_bytecode = True

from native_upgrade import IMMUTABLE, baseline_snapshot, helper, job_pid, service, unloaded
from native_upgrade_common import (pair, private_dir, require, session, sha,
                                   stopped)
from native_v2_gate import check as evidence_check, git, private_json
from native_v2_primary import initial, live, prepare, preserved, record, select, start
from native_v2_read import observe as keyed_read, specification as read_specification, verify as verify_read
from native_v2_source import accepted, boundary, invoke, live_recovery, validate_configuration
from native_v2_stop import restore_hold, stop

MODE = "native-v2-ci"


class Owner:
    def __init__(self, candidate):
        self.path = f"/tmp/lastdb-safe-upgrade-owner-{os.getuid()}.lock.d"
        self.token = str(os.getpid()) + "." + os.urandom(16).hex()
        self.candidate = candidate

    def __enter__(self):
        helper("owner-lock.sh", "safe_upgrade_owner_lock_acquire", self.path, self.token,
               str(os.getpid()), self.candidate, MODE)
        return self

    def __exit__(self, *unused):
        helper("owner-lock.sh", "safe_upgrade_owner_lock_release", self.path, self.token, "1")


def context():
    raw = json.loads(os.environ.get("LOOM_INPUT", "{}"))
    require(isinstance(raw, dict) and isinstance(raw.get("item", {}), dict), "Invalid Loom input")
    item = raw.get("item", {})
    require(not any(k in item and k in raw and item[k] != raw[k] for k in IMMUTABLE),
            "Immutable Loom item/context conflict")
    ctx = {**item, **{k: v for k, v in raw.items() if k != "item"}}
    require(ctx["upgrade_mode"] == MODE and ctx["safe_upgrade_protocol_version"] == "10"
            and ctx.get("native_reopen") is False and ctx.get("native_probe_only") is False
            and not ctx.get("zero_live_soak") and not ctx.get("accept_stale_recovery_point"),
            "Native V2 CI mode refuses other policies and gate exceptions")
    require(os.environ.get("LOOM_LIVE") == "1" and bool(os.environ.get("LOOM_EXEC_ID")),
            "Native V2 upgrade requires the supported live Loom local journal")
    return ctx


def binding(ctx):
    candidate = pair(Path(ctx["candidate"]).parent)
    require(candidate["lastdbd"]["path"] == ctx["candidate"]
            and candidate["lastdb"]["path"] == ctx["candidate_cli"], "Candidate pair paths differ")
    for name, value in candidate.items():
        require(value["sha256"] == ctx[name + "_sha256"] and value["version"] == ctx[name + "_version"]
                and "-dirty" not in value["version"] and "/target/debug/" not in value["path"],
                "Candidate is not the exact release-class CI pair")
    digest = hashlib.sha256("\0".join(str(ctx[k]) for k in (
        "source_git_oid", "candidate", "candidate_cli", "lastdbd_sha256", "lastdb_sha256",
        "lastdbd_version", "lastdb_version")).encode()).hexdigest()
    require(digest == ctx["candidate_artifact_digest"] and sha(ctx["native_approval"]) ==
            ctx["native_approval_sha256"], "Candidate or approval binding changed")
    approval = private_json(ctx["native_approval"], 65536)
    require(approval["schema"] == "lastdb.native-v2-ci-approval.v1" and approval["mode"] == MODE
            and approval["approved_by"] == "Tom" and bool(approval["quote"])
            and approval["primary_restore_or_migration"] is False
            and approval["primary_data_copy"] is False and approval["source_git_oid"] == ctx["source_git_oid"]
            and approval["candidate"] == candidate, "An exact authorized V2 candidate approval is required")
    require(re.fullmatch(r"[0-9a-f]{40}", ctx["source_git_oid"]) is not None
            and sha(approval["evidence_path"]) == approval["evidence_sha256"], "Source or evidence binding differs")
    evidence = private_json(approval["evidence_path"], 65536)
    require(evidence["source_git_oid"] == ctx["source_git_oid"], "Evidence binds another source")
    validate_configuration(approval)
    read_specification(approval)
    return candidate, approval, evidence


def state_path(ctx):
    root = private_dir(Path.home() / ".local/state/last-stack/lastdb-safe-upgrade/native-v2-ci")
    key = hashlib.sha256((ctx["candidate_artifact_digest"] + ctx["native_approval_sha256"]).encode()).hexdigest()
    return private_dir(root / key) / "state.json"


def read_state(path, ctx):
    state = private_json(path)
    require(state["schema"] == "lastdb.native-v2-ci-upgrade.v1"
            and state["binding"] == {k: ctx[k] for k in IMMUTABLE}, "Upgrade journal binds another candidate")
    return state


def fresh(approval, at=None):
    now = int(time.time()) if at is None else at
    require(type(approval["approved_at"]) is int and 0 <= now - approval["approved_at"] <= 86400,
            "Candidate approval is outside its new-cutover window")


def emit(path, **values):
    print("LOOM_CONTEXT_PATCH:" + json.dumps({"native_state": str(path), **values}, separators=(",", ":")), flush=True)
    print("PASS", flush=True)


def probe(ctx, candidate, approval, evidence, path):
    fresh(approval)
    if path.exists():
        state = read_state(path, ctx)
        require(state["phase"] not in ("rolled-back", "old-retained"),
                "A recovered failure needs a newly reviewed approval and job identities")
        if not state.get("effect_started_at"):
            current = initial_snapshot(approval, state)
            report, proof = live_recovery(approval, candidate, current["session"])
            record(path, state, state["phase"], live_recovery_report=report, live_recovery_freshness=proof)
        return
    baseline = initial(approval, candidate, path)
    for value in baseline["baseline"]["pair"].values():
        source = re.search(r"-g([0-9a-f]{7,40})(?:\b|-dirty\b)", value["version"])
        require(source is not None and approval["baseline_source_git_oid"].startswith(source[1]),
                "Actual baseline program embeds another source identity")
    git(evidence["source_repository"], "merge-base", "--is-ancestor",
        approval["baseline_source_git_oid"], ctx["source_git_oid"])
    require(approval["baseline_source_git_oid"] != ctx["source_git_oid"], "Upgrade candidate is already installed")
    gates = evidence_check(candidate, evidence, approval["baseline_source_git_oid"], baseline["baseline"], approval)
    report, proof = live_recovery(approval, candidate, baseline["baseline"]["session"])
    state = {"schema": "lastdb.native-v2-ci-upgrade.v1", "binding": {k: ctx[k] for k in IMMUTABLE},
             "execution": os.environ["LOOM_EXEC_ID"], **baseline, "gates": gates,
             "live_recovery_report": report, "live_recovery_freshness": proof}
    record(path, state, "probed")


def final_recovery(approval, candidate, state, path):
    _, _, _, _, target = service(approval)
    unloaded(target)
    observed = boundary(approval, candidate)
    request_id = approval["recovery"]["final_request_id"]
    record(path, state, "final-backup-requested", final_request_id=request_id,
           stopped_native_root=observed)
    report = invoke(approval, candidate, "status")
    if report["request_id"] == request_id:
        if not report["terminal_clean"]:
            report = invoke(approval, candidate, "resume")
    else:
        accepted(approval, report, approval["recovery"]["live_request_id"], at=state["effect_started_at"],
                 live_proof=state["live_recovery_freshness"], live_session=state["baseline"]["session"])
        report = invoke(approval, candidate, "start", request_id)
    captured = accepted(approval, report, request_id, stopped_since=state["stopped_at"])
    unloaded(target)
    require(captured == observed == boundary(approval, candidate),
            "Accepted final V2 cut is not the exact still-stopped CURRENT")
    record(path, state, "final-backup-complete", final_recovery_report=report)


def cutover(ctx, candidate, approval, evidence, path, state):
    if state["phase"] == "complete":
        live(approval, state)
        return
    require(state["phase"] in ("probed", "prepared", "stopped", "final-backup-requested",
                               "final-backup-complete", "install-requested", "selected",
                               "start-requested", "active", "soak", "complete"), "Unknown interrupted upgrade phase")
    if not state.get("effect_started_at"):
        fresh(approval)
        preserved(approval, state)
        current = initial_snapshot(approval, state)
        evidence_check(candidate, evidence, approval["baseline_source_git_oid"], current, approval)
        live_report, _ = live_recovery(approval, candidate, current["session"])
        prepare(approval, state, path)
        observed_read = keyed_read(approval)
        live_report, proof = live_recovery(approval, candidate, current["session"], live_report)
        record(path, state, "prepared", keyed_read=observed_read, live_recovery_report=live_report,
               live_recovery_freshness=proof)
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"native-v2-ci"}', flush=True)
        stop(approval, state, path, current["session"], current["pair"]["lastdbd"], "stop")
        record(path, state, "stopped", stopped_at=int(time.time()))
    else:
        fresh(approval, state["effect_started_at"])
    if state["phase"] in ("stopped", "final-backup-requested"):
        final_recovery(approval, candidate, state, path)
    if state["phase"] in ("final-backup-complete", "install-requested"):
        _, _, _, _, target = service(approval)
        unloaded(target)
        require(boundary(approval, candidate) == state["final_recovery_report"]["captured_native_root"],
                "Stopped native root advanced before install")
        select(approval, state, path)
    if state["phase"] in ("selected", "start-requested"):
        start(approval, state, path)
    first = live(approval, state)
    record(path, state, "soak", live=first)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        time.sleep(min(15, max(0, deadline - time.monotonic())))
        require(live(approval, state)["session"] == first["session"], "The candidate restarted during the soak")
    record(path, state, "complete", live=live(approval, state), completed_at=int(time.time()))
    print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"native-v2-ci"}', flush=True)


def initial_snapshot(approval, state):
    observed = baseline_snapshot(approval, state["baseline"])
    require(all(observed[k] == state["baseline"][k] for k in
                ("stable", "plist_sha256", "pair", "session", "process_start")),
            "The primary changed after the exact CI and recovery-point gates")
    return observed


def recover(approval, state, path):
    if not state.get("effect_started_at") or state["phase"] in ("rolled-back", "old-retained"):
        return
    fresh(approval, state["effect_started_at"])
    if "stop_program" in state:
        value = state["stop_program"]
        restore_hold(Path(value["path"]), value["inode"], value["sha256"])
    preserved(approval, state)
    if state["phase"] in ("install-requested", "rollback-install-requested"):
        label = plistlib.loads(Path(state["original_plist"]).read_bytes())["Label"]
        unloaded("gui/" + str(os.getuid()) + "/" + label)
        select(approval, state, path, False)
        start(approval, state, path, False)
        return
    home, _, _, program, target = service(approval)
    pid = job_pid(target)
    selected = program.parent == Path(state["candidate_directory"])
    if not selected and pid is not None:
        observed = live(approval, state, False)
        observed["keyed_read"] = verify_read(approval, state["keyed_read"])
        record(path, state, "old-retained", recovery=observed)
        return
    if selected and pid is not None:
        identity = session(home)
        expected = state.get("live", {}).get("session", state.get("starting_session"))
        require(identity["pid"] == pid and expected is not None and identity == expected,
                "Recovery found an unbound primary session")
        wanted = {**state["candidate"]["lastdbd"], "path": str(program)}
        stop(approval, state, path, identity, wanted, "rollback-stop")
    elif state["phase"] not in ("stopped", "final-backup-requested", "final-backup-complete",
                                 "install-requested", "selected", "rollback-install-requested", "rollback-selected"):
        # An unclean candidate boot is not a clean stopped native home.
        expected = state.get("live", {}).get("session") if selected else None
        stopped(home, expected or state.get("stopping_session", state["baseline"]["session"]))
    unloaded(target)
    select(approval, state, path, False)
    start(approval, state, path, False)


def main():
    require(not sys.flags.optimize, "Optimized Python cannot run an upgrade policy")
    step = sys.argv[1]
    ctx = context()
    def cancelled(signum, unused):
        raise RuntimeError("Upgrade interrupted; retain the exact local recovery transaction")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    candidate, approval, evidence = binding(ctx)
    path = state_path(ctx)
    with Owner(ctx["candidate"]):
        if step == "PROBE":
            probe(ctx, candidate, approval, evidence, path)
            emit(path, verdict="green")
        elif step == "CUTOVER":
            state = read_state(path, ctx)
            try:
                cutover(ctx, candidate, approval, evidence, path, state)
            except BaseException:
                recover(approval, state, path)
                raise
            emit(path, verdict="green", cutover=MODE)
        elif step == "RECOVER":
            recover(approval, read_state(path, ctx), path)
            emit(path, verdict="red")
        elif step in ("CHECK", "VERIFY"):
            state = read_state(path, ctx)
            require(state["phase"] == "complete" and live(approval, state)["session"] == state["live"]["session"],
                    "Native V2 upgrade is not the exact verified supervised session")
            emit(path, verdict="green")
        elif step == "RECOVERY_CHECK":
            state = read_state(path, ctx)
            require(state["phase"] in ("rolled-back", "old-retained"), "Native program recovery is incomplete")
            live(approval, state, False)
            emit(path, verdict="red")
        else:
            raise RuntimeError("Unknown native V2 upgrade step")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Native V2 upgrade refused: " + str(error), file=sys.stderr)
        sys.exit(1)
