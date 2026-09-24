#!/usr/bin/env python3
"""Offline contract check for primary cloud-sync resume.

Reads Fold source files and an optional redacted evidence file.
Does not open a LastDB home and does not re-enable primary cloud sync.
"""

import json
import re
import sys
from datetime import datetime
from pathlib import Path

EVIDENCE_SCHEMA = "lastdb-cloud-sync-resume-proof.v1"
SITUATION_SLUG = "cloud-sync-paused-pending-laststore-redesign-20260719"
UTC_FMT = "%Y-%m-%dT%H:%M:%SZ"
SHA_RE = re.compile(r"^[0-9a-f]{64}$")
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')
PRIMARY_MARKERS = (
    "/.lastdb",
    "/.folddb",
    "~/.lastdb",
    "~/.folddb",
    "BEGIN PRIVATE",
    "BEGIN OPENSSH",
    "AKIA",
)
SOURCE_FILES = {
    "fold_db/crates/core/src/sync/snapshot_log/mod.rs": "snapshot-log",
    "fold_db/crates/core/src/sync/engine/backup_uploader.rs": "backup-uploader",
    "fold_db/crates/core/src/sync/engine/wiring.rs": "upload-interlock",
    "fold_db/crates/core/src/sync/engine/file_blob.rs": "file-blob",
    "fold_db/crates/core/src/sync/engine/cycle.rs": "degraded-cycle",
    "fold_db/crates/core/src/fold_db_core/fold_db/sync.rs": "cloud-off",
    "vendor/laststore/src/options.rs": "hash-group",
}


def strip_strings(text):
    return STRING_RE.sub('""', text)


def require_text(text, needle, label, failures):
    if needle not in strip_strings(text):
        failures.append(label)


def read_source(source_dir):
    texts = {}
    missing = []
    for rel in SOURCE_FILES:
        path = source_dir / rel
        if not path.is_file() or path.stat().st_size == 0:
            missing.append(rel)
            continue
        texts[rel] = path.read_text(encoding="utf-8", errors="replace")
    return texts, missing


def source_failures(source_dir):
    failures = []
    texts, missing = read_source(source_dir)
    for rel in missing:
        failures.append("The Fold %s source is absent." % SOURCE_FILES[rel])
    if missing:
        return failures

    snap = texts["fold_db/crates/core/src/sync/snapshot_log/mod.rs"]
    require_text(
        snap,
        "mutation log + snapshot frontier F + CAS latest",
        "The snapshot-log source lacks the v1 object model.",
        failures,
    )
    require_text(
        snap,
        "pub const SNAPSHOT_LOG_MODEL_VERSION: u32 = 1;",
        "The snapshot-log source lacks model version 1.",
        failures,
    )
    require_text(
        snap,
        "pub fn cas_allows_replace(current: Option<&Self>, candidate: &Self) -> bool",
        "The snapshot-log source lacks CAS replace.",
        failures,
    )

    backup = texts["fold_db/crates/core/src/sync/engine/backup_uploader.rs"]
    require_text(
        backup,
        "Upload sealed local files (chunks) as-is",
        "The backup uploader does not upload sealed files as-is.",
        failures,
    )
    require_text(
        backup,
        "Never blocks local Mini R/W",
        "The backup uploader does not keep local reads and writes free.",
        failures,
    )

    wiring = texts["fold_db/crates/core/src/sync/engine/wiring.rs"]
    require_text(
        wiring,
        "pub async fn cloud_plane_allows_upload(&self) -> bool",
        "The upload interlock is absent.",
        failures,
    )
    require_text(
        wiring,
        "Hard interlock:",
        "The upload interlock does not forbid cloud writes while Off.",
        failures,
    )
    require_text(
        wiring,
        "pub async fn reenable_cloud_sync(&self) -> CloudSyncReenableOutcome",
        "The explicit re-enable function is absent.",
        failures,
    )
    require_text(
        wiring,
        "pub async fn set_cloud_sync_disabled(&self, disabled: bool)",
        "The explicit cloud-off function is absent.",
        failures,
    )

    cloud_off = texts["fold_db/crates/core/src/fold_db_core/fold_db/sync.rs"]
    require_text(
        cloud_off,
        "pub async fn set_cloud_sync_disabled_live(&self, disabled: bool)",
        "The public cloud-off command is absent.",
        failures,
    )
    require_text(
        cloud_off,
        "pub async fn reenable_cloud_sync_live(",
        "The public re-enable command is absent.",
        failures,
    )
    require_text(
        cloud_off,
        "lastdb cloud off",
        "The durable cloud-off pause is absent.",
        failures,
    )

    blobs = texts["fold_db/crates/core/src/sync/engine/file_blob.rs"]
    require_text(
        blobs,
        "pub async fn upload_file_blob(&self, plaintext: &[u8]) -> SyncResult<FileBlobRef>",
        "The file-blob upload route is absent.",
        failures,
    )
    require_text(
        blobs,
        "pub async fn download_file_blob(&self, blob_ref: &FileBlobRef) -> SyncResult<Option<Vec<u8>>>",
        "The file-blob fetch route is absent.",
        failures,
    )

    cycle = texts["fold_db/crates/core/src/sync/engine/cycle.rs"]
    require_text(
        cycle,
        "pub(crate) async fn record_sync_failure(&self, err: &SyncError)",
        "The degraded failure record is absent.",
        failures,
    )
    require_text(
        cycle,
        "upload_backlog_after",
        "The backlog field is absent.",
        failures,
    )

    options = texts["vendor/laststore/src/options.rs"]
    require_text(
        options,
        "layout_mode: LayoutMode::HashGroup",
        "The hash-group default is absent.",
        failures,
    )
    return failures


def walk_strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from walk_strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from walk_strings(item)


def req_bool(obj, key, expected, failures):
    if not isinstance(obj, dict) or key not in obj or not isinstance(obj[key], bool):
        failures.append("The evidence field %s is not a boolean." % key)
        return
    if obj[key] is not expected:
        failures.append("The evidence field %s is not %s." % (key, str(expected).lower()))


def req_int(obj, key, failures, measured):
    if not isinstance(obj, dict) or key not in obj:
        measured["gap"] = True
        failures.append("The evidence field %s is absent." % key)
        return None
    value = obj[key]
    if isinstance(value, bool) or not isinstance(value, int):
        measured["gap"] = True
        failures.append("The evidence field %s is not a measured integer." % key)
        return None
    return value


def req_time(obj, key, failures):
    if not isinstance(obj, dict) or not isinstance(obj.get(key), str):
        failures.append("The evidence field %s is not a UTC timestamp." % key)
        return None
    try:
        return datetime.strptime(obj[key], UTC_FMT)
    except ValueError:
        failures.append("The evidence field %s is not a UTC timestamp." % key)
        return None


def section(data, name, failures):
    value = data.get(name)
    if not isinstance(value, dict):
        failures.append("The evidence section %s is absent." % name)
        return {}
    return value


def evidence_failures(path):
    failures = []
    measured = {"gap": False}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError):
        return ["The evidence file is not JSON."]
    if not isinstance(data, dict):
        return ["The evidence file is not a JSON object."]
    if data.get("schema") != EVIDENCE_SCHEMA:
        failures.append("The evidence schema is not %s." % EVIDENCE_SCHEMA)

    for text in walk_strings(data):
        for marker in PRIMARY_MARKERS:
            if marker in text:
                failures.append("The evidence names a LastDB home or a secret.")
                break

    surface = section(data, "surface", failures)
    kind = surface.get("kind")
    if kind not in ("cow", "ephemeral"):
        failures.append("The probe surface is not a CoW copy or an ephemeral home.")
    req_bool(surface, "primary_home_opened", False, failures)
    req_bool(surface, "primary_mutated", False, failures)
    req_bool(surface, "primary_reenabled_by_harness", False, failures)
    req_bool(surface, "live_cutover", False, failures)
    home = surface.get("home_path")
    if not isinstance(home, str) or not home.startswith("/") or home in ("/", ""):
        failures.append("The probe home path is absent.")
    elif any(marker in home for marker in PRIMARY_MARKERS):
        failures.append("The evidence names a LastDB home or a secret.")

    groups = section(data, "hash_group", failures)
    documents = req_int(groups, "cow_document_count", failures, measured)
    group_files = req_int(groups, "group_file_count", failures, measured)
    group_bytes = req_int(groups, "group_bytes_uploaded", failures, measured)
    staging_objects = req_int(groups, "staging_object_count", failures, measured)
    if documents is not None and documents < 1:
        failures.append("The hash-group CoW proof has no documents.")
    if group_files is not None and group_files < 1:
        failures.append("The probe uploaded no group files.")
    if group_bytes is not None and group_bytes < 1:
        failures.append("The probe uploaded no group bytes.")
    if (
        staging_objects is not None
        and group_files is not None
        and (staging_objects < 0 or staging_objects > group_files)
    ):
        failures.append("The staging object count exceeds the group file count.")
    if groups.get("cow_proof_verdict") != "PASS":
        failures.append("The hash-group CoW proof verdict is not PASS.")
    req_bool(groups, "promoted", False, failures)
    req_bool(groups, "source_unchanged", True, failures)

    probe = section(data, "probe", failures)
    upload_bytes = req_int(probe, "upload_bytes", failures, measured)
    window_secs = req_int(probe, "upload_window_secs", failures, measured)
    growth = req_int(probe, "staging_growth_bytes", failures, measured)
    backlog_start = req_int(probe, "backlog_start", failures, measured)
    backlog_end = req_int(probe, "backlog_end", failures, measured)
    window_start = req_time(probe, "window_start", failures)
    window_end = req_time(probe, "window_end", failures)
    req_bool(probe, "degraded", False, failures)
    if upload_bytes is not None and growth is not None and upload_bytes <= growth:
        failures.append("Upload throughput does not exceed staging growth.")
    if growth is not None and growth < 0:
        failures.append("Staging growth is negative.")
    if window_secs is not None and (window_secs < 1 or window_secs > 86400):
        failures.append("The probe window is not bounded between 1 and 86400 seconds.")
    if backlog_start is not None and backlog_end is not None:
        if backlog_start < 0 or backlog_end < 0 or backlog_end >= backlog_start:
            failures.append("The backlog does not converge.")
    if window_start is not None and window_end is not None and window_secs is not None:
        delta = int((window_end - window_start).total_seconds())
        if delta != window_secs or delta < 1:
            failures.append("The probe window does not match the measured duration.")

    reenable = section(data, "reenable", failures)
    if reenable.get("situation_slug") != SITUATION_SLUG:
        failures.append("The Situation slug is not the cloud-sync pause.")
    if reenable.get("cleared_by") != "Tom":
        failures.append("Tom did not clear the Situation.")
    if reenable.get("reenable_actor") != "Tom":
        failures.append("Tom did not perform the bounded re-enable.")
    cleared_at = req_time(reenable, "situation_cleared_at", failures)
    reenable_at = req_time(reenable, "reenable_at", failures)
    if cleared_at is not None and reenable_at is not None and cleared_at >= reenable_at:
        failures.append("The Situation clearance is not before the re-enable.")

    catchup = section(data, "catchup", failures)
    lag = req_int(catchup, "primary_sync_lag_bytes", failures, measured)
    depth = req_int(catchup, "staging_depth", failures, measured)
    cap = req_int(catchup, "staging_cap", failures, measured)
    if lag is not None and lag != 0:
        failures.append("Primary sync lag is not zero.")
    if depth is not None and cap is not None and (depth < 0 or cap <= depth):
        failures.append("Staging depth is not below the cap.")
    for key in (
        "brain_reads",
        "brain_writes",
        "kanban_reads",
        "kanban_writes",
        "lastgit_reads",
        "lastgit_writes",
    ):
        count = req_int(catchup, key, failures, measured)
        if count is not None and count < 1:
            failures.append("The local %s count is zero." % key)

    blobs = section(data, "file_blob", failures)
    blob_upload = req_int(blobs, "upload_bytes", failures, measured)
    blob_fetch = req_int(blobs, "fetch_bytes", failures, measured)
    if blob_upload is not None and blob_upload < 1:
        failures.append("The file-blob canary uploaded no bytes.")
    if blob_upload is not None and blob_fetch is not None and blob_fetch != blob_upload:
        failures.append("The file-blob fetch byte count does not match the upload.")
    if blobs.get("upload_route") != "upload_file_blob":
        failures.append("The file-blob upload route is not configured.")
    if blobs.get("fetch_route") != "download_file_blob":
        failures.append("The file-blob fetch route is not configured.")
    digest = blobs.get("canary_sha256")
    if not isinstance(digest, str) or SHA_RE.fullmatch(digest) is None:
        measured["gap"] = True
        failures.append("The file-blob canary has no SHA-256 sample.")

    if measured["gap"]:
        failures.append("The evidence lacks measured CoW or ephemeral output.")
    return failures


def measured_summary(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    probe = data["probe"]
    groups = data["hash_group"]
    catchup = data["catchup"]
    blobs = data["file_blob"]
    reenable = data["reenable"]
    return "\n".join(
        [
            "Measured probe: upload_bytes %s is above staging_growth_bytes %s over %s seconds."
            % (probe["upload_bytes"], probe["staging_growth_bytes"], probe["upload_window_secs"]),
            "Backlog moved from %s to %s." % (probe["backlog_start"], probe["backlog_end"]),
            "Hash-group CoW documents: %s. Group files: %s. Staging objects: %s."
            % (
                groups["cow_document_count"],
                groups["group_file_count"],
                groups["staging_object_count"],
            ),
            "File-blob canary bytes: %s. Fetch bytes matched." % blobs["upload_bytes"],
            "Situation %s cleared at %s. Tom re-enabled at %s."
            % (
                SITUATION_SLUG,
                reenable["situation_cleared_at"],
                reenable["reenable_at"],
            ),
            "Primary sync lag bytes: %s. Staging depth %s is below cap %s."
            % (catchup["primary_sync_lag_bytes"], catchup["staging_depth"], catchup["staging_cap"]),
        ]
    )


def main():
    source_dir = Path(sys.argv[1])
    evidence_arg = sys.argv[2] if len(sys.argv) > 2 else ""
    failures = source_failures(source_dir)
    source_line = "Source contract: FAIL" if failures else "Source contract: PASS"
    lines = [
        source_line,
        "The harness did not open a LastDB home.",
        "The harness did not re-enable primary cloud sync.",
    ]
    if failures:
        lines.append("")
        lines.append("Source failures:")
        lines.extend("- %s" % item for item in failures)

    if not evidence_arg:
        lines.insert(1, "Operational evidence: ABSENT")
        lines.append("")
        lines.append("Operational evidence is absent.")
        lines.append(
            "Set CLOUD_SYNC_RESUME_PROOF_EVIDENCE_FILE to redacted JSON with schema %s."
            % EVIDENCE_SCHEMA
        )
        lines.append("The file must carry measured CoW or ephemeral output.")
        lines.append("The harness does not read a LastDB home to build that file.")
        print("\n".join(lines))
        return 1

    evidence_path = Path(evidence_arg)
    op_failures = evidence_failures(evidence_path)
    if op_failures:
        lines.insert(1, "Operational evidence: FAIL")
        lines.append("")
        lines.append("Evidence failures:")
        lines.extend("- %s" % item for item in op_failures)
        print("\n".join(lines))
        return 1

    lines.insert(1, "Operational evidence: PASS")
    lines.append("")
    lines.append(measured_summary(evidence_path))
    print("\n".join(lines))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
