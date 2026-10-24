#!/usr/bin/env python3
"""Candidate-bound two-home native migration through Loom local recovery."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import sys
import time

sys.dont_write_bytecode = True

import native_upgrade as native
from native_upgrade_common import (load, pair, private_dir, regular, require, run, save, sha)
from native_migration_io import generated_probe

MODE = "native-logical-migration-cloud-off"
SCHEMA = "lastdb.native-migration.v1"


def context():
    raw = json.loads(os.environ.get("LOOM_INPUT", "{}"))
    require(isinstance(raw, dict) and isinstance(raw.get("item", {}), dict), "Invalid migration input")
    item = raw.get("item", {})
    require(not any(key in raw and key in item and raw[key] != item[key]
                    for key in native.IMMUTABLE), "Conflicting immutable migration input")
    value = {**item, **{key: value for key, value in raw.items() if key != "item"}}
    require(value.get("upgrade_mode") == MODE and value.get("safe_upgrade_protocol_version") == "9",
            "Native migration protocol differs")
    require(value.get("native_reopen") is False and type(value.get("native_probe_only")) is bool
            and not value.get("zero_live_soak") and not value.get("accept_stale_recovery_point"),
            "Migration refuses in-place reopen and legacy gate exceptions")
    return value


def binding(ctx):
    require(sha(ctx["native_approval"]) == ctx["native_approval_sha256"], "Migration approval changed")
    approval = load(ctx["native_approval"], maximum=32768)
    require(approval.get("schema") == "lastdb.native-migration-approval.v1"
            and approval.get("approved_by") == "Tom" and bool(approval.get("quote"))
            and approval.get("mode") == MODE and approval.get("cloud_off") is True
            and approval.get("filesystem_clone") is False,
            "An explicit candidate-bound two-home approval is required")
    candidate = pair(Path(ctx["candidate"]).parent)
    require(candidate == approval["candidate"] and ctx["source_git_oid"] == approval["source_git_oid"],
            "Migration candidate or source differs")
    for name in ("lastdb", "lastdbd"):
        require(candidate[name]["path"] == ctx["candidate" if name == "lastdbd" else "candidate_cli"]
                and candidate[name]["sha256"] == ctx[name + "_sha256"]
                and candidate[name]["version"] == ctx[name + "_version"], "Migration pair bytes differ")
    digest = hashlib.sha256("\0".join(str(ctx[key]) for key in (
        "source_git_oid", "candidate", "candidate_cli", "lastdbd_sha256", "lastdb_sha256",
        "lastdbd_version", "lastdb_version")).encode()).hexdigest()
    require(digest == ctx["candidate_artifact_digest"], "Migration artifact digest differs")
    for tool in approval["tools"].values():
        regular(tool["path"])
        require(sha(tool["path"]) == tool["sha256"], "Migration worker bytes differ")
        run(["/usr/bin/codesign", "--verify", "--strict", tool["path"]])
    native.service(approval)
    require(sha(approval["verification_file"]) == approval["verification_sha256"], "Verification keys changed")
    return candidate, approval


def path_for(ctx):
    root = private_dir(Path.home() / ".local/state/last-stack/lastdb-safe-upgrade/migration")
    key = hashlib.sha256((ctx["candidate_artifact_digest"] + ctx["native_approval_sha256"]).encode()).hexdigest()
    return private_dir(root / key) / "state.json"


def read_state(path, ctx):
    state = load(path)
    require(state.get("schema") == SCHEMA
            and state.get("binding") == {key: ctx[key] for key in native.IMMUTABLE},
            "Migration state binding differs")
    return state


def latest_main(source):
    result = run(["git", "ls-remote", "https://github.com/EdgeVector/lastdb.git", "refs/heads/main"], timeout=30)
    require(result.stdout.split()[0] == source,
            "MAIN_CHANGED: refresh the CI migration artifact before a primary stop")


def generated_tuning(approval):
    _, plist, _, _, _ = native.service(approval)
    tuning = {}
    for line in native.helper("live-lastdb-env.sh", "live_lastdb_env_pairs", plist).stdout.splitlines():
        name, value = line.split("=", 1)
        if not re.search(r"HOME|PATH|DIR|CLOUD|KEY|TOKEN|SECRET|URL|ENDPOINT|ISOLATED|BOOTSTRAP", name):
            tuning[name] = value
    return tuning


def step_main(step):
    ctx = context()
    require(os.environ.get("LOOM_LIVE") == "1" and bool(os.environ.get("LOOM_EXEC_ID")),
            "Native migration requires the live Loom local-recovery graph")
    candidate, approval = binding(ctx)
    path = path_for(ctx)
    from native_migration_effects import cutover, check, recover
    with native.Owner(ctx["candidate"]):
        if step == "PROBE":
            if path.exists():
                state = read_state(path, ctx)
                require(state.get("effect_started_at") or state.get("probe", {}).get("passed") is True,
                        "An incomplete probe needs a new exact approval")
            else:
                native.approval_fresh(approval)
                baseline = native.snapshot(approval)
                relation = native.freshness(candidate, baseline["pair"], ctx["source_git_oid"])
                require(relation.get("relation") == "forward", "Migration target must be a forward source")
                match = re.search(r"-g([0-9a-f]+)$", baseline["pair"]["lastdbd"]["version"])
                require(match and approval["baseline_source_git_oid"].startswith(match[1]),
                        "The source reader is not built from the installed source")
                state = {"schema": SCHEMA, "binding": {key: ctx[key] for key in native.IMMUTABLE},
                         "baseline": baseline, "execution": os.environ["LOOM_EXEC_ID"]}
                native.record(path, state, "probe-requested")
                result = generated_probe(baseline["pair"], candidate, approval["tools"],
                    path.parent / "generated-proof", baseline["memory_limit_mb"], generated_tuning(approval))
                native.record(path, state, "probed", probe=result)
            native.emit({"verdict": "probed" if ctx["native_probe_only"] else "green", "native_state": str(path)})
        elif step == "CUTOVER":
            require(ctx["native_probe_only"] is False, "A probe-only migration cannot change the primary")
            state = read_state(path, ctx)
            try:
                cutover(ctx, approval, candidate, path, state)
            except Exception:
                recover(approval, candidate, path, state)
                raise
        elif step in ("CHECK", "VERIFY"):
            state = read_state(path, ctx)
            check(approval, candidate, state)
            if step == "VERIFY":
                native.emit({"verdict": "green", "native_state": str(path), "primary_session": state["live"]["session"]})
        elif step in ("RECOVER", "RECOVERY_CHECK"):
            state = read_state(path, ctx)
            if step == "RECOVER":
                recover(approval, candidate, path, state)
                native.emit({"verdict": "red", "native_state": str(path)})
            else:
                if state["phase"] == "target-retained":
                    from native_migration_effects import live_gate
                    live_gate(approval, candidate, state)
                    return
                require(state["phase"] == "source-restored", "Migration recovery is incomplete")
                from native_upgrade_common import health, session
                home, _, _, program, target = native.service(approval)
                require(pair(program.parent) == state["baseline"]["pair"], "Recovered source pair differs")
                identity = session(home)
                require(native.job_pid(target) == identity["pid"], "Recovered source supervision differs")
                health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], identity["pid"])
        else:
            raise RuntimeError("Unknown migration step")


def approve(args):
    candidate = pair(Path(args.candidate).expanduser().resolve().parent)
    require(re.fullmatch(r"[0-9a-f]{40}", args.source) and re.fullmatch(r"[0-9a-f]{40}", args.baseline_source),
            "Full source and baseline revisions are required")
    match = re.search(r"-g([0-9a-f]+)$", candidate["lastdbd"]["version"])
    require(match and args.source.startswith(match[1]), "Candidate source version differs")
    tools = {}
    for name, value in (("source", args.source_reader), ("target", args.target_writer)):
        path = Path(value).expanduser().resolve()
        regular(path)
        run(["/usr/bin/codesign", "--verify", "--strict", path])
        tools[name] = {"path": str(path), "sha256": sha(path)}
    output = Path(args.output).expanduser()
    require(not output.exists(), "Migration approval path already exists")
    approval = {"schema": "lastdb.native-migration-approval.v1", "approved_by": "Tom",
        "quote": args.quote, "approved_at": int(time.time()), "mode": MODE, "cloud_off": True,
        "filesystem_clone": False, "logical_target_authorized": True, "source_git_oid": args.source,
        "baseline_source_git_oid": args.baseline_source, "candidate": candidate, "tools": tools,
        "ci_run": args.ci_run, "primary_home": str(Path.home() / ".lastdb"),
        "verification_file": str(Path(args.verification).expanduser().resolve()),
        "verification_sha256": sha(Path(args.verification).expanduser().resolve()),
        "launchd_plist": str(Path(args.plist).expanduser()),
        "recovery": "Original source data before target app writes; repair forward or verified reverse transfer afterward"}
    native.service(approval)
    save(output, approval)
    print("Candidate-bound logical migration approval recorded: " + str(output))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("step", choices=("PROBE", "CUTOVER", "VERIFY", "CHECK", "RECOVER", "RECOVERY_CHECK", "approve"))
    for name in ("candidate", "source", "baseline-source", "source-reader", "target-writer", "verification", "quote", "plist", "ci-run", "output"):
        parser.add_argument("--" + name)
    args = parser.parse_args()
    if args.step == "approve":
        require(all(value for key, value in vars(args).items() if key != "step"), "Migration approval arguments are incomplete")
        approve(args)
    else:
        def cancelled(signum, unused):
            raise RuntimeError("Migration interrupted; retain its exact journal and both data homes")
        signal.signal(signal.SIGTERM, cancelled)
        signal.signal(signal.SIGINT, cancelled)
        step_main(args.step)


if __name__ == "__main__":
    try:
        main()
    except Exception as error:
        print("Native migration refused: " + str(error), file=sys.stderr)
        sys.exit(1)
