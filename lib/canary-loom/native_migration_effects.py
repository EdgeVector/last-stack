"""Journalled two-home migration and exact data/program recovery boundaries."""

import hashlib
import json
import os
from pathlib import Path
import shutil
import time

import native_upgrade as native
from native_upgrade_common import (call, durable_batch, exact_read, health, load, memory,
                                   pair, private_dir, require, run, save, session, sha, stopped, sync_dir, wait_health)
from native_migration_io import PrivateTarget, prepare, transfer


def outer_unchanged(approval, state):
    home, plist_path, _, _, _ = native.service(approval)
    baseline = state["baseline"]
    require(home.stat().st_ino == baseline["stable"]["home_inode"]
            and sha(plist_path) == baseline["plist_sha256"], "Primary home or supervisor changed")
    for name, digest in baseline["stable"]["files"].items():
        if name.startswith("data/"):
            continue
        path = home / name
        require((sha(path) if path.exists() else None) == digest, "Primary identity or cloud policy changed")


def key_digest(sock, spec):
    require(isinstance(spec.get("keys"), list) and 0 < len(spec["keys"]) <= 128
            and isinstance(spec.get("fields"), list) and len(spec["fields"]) == 2,
            "Migration verification needs bounded known keys and two receipt fields")
    value = call(sock, "/api/query", {"schema_name": spec["schema"], "fields": spec["fields"],
        "filter": {"HashRangeKeys": [[key, ""] for key in spec["keys"]]}, "limit": len(spec["keys"])})
    found = {row["key"]["hash"]: row["fields"] for row in value.get("results", [])}
    require(not value.get("has_more") and not value.get("unresolved_rows")
            and len(found) == len(value.get("results", [])) and set(found) == set(spec["keys"]),
            "Known migration keys are absent or incomplete")
    return hashlib.sha256(json.dumps(found, sort_keys=True).encode()).hexdigest()


def live_gate(approval, candidate, state):
    outer_unchanged(approval, state)
    home, _, plist, program, target = native.service(approval)
    require((home / "data").stat().st_ino == state["target_data_inode"], "Selected target data differs")
    require(pair(program.parent) == native.candidate_at(candidate, program.parent), "Selected target pair differs")
    identity = session(home)
    require(native.job_pid(target) == identity["pid"], "Target supervision differs")
    native.check_environment(identity["pid"], plist)
    value = health(home / "data/folddb.sock", candidate["lastdbd"]["version"], identity["pid"])
    return {"session": identity, "health": value,
            "memory_bytes": memory(identity["pid"], state["baseline"]["memory_limit_mb"])}


def target_checks(approval, candidate, path, state):
    home, _, plist, _, _ = native.service(approval)
    target = Path(state["target_home"])
    environment = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "LANG": "C", "RUST_MIN_STACK": "16777216"}
    environment.update(plist.get("EnvironmentVariables", {}))
    node = PrivateTarget(target, path.parent / "private-target", state["baseline"]["memory_limit_mb"], environment)
    spec = load(approval["verification_file"])
    try:
        node.start(candidate)
        require(key_digest(node.socket, spec) == state["source_keys_sha256"], "Migrated keyed values differ")
        identity = state["check_key"]
        fields = {spec["fields"][0]: identity, spec["fields"][1]: "migration-private"}
        result = durable_batch(node.socket, [{"type": "mutation", "schema": spec["schema"],
            "mutation_type": "create", "key_value": {"hash": identity}, "fields_and_values": fields}])
        exact_read(node.socket, spec["schema"], spec["fields"], [identity], {identity: fields})
        compact = call(node.socket, "/api/db/compact", {"dry_run": False, "grace_ms": 0}, timeout=180)
        require(compact["compact"]["native_disk"].get("executed") is True, "Private target compaction failed")
        first_stop = node.stop()
        node.start(candidate)
        require(key_digest(node.socket, spec) == state["source_keys_sha256"], "Target reopen keyed values differ")
        exact_read(node.socket, spec["schema"], spec["fields"], [identity], {identity: fields})
        final_stop = node.stop()
        native.record(path, state, "target-checked", target_check={"ack": result, "compaction": True,
            "first_stop": first_stop, "reopen_stop": final_stop}, target_data_inode=(target / "data").stat().st_ino)
    finally:
        node.close()


def promote(approval, candidate, path, state):
    outer_unchanged(approval, state)
    home, _, _, program, service = native.service(approval)
    native.unloaded(service)
    stopped(home, state["baseline"]["session"])
    data, retained, incoming = home / "data", path.parent / "source-data", Path(state["target_home"]) / "data"
    require(data.stat().st_ino == state["baseline"]["stable"]["data_inode"]
            and incoming.stat().st_ino == state["target_data_inode"] and not retained.exists(),
            "Data promotion paths differ")
    require(data.stat().st_dev == path.parent.stat().st_dev == incoming.stat().st_dev,
            "Migration promotion needs atomic renames on one filesystem")
    native.record(path, state, "retain-source-intent", source_data=str(retained))
    os.rename(data, retained)
    sync_dir(home)
    sync_dir(path.parent)
    native.record(path, state, "source-retained")
    os.rename(incoming, data)
    sync_dir(incoming.parent)
    sync_dir(home)
    native.record(path, state, "target-selected")
    for name in ("lastdbd", "lastdb"):
        native.unloaded(service)
        require(sha(program.parent / name) == state["baseline"]["pair"][name]["sha256"], "Old program changed")
        os.replace(Path(state["stage_directory"]) / name, program.parent / name)
        sync_dir(program.parent)
    require(pair(program.parent) == native.candidate_at(candidate, program.parent), "Promoted pair differs")
    # This durable boundary precedes the first public socket. A crash beyond
    # it cannot prove that no client received an acknowledgement.
    native.record(path, state, "canonical-start-intent", target_app_writes_possible=True)
    native.bootstrap(approval)
    wait_health(home / "data/folddb.sock", candidate["lastdbd"]["version"], native.job_pid(service))
    native.record(path, state, "active", live=live_gate(approval, candidate, state))


def canonical_checks(approval, candidate, path, state):
    home, _, _, program, service = native.service(approval)
    sock, spec = home / "data/folddb.sock", load(approval["verification_file"])
    require(key_digest(sock, spec) == state["source_keys_sha256"], "Live migrated values differ")
    key = state["check_key"]
    fields = {spec["fields"][0]: key, spec["fields"][1]: "migration-live"}
    ack = durable_batch(sock, [{"type": "mutation", "schema": spec["schema"], "mutation_type": "update",
                              "key_value": {"hash": key}, "fields_and_values": fields}])
    compact = call(sock, "/api/db/compact", {"dry_run": False, "grace_ms": 0}, timeout=180)
    require(compact["compact"]["native_disk"].get("executed") is True, "Live target compaction failed")
    exact_read(sock, spec["schema"], spec["fields"], [key], {key: fields})
    require(key_digest(sock, spec) == state["source_keys_sha256"], "Live compaction changed migrated values")
    identity = session(home)
    native.record(path, state, "canonical-reopen-stop-intent", canonical_ack=ack, reopen_session=identity)
    output = native.helper("launchd-job-checks.sh", "lastdb_launchd_graceful_prestop",
        "/bin/launchctl", service, program, "300", "150", "1", timeout=510).stdout
    require("LASTDB_LAUNCHD_PRESTOP=ok " in output and "forced_kill=0" in output, "Canonical clean stop failed")
    proof = stopped(home, identity)
    native.unloaded(service)
    native.record(path, state, "canonical-reopen-start-intent", canonical_reopen_stop=proof)
    native.bootstrap(approval)
    wait_health(sock, candidate["lastdbd"]["version"], native.job_pid(service))
    require(key_digest(sock, spec) == state["source_keys_sha256"], "Canonical reopen changed migrated values")
    exact_read(sock, spec["schema"], spec["fields"], [key], {key: fields})
    native.record(path, state, "reopened", live=live_gate(approval, candidate, state))


def cutover(ctx, approval, candidate, path, state):
    from native_migration import latest_main
    require(state.get("probe", {}).get("passed") is True, "Migration probe did not pass")
    if not state.get("effect_started_at"):
        native.approval_fresh(approval)
        current = native.snapshot(approval)
        require(all(current[key] == state["baseline"][key] for key in
                    ("stable", "plist_sha256", "pair", "session", "process_start")), "Primary changed after migration probe")
        require(time.time() - state["probe"]["completed_at"] <= 3600, "Migration probe expired")
        home, _, _, program, _ = native.service(approval)
        spec = load(approval["verification_file"])
        digest = key_digest(home / "data/folddb.sock", spec)
        stage = native.prepare_pair(candidate, program, path, state)
        target_home = private_dir(path.parent / "target-home")
        inventory_result = run([approval["tools"]["source"]["path"], "verify", "--home",
                                home / "data/disk-pack"], timeout=600)
        inventory = json.loads(inventory_result.stderr)
        require(type(inventory.get("body_bytes")) is int and inventory["body_bytes"] >= 0
                and type(inventory.get("records")) is int and inventory["records"] > 0
                and type(inventory.get("tombstones")) is int and inventory["tombstones"] >= 0,
                "Source record inventory is invalid")
        free = shutil.disk_usage(home).free
        required_space = (1024 * 1024 * 1024 + inventory["body_bytes"] * 4
                          + (inventory["records"] + inventory["tombstones"]) * 4096)
        require(free >= required_space, "Source inventory, target compaction, and recovery lack disk headroom")
        native.record(path, state, "prepared", source_keys_sha256=digest, stage_directory=str(stage),
            target_home=str(target_home), check_key="native-migration-" + path.parent.name[:24],
            source_inventory=inventory, required_free_bytes=required_space, observed_free_bytes=free)
        latest_main(ctx["source_git_oid"])
        print('LOOM_EFFECT_INTENT:{"kind":"deploy","target":"native-logical-migration-cloud-off"}', flush=True)
        native.strict_stop(approval, state, path)
        result = transfer(home, target_home, approval["tools"])
        native.record(path, state, "transferred", transfer=result)
        prepare(candidate, home, target_home, primary=True)
        target_checks(approval, candidate, path, state)
        promote(approval, candidate, path, state)
    require(state.get("target_app_writes_possible") is True, "Interrupted transfer requires source recovery before a new attempt")
    if state["phase"] not in ("reopened", "soak", "complete"):
        canonical_checks(approval, candidate, path, state)
    live = live_gate(approval, candidate, state)
    native.record(path, state, "soak", live=live, soak_started_at=int(time.time()))
    deadline = time.monotonic() + 300
    while True:
        current = live_gate(approval, candidate, state)
        require(current["session"] == live["session"], "Migrated primary restarted during the soak")
        if time.monotonic() >= deadline:
            break
        time.sleep(min(15, max(0, deadline - time.monotonic())))
    native.record(path, state, "complete", live=current, completed_at=int(time.time()))
    print('LOOM_EFFECT_DONE:{"kind":"deploy","target":"native-logical-migration-cloud-off"}', flush=True)
    native.emit({"verdict": "green", "native_state": str(path), "cutover": "native-logical-migration-cloud-off"})


def check(approval, candidate, state):
    require(state["phase"] == "complete", "Native migration is incomplete")
    live = live_gate(approval, candidate, state)
    require(live["session"] == state["live"]["session"], "Completed migration session changed")


def recover(approval, candidate, path, state):
    if not state.get("effect_started_at"):
        return
    outer_unchanged(approval, state)
    home, _, plist, program, service = native.service(approval)
    if state["phase"] == "source-restored":
        require(pair(program.parent) == state["baseline"]["pair"]
                and (home / "data").stat().st_ino == state["baseline"]["stable"]["data_inode"],
                "Recovered source data or programs differ")
        identity = session(home)
        require(native.job_pid(service) == identity["pid"], "Recovered source supervisor differs")
        health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], identity["pid"])
        return
    if state.get("target_app_writes_possible"):
        # Only the exact target is eligible beyond this boundary. Restarting
        # its verified pair never selects or rewrites the retained source.
        require((home / "data").stat().st_ino == state["target_data_inode"]
                and pair(program.parent) == native.candidate_at(candidate, program.parent),
                "An unknown target blocks repair forward")
        if native.job_pid(service) is None:
            from native_upgrade_common import alive
            require(not alive(session(home)["pid"]), "A target process still exists outside supervision")
            native.bootstrap(approval)
            wait_health(home / "data/folddb.sock", candidate["lastdbd"]["version"], native.job_pid(service))
        native.record(path, state, "target-retained", live=live_gate(approval, candidate, state))
        return
    old = state["baseline"]["session"]
    if native.job_pid(service) == old["pid"]:
        require(session(home) == old, "Old source session differs")
        hold = Path(str(program) + ".prestop-hold")
        if hold.exists():
            require(not program.exists() and sha(hold) == state["baseline"]["pair"]["lastdbd"]["sha256"],
                    "Interrupted source stop left an unknown program hold")
            os.replace(hold, program)
            sync_dir(program.parent)
        require(pair(program.parent) == state["baseline"]["pair"], "Still-active source pair differs")
        health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], old["pid"])
        native.record(path, state, "source-restored")
        return
    require(native.job_pid(service) is None, "An unexpected supervised process blocks source recovery")
    hold = Path(str(program) + ".prestop-hold")
    if hold.exists():
        require(not program.exists() and sha(hold) == state["baseline"]["pair"]["lastdbd"]["sha256"],
                "Source stop program hold differs")
        os.replace(hold, program)
        sync_dir(program.parent)
        run(["/bin/launchctl", "bootout", service], check=False)
    native.unloaded(service)
    data, retained = home / "data", path.parent / "source-data"
    if retained.exists():
        require(retained.stat().st_ino == state["baseline"]["stable"]["data_inode"], "Retained source data differs")
        if data.exists():
            require(data.stat().st_ino == state.get("target_data_inode"), "An unknown data home blocks recovery")
            rejected = path.parent / "rejected-target-data"
            require(not rejected.exists(), "Recovery target data path already exists")
            os.rename(data, rejected)
        os.rename(retained, data)
        sync_dir(home)
        sync_dir(path.parent)
    require(data.stat().st_ino == state["baseline"]["stable"]["data_inode"], "Original source is not selected")
    backup = path.parent / "programs-before"
    for name in ("lastdbd", "lastdb"):
        expected = state["baseline"]["pair"][name]["sha256"]
        saved, target = backup / name, program.parent / name
        require(sha(saved) == expected, "Saved source program differs")
        if not target.exists() or sha(target) != expected:
            stage = target.with_name(target.name + ".migration-recovery")
            require(not stage.exists(), "Recovery staging file already exists")
            shutil.copy2(saved, stage)
            with stage.open("rb") as stream:
                os.fsync(stream.fileno())
            os.replace(stage, target)
            sync_dir(target.parent)
    require(pair(program.parent) == state["baseline"]["pair"], "Recovered source programs differ")
    stopped(home, old)
    native.record(path, state, "source-recovery-start-intent")
    native.bootstrap(approval)
    wait_health(home / "data/folddb.sock", state["baseline"]["pair"]["lastdbd"]["version"], native.job_pid(service))
    native.check_environment(native.job_pid(service), plist)
    native.record(path, state, "source-restored", recovery_session=session(home))
