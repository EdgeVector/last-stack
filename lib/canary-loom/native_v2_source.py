"""Use only supported foreground V2 source commands and metadata-only boundary reads."""

import json
import os
from pathlib import Path
import re
import time
import uuid

from native_upgrade_common import require, run
from native_v2_freshness import (configuration as freshness_configuration,
                                 observe as observe_freshness, validate as validate_freshness)


def root(value):
    fields = {"home_id", "home_digest", "generation", "frontier", "current_sha256", "required_features"}
    require(isinstance(value, dict) and set(value) == fields, "Native root fields differ")
    require(re.fullmatch(r"[0-9a-f-]{36}", value["home_id"]) is not None,
            "Native home identity is absent")
    for name in ("home_digest", "current_sha256"):
        require(re.fullmatch(r"[0-9a-f]{64}", value[name]) is not None, "Native root digest differs")
    for name in ("generation", "frontier", "required_features"):
        require(isinstance(value[name], str) and value[name].isdigit()
                and 0 <= int(value[name]) <= 2**64 - 1, "Native root integer differs")
    return value


def boundary(approval, candidate):
    result = run([candidate["lastdb"]["path"], "--data-dir", approval["primary_home"],
                  "cloud", "backup-v2", "boundary", "--json"], timeout=60)
    require(len(result.stdout) <= 65536, "Boundary response exceeds its bound")
    value = json.loads(result.stdout)
    require(value["version"] == 1 and value["metadata_only"] is True
            and value["writer_fence_held"] is False
            and value["account_id"] == approval["recovery"]["account_id"]
            and value["identity_public_key"] == approval["recovery"]["identity_public_key"],
            "Stopped account identity or metadata observation differs")
    return root(value["native_root"])


def invoke(approval, candidate, action, request_id=None):
    recovery = approval["recovery"]
    argv = [candidate["lastdb"]["path"], "--data-dir", approval["primary_home"],
            "cloud", "backup-v2", "standalone", "--state-dir", recovery["state_dir"],
            "--credentials-home", recovery["credentials_home"], "--env", recovery["environment"], action]
    if request_id:
        argv += ["--request-id", request_id]
    environment = dict(os.environ, LASTDB_BYTE_BACKUP_V2_ENABLED="1")
    result = run([*argv, "--json"], timeout=3600 if action in ("start", "resume") else 60, env=environment)
    require(len(result.stdout) <= 1024 * 1024, "Standalone response exceeds its bound")
    return json.loads(result.stdout)


def live_recovery(approval, candidate, identity, report=None):
    if report is None:
        report = invoke(approval, candidate, "status")
    proof = observe_freshness(approval, report, identity)
    accepted(approval, report, approval["recovery"]["live_request_id"],
             live_proof=proof, live_session=identity)
    return report, proof


def accepted(approval, report, request_id, at=None, stopped_since=None, live_proof=None, live_session=None):
    recovery = approval["recovery"]
    captured = root(report["captured_native_root"])
    backup = report["accepted_backup"]
    now = int(time.time()) if at is None else at
    require(report["version"] == 1 and report["phase"] == "published"
            and report["request_id"] == request_id
            and report["account_id"] == recovery["account_id"]
            and report["identity_public_key"] == recovery["identity_public_key"]
            and report["source_home"] == captured["home_id"] == recovery["home_id"]
            and captured["home_digest"] == recovery["home_digest"], "Recovery point belongs to another home")
    require(report["terminal_clean"] is True and report["retained_source_bytes"] == 0,
            "Recovery point is not accepted and fully released")
    captured_at = report["capture_started_at"]
    require(type(captured_at) is int and 0 <= now - captured_at,
            "Recovery point age is absent or future")
    if stopped_since is None:
        validate_freshness(approval, report, live_proof, live_session, now)
    else:
        # Final uploads may exceed five minutes. No writer runs, and the caller
        # independently requires the complete CURRENT identity to remain equal.
        require(captured_at >= stopped_since, "Final recovery point predates the clean stop")
    job = backup["begin"]["job"]
    require(backup["version"] == 2 and job["commit_id"] == request_id
            and job["stream"]["scope"]["account_id"] == recovery["account_id"]
            and job["stream"]["scope"]["account_generation"] == recovery["account_generation"]
            and re.fullmatch(r"[0-9a-f]{64}", backup["commit_sha256"]) is not None,
            "Recovery point is not the exact accepted V2 job")
    return captured


def validate_configuration(approval):
    recovery = approval["recovery"]
    freshness_configuration(approval)
    require(recovery["environment"] == "prod", "Primary upgrade requires the explicit PROD V2 endpoint")
    require(re.fullmatch(r"[0-9a-f]{32}", recovery["account_id"]) is not None,
            "Recovery account identity differs")
    require(isinstance(recovery["identity_public_key"], str) and 1 <= len(recovery["identity_public_key"]) <= 256
            and re.fullmatch(r"[0-9a-f]{64}", recovery["home_digest"]) is not None
            and re.fullmatch(r"0|[1-9][0-9]{0,19}", recovery["account_generation"]) is not None,
            "Recovery identity or account generation differs")
    for name in ("live_request_id", "final_request_id", "home_id"):
        require(str(uuid.UUID(recovery[name])) == recovery[name], "Recovery UUID is not canonical")
    require(recovery["live_request_id"] != recovery["final_request_id"], "Final cut needs its own fixed job identity")
    for name in ("state_dir", "credentials_home"):
        path = Path(recovery[name])
        require(path.is_absolute() and path.resolve() == path, "Recovery path is not explicit and canonical")
    state = Path(recovery["state_dir"])
    home = Path(approval["primary_home"])
    require(not state.is_relative_to(home) and state != Path(recovery["credentials_home"]),
            "Standalone state must be external to source and credentials")
