"""Offline native format activation after the final stopped backup.

The route runs the exact verified candidate CLI once, under the clean stop,
after the final stopped backup is accepted and fully verified. The command
changes only the node marker. The route proves that every other native file
in the final stopped backup keeps its exact bytes before any start.
Recovery restarts the same exact pair. The marker change is forward only.
"""

import hashlib
import json
import os
from pathlib import Path
import time

from native_upgrade_common import require, run, sha, stopped
from native_v2_primary import record
from native_run_v2_final_manifest import decimal
from native_run_v2_inputs import digest, reference
from native_run_v2_recovery import FILE, native_hash, selectors
from native_run_v2_routes import markers, route
from native_run_v2_state import MARKER, Metadata, stable

PHASES = ("activation-requested", "activated")
REPLY = {"previous_format": 4, "current_format": 6, "changed": True, "encrypted_files_unchanged": True}


def contract(approval):
    selected = route(approval)
    require(selected["kind"] == "activation" and selected["marker"] != selected["after"],
            "The approval does not select a format activation")
    return selected["marker"], selected["after"]


def without_marker(value):
    return {key: item for key, item in value.items() if key != "node_marker"}


def expected_stable(approval, state):
    """The stable home that the current phase requires."""
    expected = state["baseline"]["stable"]
    value = state.get("activation")
    if value is None:
        return expected
    contract(approval)
    return {**expected, "node_marker": value["node_marker"]}


def current_marker(home, allowed):
    metadata = Metadata()
    try:
        data = metadata.directory(home / "data", private=False)
        _, contents = metadata.file(data, MARKER, max(len(item) for item in allowed))
        require(contents in allowed, "The primary node marker is not a route marker")
        return contents
    finally:
        metadata.close()


def observed(approval, state, marker):
    """Hold both native owner locks; bind both CURRENT files and the stable home."""
    from native_run_v2_final_links import normalize
    home = Path(approval["primary_home"])
    profile = reference(state["final_backup"]["report"])["run_profile"]
    metadata, roots = selectors(home, profile, stopped=True, marker=marker)
    try:
        require(roots == state["stopped_native_roots"], "A stopped CURRENT file changed around the activation")
        return normalize(approval, state, stable(home, markers(approval)))
    finally:
        metadata.close()


def unchanged_files(home, state):
    manifest = reference(state["final_backup"]["manifest"], 32 * 1024 * 1024)
    found = 0
    for item in manifest["native_file_manifest"]:
        path = item["path"]
        if path == MARKER:
            continue
        require(FILE.fullmatch(path) is not None, "A final native path is invalid")
        count = decimal(item["native_bytes"])
        require(0 < count <= 2**40 and native_hash(home / "data" / path, count) == digest(item["native_sha256"]),
                "The activation changed a native file other than the node marker")
        found += 1
    require(found + 1 == len(manifest["native_file_manifest"]), "The final native file set lacks its marker")
    return found


def command(approval, state, home):
    program = Path(state["candidate_directory"]) / "lastdb"
    require(sha(program) == approval["candidate"]["lastdb"]["sha256"],
            "The activation CLI differs from the exact CI candidate")
    env = {k: v for k, v in os.environ.items() if not k.startswith(
        ("LASTDB_", "FOLD", "AWS_", "B2_", "CF_", "CLOUDFLARE_", "DYLD_", "LD_"))
        and k not in ("EXEMEM_API_URL", "EXEMEM_ENV", "ENVIRONMENT")}
    result = run([program, "--data-dir", home, "db", "enable-alternate-keys", "--i-know-this-is-primary", "--json"],
                 timeout=600, check=False, env=env)
    require(result.returncode == 0 and len(result.stdout.encode()) <= 65536,
            "The offline activation command failed; the marker is checked before any start")
    value = json.loads(result.stdout)
    if value.get("ok") is True and isinstance(value.get("data"), dict):
        value = value["data"]
    require(value == REPLY, "The offline activation reply differs from the exact format 4 to 6 change")
    return value


def activate(approval, state, path):
    """Run after the final stopped backup; resume safely after an interruption."""
    before, after = contract(approval)
    home = Path(approval["primary_home"])
    identity = state["last_stopped_session"]
    require(isinstance(state.get("final_backup"), dict) and state.get("final_backup_requested")
            == approval["final_backup"]["request_id"], "The activation requires the verified final stopped backup")
    require(stopped(home, identity) == state["stop_proof"], "The activation requires the exact clean stop")
    if state.get("activation"):
        verify(approval, state)
        return state["activation"]
    marker = current_marker(home, (before, after))
    reply = None
    if marker == before:
        require(observed(approval, state, before) == state["baseline"]["stable"],
                "The stopped home changed after the final stopped backup")
        record(path, state, "activation-requested", activation_requested_at=int(time.time()))
        reply = command(approval, state, home)
    else:
        # The command renames one complete marker. A prior interrupted run
        # can leave only the new marker; its proof below is the same.
        require(state["phase"] == "activation-requested", "The marker changed without an activation request")
    current = observed(approval, state, after)
    require(without_marker(current) == without_marker(state["baseline"]["stable"])
            and current["node_marker"]["sha256"] == hashlib.sha256(after).hexdigest()
            and current["node_marker"]["size"] == len(after) and current["node_marker"]["nlink"] == 1,
            "The activation changed home identity, cloud controls, or native descriptors")
    value = {"node_marker": current["node_marker"], "reply": reply, "activated_at": int(time.time())}
    value["native_files_unchanged"] = unchanged_files(home, state)
    require(stopped(home, identity) == state["stop_proof"], "The stopped session changed during activation")
    record(path, state, "activated", activation=value)
    return value


def verify(approval, state):
    """The stopped home still holds the exact recorded activation."""
    _, after = contract(approval)
    home = Path(approval["primary_home"])
    require(current_marker(home, (after,)) == after, "The activated marker changed")
    require(observed(approval, state, after) == expected_stable(approval, state),
            "The activated home identity or a stopped CURRENT file changed")


def reconcile(approval, state, path):
    """Record an activation that an interrupted run completed before recovery."""
    if state.get("activation") or state.get("phase") != "activation-requested":
        return
    before, after = contract(approval)
    if current_marker(Path(approval["primary_home"]), (before, after)) == after:
        activate(approval, state, path)
