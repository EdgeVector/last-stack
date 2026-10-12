#!/usr/bin/env python3
"""Reduce one restore failure report to closed public fields only."""

from __future__ import annotations

import json
import os
import stat
import sys
from pathlib import Path

SCHEMA = "lastdb.dev-photograph.restore-error.v1"
INPUT_SCHEMA = "lastdb.restore.error.v1"
INPUT_CAP = 1024
U64_MAX = (1 << 64) - 1
SYNC_CODES = frozenset({
    "operation_failed", "io_error", "crypto_error", "wrong_key",
    "serialization_error", "network_error", "auth_error", "forbidden",
    "quota_exceeded", "object_error", "corrupt_log_entry", "replay_apply_failed",
    "unsupported_envelope", "unsupported_backup_format", "sequence_gap", "sync_error",
})
STAGE_CODES = {
    "source_scope": frozenset({"invalid_source_scope"}),
    "identity_key": frozenset({"io_error", "invalid_identity_key", "crypto_error"}),
    "source_layout": frozenset({
        "operation_failed", "frame_aead_opt_in_required", "layout_mismatch",
    }),
    "prepare_destination": frozenset({"io_error"}),
    "completion_marker": frozenset({"io_error"}),
    "render_report": frozenset({"serialization_error"}),
}
for _stage in (
    "preflight", "cloud_credentials", "open_destination", "runtime_init",
    "open_restore_database", "flush_destination",
):
    STAGE_CODES[_stage] = frozenset({"operation_failed"})
for _stage in (
    "restore_s0_latest_pointer", "restore_s0_manifest_download",
    "restore_s0_manifest_decode", "restore_s0_manifest_validation",
    "restore_s0_latest_pointer_validation", "restore_s0_source_scope_validation",
    "restore_s0_destination_validation", "restore_s0_chunk_download",
    "restore_s0_chunk_install", "restore_s0_destination_integrity",
    "restore_s0_destination_commit", "restore_tail",
):
    STAGE_CODES[_stage] = SYNC_CODES
OPERATIONS = frozenset({
    "put", "delete", "batch_put", "batch_delete", "logical_commit",
    "mutation_intent", "unknown",
})
CAUSES = frozenset({
    "schema_not_found", "schema_blocked", "invalid_field", "invalid_permission",
    "invalid_transform", "invalid_data", "delete_barrier_changed",
    "permission_denied", "catalog_membership_denied", "transport_not_attested",
    "transform_gas_exceeded", "transform_call_depth_exceeded", "cas_conflict",
    "atom_content_too_large", "invalid_cursor", "storage_full", "persist_queue_full",
    "capture_queue_full", "materialization_failed", "missing_mutation_applier",
    "legacy_molecule_delete", "raw_delete_barrier_put", "delete_barrier_identity_mismatch",
    "unknown",
})


def unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate field")
        result[key] = value
    return result


def invalid_constant(_value: str) -> None:
    raise ValueError("non-finite number")


def file_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev, value.st_ino, value.st_uid, value.st_mode, value.st_nlink,
        value.st_size, value.st_mtime_ns, value.st_ctime_ns,
    )


def read_report(name: str) -> bytes:
    path = Path(name)
    if not path.is_absolute() or str(path.resolve(strict=True)) != str(path):
        raise ValueError("non-canonical source")
    before = path.lstat()
    if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid()
            or before.st_nlink != 1 or before.st_mode & 0o022
            or not 0 < before.st_size <= INPUT_CAP):
        raise ValueError("unsafe source")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if file_identity(os.fstat(descriptor)) != file_identity(before):
            raise ValueError("source changed")
        data = os.read(descriptor, INPUT_CAP + 1)
        if (len(data) != before.st_size
                or file_identity(os.fstat(descriptor)) != file_identity(before)
                or file_identity(path.lstat()) != file_identity(before)
                or str(path.resolve(strict=True)) != str(path)):
            raise ValueError("source changed")
        return data
    finally:
        os.close(descriptor)


def require_u64(value: object) -> int:
    if type(value) is not int or not 0 <= value <= U64_MAX:
        raise ValueError("invalid numeric field")
    return value


def public_replay(value: object) -> dict[str, object]:
    required = {"seq", "operation", "cause"}
    optional = {"atom_content_bytes", "atom_limit_bytes"}
    if (not isinstance(value, dict) or not required <= value.keys()
            or not value.keys() <= required | optional):
        raise ValueError("unsupported replay fields")
    if value["operation"] not in OPERATIONS or value["cause"] not in CAUSES:
        raise ValueError("unsupported replay enums")
    replay = {"seq": require_u64(value["seq"]),
              "operation": value["operation"], "cause": value["cause"]}
    supplied = value.keys() & optional
    if supplied:
        if (supplied != optional or value["cause"] != "atom_content_too_large"
                or value["operation"] != "mutation_intent"):
            raise ValueError("unsupported atom diagnosis")
        for field in sorted(optional):
            replay[field] = require_u64(value[field])
    return replay


def public_error(data: bytes) -> dict[str, object]:
    value = json.loads(data.decode("utf-8"), object_pairs_hook=unique_object,
                       parse_constant=invalid_constant)
    required = {"schema", "ok", "stage", "code"}
    if (not isinstance(value, dict) or not required <= value.keys()
            or not value.keys() <= required | {"replay"}
            or value["schema"] != INPUT_SCHEMA or value["ok"] is not False):
        raise ValueError("unsupported envelope")
    stage, code = value["stage"], value["code"]
    if type(stage) is not str or type(code) is not str or code not in STAGE_CODES.get(stage, ()):
        raise ValueError("unsupported stage or code")
    error: dict[str, object] = {
        "schema": INPUT_SCHEMA, "ok": False, "stage": stage, "code": code,
    }
    if "replay" in value:
        if stage != "restore_tail" or code != "replay_apply_failed":
            raise ValueError("unsupported replay boundary")
        error["replay"] = public_replay(value["replay"])
    return error


def main(argv: list[str]) -> int:
    output: dict[str, object] = {
        "schema": SCHEMA, "captured": False, "reason": "UNKNOWN", "error": None,
    }
    try:
        if len(argv) == 2 and argv[0] == "--source":
            error = public_error(read_report(argv[1]))
            output.update(captured=True, reason="VALIDATED", error=error)
    except Exception:
        # Never format the input, path, parser error, or exception into output.
        pass
    print(json.dumps(output, ensure_ascii=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv[1:]))
    except BrokenPipeError:
        raise SystemExit(0)
