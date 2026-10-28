#!/usr/bin/env python3
"""Loom RunV2 policies: closed bootstrap or backup-protected ordinary maintenance."""

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

from native_upgrade import IMMUTABLE, helper, job_pid, service, unloaded
from native_upgrade_common import pair, private_dir, require, run, session, stopped
from native_v2_primary import record
from native_v2_stop import restore_hold
from native_run_v2_compatibility import BASELINE, BASELINE_PROGRAMS
from native_run_v2_profiles import check as evidence_check, selected as selected_profile
from native_run_v2_inputs import digest, read, uint
from native_run_v2_primary import (baseline_snapshot, initial, live, prepare, preserved,
                                   select, start, stopped_boundary)
from native_run_v2_stop import stop

MODE = "native-run-v2-ci-cloud-off"
PROFILE = "run-v2-ci-bootstrap-v1"
BINDING = (*IMMUTABLE, "native_probe_only", "zero_live_soak", "accept_stale_recovery_point")


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
    require(not any(k in item and k in raw and item[k] != raw[k] for k in BINDING),
            "Immutable Loom item/context conflict")
    ctx = {**item, **{k: v for k, v in raw.items() if k != "item"}}
    require((ctx.get("upgrade_mode"), ctx.get("safe_upgrade_protocol_version"))
            in ((MODE, "11"), ("native-run-v2-ci", "12"), ("native-run-v2-ci", "13"))
            and ctx.get("native_reopen") is False and ctx.get("native_probe_only") is False
            and ctx.get("zero_live_soak", False) is False
            and ctx.get("accept_stale_recovery_point", "") == "",
            "RunV2 refuses other modes and gate exceptions")
    require(os.environ.get("LOOM_LIVE") == "1" and bool(os.environ.get("LOOM_EXEC_ID")),
            "RunV2 requires the supported live Loom local journal")
    return ctx


def binding(ctx):
    candidate = pair(Path(ctx["candidate"]).parent)
    require(candidate["lastdbd"]["path"] == ctx["candidate"]
            and candidate["lastdb"]["path"] == ctx["candidate_cli"], "Candidate pair paths differ")
    for name, value in candidate.items():
        require(value["sha256"] == ctx[name + "_sha256"] and value["version"] == ctx[name + "_version"]
                and "-dirty" not in value["version"] and "/target/debug/" not in value["path"],
                "Candidate is not the exact release-class CI pair")
    fields = ("source_git_oid", "candidate", "candidate_cli", "lastdbd_sha256", "lastdb_sha256",
              "lastdbd_version", "lastdb_version")
    identity = hashlib.sha256("\0".join(str(ctx[k]) for k in fields).encode()).hexdigest()
    require(identity == ctx["candidate_artifact_digest"]
            and re.fullmatch(r"[0-9a-f]{40}", ctx["source_git_oid"]), "Candidate binding differs")
    approval = read(ctx["native_approval"], 65536, digest(ctx["native_approval_sha256"]))
    _, profile = selected_profile(approval)
    ordinary = approval.get("schema") in ("lastdb.run-v2-maintenance-approval.v1", "lastdb.run-v2-maintenance-approval.v2")
    require(ordinary
            == (ctx["upgrade_mode"] == "native-run-v2-ci"), "The RunV2 mode and profile differ")
    require(ctx["safe_upgrade_protocol_version"] == ("13" if approval.get("schema") == "lastdb.run-v2-maintenance-approval.v2"
            else "12" if ordinary else "11"), "The exact RunV2 approval protocol differs")
    require(approval.get("mode") == ctx["upgrade_mode"]
            and approval.get("approved_by") == "Tom"
            and isinstance(approval.get("quote"), str) and bool(approval["quote"].strip())
            and approval.get("source_git_oid") == ctx["source_git_oid"]
            and approval.get("candidate") == candidate
            and approval.get("baseline_source_git_oid") == getattr(profile, "BASELINE", BASELINE)
            and approval.get("baseline_programs_sha256") == getattr(profile, "BASELINE_PROGRAMS", BASELINE_PROGRAMS)
            and approval.get("cloud_off") is True and approval.get("primary_data_copy") is False
            and approval.get("primary_restore_or_migration") is False
            and approval.get("primary_validation") == ("keyed-data-health-continuity"
                if ctx["upgrade_mode"] == "native-run-v2-ci" else "metadata-health-continuity")
            and approval.get("recovery_policy") == ("accepted-stopped-native-cut-and-saved-pair"
                if ctx["upgrade_mode"] == "native-run-v2-ci" else "saved-pair-same-run-v2-home"),
            "An exact named RunV2 approval for the selected policy is required")
    evidence = read(approval["evidence_path"], 65536, digest(approval["evidence_sha256"]))
    return candidate, approval, evidence


def state_path(ctx):
    root = private_dir(Path.home() / ".local/state/last-stack/lastdb-safe-upgrade" /
                       ("native-run-v2-maintenance" if ctx["upgrade_mode"] == "native-run-v2-ci"
                        else "native-run-v2-ci-bootstrap"))
    key = hashlib.sha256((ctx["candidate_artifact_digest"] + ctx["native_approval_sha256"]).encode()).hexdigest()
    return private_dir(root / key) / "state.json"


def state_schema(ctx):
    if ctx["safe_upgrade_protocol_version"] == "13":
        return "lastdb.run-v2-maintenance-upgrade.v2"
    return ("lastdb.run-v2-maintenance-upgrade.v1" if ctx["upgrade_mode"] == "native-run-v2-ci"
            else "lastdb.run-v2-ci-bootstrap-upgrade.v1")


def read_state(path, ctx):
    state = read(path)
    require(state.get("schema") == state_schema(ctx)
            and state.get("binding") == {k: ctx.get(k) for k in BINDING},
            "The RunV2 upgrade journal binds another operation")
    return state


def fresh(approval, at=None):
    now = int(time.time()) if at is None else uint(at, True)
    require(0 <= now - uint(approval["approved_at"], True) <= 86400,
            "Candidate approval is outside its new-cutover window")


def emit(path, **values):
    print("LOOM_CONTEXT_PATCH:" + json.dumps({"native_state": str(path), **values}, separators=(",", ":")), flush=True)
    print("PASS", flush=True)


def initial_snapshot(approval, state):
    observed = baseline_snapshot(approval, state["baseline"])
    require(all(observed[k] == state["baseline"][k] for k in
                ("stable", "plist_sha256", "pair", "session", "process_start"))
            and observed.get("keyed_read") == state["baseline"].get("keyed_read"),
            "The primary changed after the exact RunV2 gates")
    return observed


def probe(ctx, candidate, approval, evidence, path):
    fresh(approval)
    if path.exists():
        state = read_state(path, ctx)
        require(state["phase"] not in ("rolled-back", "old-retained"),
                "A recovered failure needs a newly reviewed approval")
        if not state.get("effect_started_at"):
            initial_snapshot(approval, state)
            evidence_check(candidate, evidence, approval)
        return
    baseline = initial(approval, candidate, path)
    for value in baseline["baseline"]["pair"].values():
        source = re.search(r"-g([0-9a-f]{7,40})(?:\b|-dirty\b)", value["version"])
        require(source is not None and approval["baseline_source_git_oid"].startswith(source[1]), "Actual baseline embeds another source")
    if ctx["upgrade_mode"] == "native-run-v2-ci":
        require(approval.get("memory_limit_mb") == baseline["baseline"]["memory_limit_mb"],
                "The DEV memory guard differs from the actual primary memory limit")
    gates = evidence_check(candidate, evidence, approval)
    state = {"schema": state_schema(ctx),
             "binding": {k: ctx.get(k) for k in BINDING}, "execution": os.environ["LOOM_EXEC_ID"],
             **baseline, "gates": gates}
    record(path, state, "probed")


def cutover(ctx, candidate, approval, evidence, path, state):
    if state["phase"] == "complete":
        require(live(approval, state)["session"] == state["live"]["session"], "Completed primary session changed")
        return
    require(state["phase"] in ("probed", "prepared", "stopped", "install-requested", "selected",
                               "start-requested", "active", "soak"), "Unknown interrupted RunV2 phase")
    if not state.get("effect_started_at"):
        fresh(approval)
        preserved(approval, state)
        initial_snapshot(approval, state)
        gates = evidence_check(candidate, evidence, approval)
        prepare(approval, state, path)
        initial_snapshot(approval, state)
        fresh(approval)
        if ctx["upgrade_mode"] == "native-run-v2-ci":
            from native_run_v2_recovery import before_stop
            record(path, state, "prepared", recovery_point=before_stop(approval, state))
        record(path, state, "prepared", gates=gates)
        print("LOOM_EFFECT_INTENT:" + json.dumps({"kind":"deploy","target":ctx["upgrade_mode"]}), flush=True)
        stop(approval, state, path, state["baseline"]["session"], state["baseline"]["pair"]["lastdbd"], "stop")
        record(path, state, "stopped", stopped_at=int(time.time()), stopped_native_roots=stopped_boundary(approval, state))
    else:
        fresh(approval, state["effect_started_at"])
    if state["phase"] in ("stopped", "install-requested"):
        require(stopped_boundary(approval, state) == state["stopped_native_roots"],
                "The exact stopped RunV2 CURRENT pair changed before installation")
        if ctx["upgrade_mode"] == "native-run-v2-ci":
            if ctx["safe_upgrade_protocol_version"] == "13":
                from native_run_v2_final_recovery import complete
                complete(approval, state, path)
            else:
                from native_run_v2_recovery import stopped_cut
                stopped_cut(approval, state)
        select(approval, state, path)
    if state["phase"] in ("selected", "start-requested"):
        start(approval, state, path)
    first = live(approval, state)
    if state.get("live"):
        require(first["session"] == state["live"]["session"], "The candidate session changed")
    record(path, state, "soak", live=first)
    deadline = time.monotonic() + 300
    while time.monotonic() < deadline:
        time.sleep(min(15, max(0, deadline - time.monotonic())))
        require(live(approval, state)["session"] == first["session"], "The candidate restarted during the soak")
    current = live(approval, state)
    record(path, state, "complete", live=current, completed_at=int(time.time()))
    print("LOOM_EFFECT_DONE:" + json.dumps({"kind":"deploy","target":ctx["upgrade_mode"]}), flush=True)


def recover(approval, state, path):
    if not state.get("effect_started_at") or state["phase"] in ("rolled-back", "old-retained"):
        return
    fresh(approval, state["effect_started_at"])
    if "stop_program" in state:
        value = state["stop_program"]
        restore_hold(Path(value["path"]), value["inode"], value["sha256"])
    preserved(approval, state)
    intents, bindings = state.get("startup_intents", {}), state.get("startup_bindings", {})
    require(isinstance(intents, dict) and isinstance(bindings, dict) and set(intents) <= set(bindings),
            "An unknown startup outcome requires review before automatic program recovery")
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
        restarting = state["phase"] == "rollback-start-requested"
        expected = state.get("starting_session") if restarting else state["baseline"]["session"]
        process_start = state.get("starting_process_start") if restarting else state["baseline"]["process_start"]
        require(expected is not None and observed["session"] == expected
                and run(["/bin/ps", "-p", str(pid), "-o", "lstart="]).stdout.strip() == process_start,
                "The retained baseline session is not the exact recorded process")
        record(path, state, "rolled-back" if restarting else "old-retained", recovery=observed)
        return
    if selected and pid is not None:
        identity = session(home)
        expected = state.get("live", {}).get("session", state.get("starting_session"))
        require(identity["pid"] == pid and expected is not None and identity == expected,
                "Recovery found an unbound primary session")
        wanted = {**state["candidate"]["lastdbd"], "path": str(program)}
        stop(approval, state, path, identity, wanted, "rollback-stop")
    else:
        expected = state.get("live", {}).get("session") if selected else None
        stopped(home, expected or state.get("stopping_session", state["baseline"]["session"]))
    unloaded(target)
    select(approval, state, path, False)
    start(approval, state, path, False)


def main():
    require(not sys.flags.optimize, "Optimized Python cannot run an upgrade policy")
    ctx = context()
    def cancelled(unused_signal, unused_frame):
        raise RuntimeError("Upgrade interrupted; retain the exact local recovery transaction")
    signal.signal(signal.SIGTERM, cancelled)
    signal.signal(signal.SIGINT, cancelled)
    candidate, approval, evidence = binding(ctx)
    path = state_path(ctx)
    step = sys.argv[1]
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
            emit(path, verdict="green", cutover=ctx["upgrade_mode"])
        elif step == "RECOVER":
            recover(approval, read_state(path, ctx), path)
            emit(path, verdict="red")
        elif step in ("CHECK", "VERIFY"):
            state = read_state(path, ctx)
            require(state["phase"] == "complete" and live(approval, state)["session"] == state["live"]["session"],
                    "RunV2 bootstrap is not the exact verified supervised session")
            emit(path, verdict="green")
        elif step == "RECOVERY_CHECK":
            state = read_state(path, ctx)
            require(state["phase"] in ("rolled-back", "old-retained"), "RunV2 program recovery is incomplete")
            expected = state.get("recovery", state.get("live"))["session"]
            require(live(approval, state, False)["session"] == expected, "The recovered baseline session changed")
            emit(path, verdict="red")
        else:
            raise RuntimeError("Unknown RunV2 bootstrap step")


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("RunV2 bootstrap refused: " + str(error), file=sys.stderr)
        sys.exit(1)
