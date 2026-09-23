#!/usr/bin/env python3
"""Offline contract check for cloud transaction groups.

Reads one pin-log source file and an optional redacted evidence file.
Does not open a LastDB home and does not start a cloud cutover.
"""

import json
import re
import sys
from datetime import datetime
from pathlib import Path

FRONTIER = "1787974212509104000"
FRONTIER_N = int(FRONTIER)
EVIDENCE_SCHEMA = "lastdb-cloud-transaction-groups-proof.v1"
INT_RE = re.compile(r"[0-9]+")
UTC_RE = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z")
SHA_RE = re.compile(r"[0-9a-f]{64}")
SOAK_SECONDS = 24 * 60 * 60
PRIMARY_MARKERS = (
    "/.lastdb",
    "/.folddb",
    "~/.lastdb",
    "~/.folddb",
    "BEGIN PRIVATE",
    "BEGIN OPENSSH",
    "AKIA",
)


def region(text, signature):
    start = text.find(signature)
    if start < 0:
        return None
    line_start = text.rfind("\n", 0, start) + 1
    indent = start - line_start
    rest_start = start + len(signature)
    acc = text[start:rest_start]
    for line in text[rest_start:].split("\n"):
        stripped = line.lstrip(" ")
        pad = len(line) - len(stripped)
        if pad == indent and (
            stripped.startswith("fn ")
            or stripped.startswith("async fn ")
            or stripped.startswith("pub ")
            or stripped.startswith("pub(crate)")
        ):
            break
        acc += "\n" + line
    return acc


def require_text(text, needle, label, failures):
    if needle not in text:
        failures.append(label)


def require_region(text, signature, needles, failures):
    body = region(text, signature)
    if body is None:
        failures.append("The pin-log source lacks %s." % signature)
        return None
    for needle, label in needles:
        if needle not in body:
            failures.append(label)
    return body


def require_order(body, first, second, label, failures):
    if body is None:
        return
    left = body.find(first)
    right = body.find(second)
    if left < 0 or right < 0 or left >= right:
        failures.append(label)


def source_failures(text):
    failures = []
    require_text(
        text,
        'const TRANSACTION_GROUP_WIRE_VERSION: u32 = 2;',
        "The pin-log source lacks wire version 2.",
        failures,
    )
    require_text(
        text,
        'const TRANSACTION_GROUP_MANIFEST_SCHEMA: &str = "__lastdb_transaction_group_v2__";',
        "The pin-log source lacks the group manifest schema.",
        failures,
    )
    require_text(
        text,
        "fn transaction_group_id(",
        "The pin-log source lacks a stable group identifier.",
        failures,
    )

    seal = require_region(
        text,
        "async fn seal_transaction_group(",
        [
            (
                "if schemas.len() < 2",
                "The sealer does not require more than one schema.",
            ),
            (
                "TransactionGroupWireV2::Shard",
                "The sealer does not build a shard.",
            ),
            (
                "group_id: group_id.clone()",
                "A shard does not carry the group identifier.",
            ),
            (
                "writer_id: writer.to_string()",
                "A shard does not carry the writer identity.",
            ),
            (
                "frontier_after: record.frontier_after",
                "A shard does not carry the frontier.",
            ),
            (
                "shard_count,",
                "A shard does not carry the shard count.",
            ),
            (
                "TRANSACTION_GROUP_MANIFEST_SCHEMA",
                "The manifest does not use the group manifest schema.",
            ),
            (
                "TransactionGroupWireV2::Manifest",
                "The sealer does not build a manifest.",
            ),
        ],
        failures,
    )
    require_order(
        seal,
        "TransactionGroupWireV2::Shard",
        "TransactionGroupWireV2::Manifest",
        "The sealer does not place the manifest after the shards.",
        failures,
    )

    publish = require_region(
        text,
        "async fn seal_mutation_log_publish_unit(",
        [
            (
                "MutationLogRecordStream::MultiSchema",
                "The publisher does not detect a multi-schema record.",
            ),
            (
                "seal_transaction_group(",
                "The publisher does not seal a multi-schema record as a group.",
            ),
            (
                "seal_mutation_log_segment_batch(",
                "The publisher does not keep the single-schema segment path.",
            ),
        ],
        failures,
    )
    require_order(
        publish,
        "MutationLogRecordStream::MultiSchema",
        "seal_mutation_log_segment_batch(",
        "The single-schema path is not the fallback after the group path.",
        failures,
    )

    replay = require_region(
        text,
        "async fn open_mutation_log_replay_units(",
        [
            (
                "transaction_group: false",
                "A V1 segment is not kept as a non-group replay unit.",
            ),
            (
                "has shards but no commit manifest",
                "A group without a manifest can replay.",
            ),
            (
                "shard count does not match its manifest",
                "A group with a missing shard can replay.",
            ),
        ],
        failures,
    )
    require_order(
        replay,
        "transaction_group: false",
        "has shards but no commit manifest",
        "The V1 replay path is not distinct from group commit checks.",
        failures,
    )

    require_region(
        text,
        "async fn multi_schema_cloud_publish_failure_keeps_record_and_frontier(",
        [
            (
                "mutation_log.frontier_f, frontier_before",
                "A failed upload does not keep the published frontier.",
            ),
            (
                "mutation_log.segments_uploaded, 0",
                "A failed upload does not keep the upload count at zero.",
            ),
        ],
        failures,
    )
    require_region(
        text,
        "async fn transaction_group_seals_one_shard_per_schema_and_a_manifest_last(",
        [
            (
                "TRANSACTION_GROUP_MANIFEST_SCHEMA",
                "The seal test does not expect the manifest schema last.",
            ),
            (
                "a retry must use stable object keys",
                "A retry can mint new object keys.",
            ),
        ],
        failures,
    )
    require_region(
        text,
        "async fn transaction_group_without_manifest_fails_before_replay(",
        [
            (
                'error.contains("no commit manifest")',
                "The missing-manifest test does not fail before replay.",
            )
        ],
        failures,
    )
    require_region(
        text,
        "async fn transaction_group_with_missing_shard_fails_before_replay(",
        [
            (
                'error.contains("shard count")',
                "The missing-shard test does not fail before replay.",
            )
        ],
        failures,
    )
    require_region(
        text,
        "async fn transaction_group_rejects_a_resealed_shard_not_named_by_manifest(",
        [
            (
                'error.contains("manifest validation")',
                "A resealed shard can pass the manifest check.",
            )
        ],
        failures,
    )
    return failures


def walk_strings(value, found):
    if isinstance(value, str):
        found.append(value)
    elif isinstance(value, dict):
        for key, item in value.items():
            found.append(str(key))
            walk_strings(item, found)
    elif isinstance(value, list):
        for item in value:
            walk_strings(item, found)


def measured_text(value):
    return isinstance(value, str) and bool(value.strip())


def measured_map(text):
    values = {}
    for line in text.splitlines():
        if ":" not in line:
            continue
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if key and key not in values:
            values[key] = value
    return values


def measured_int(values, key):
    raw = values.get(key)
    if raw is None or INT_RE.fullmatch(raw) is None:
        return None
    return int(raw)


def measured_time(values, key):
    raw = values.get(key)
    if raw is None or UTC_RE.fullmatch(raw) is None:
        return None
    return datetime.strptime(raw, "%Y-%m-%dT%H:%M:%SZ")


def cow_measure(text):
    values = measured_map(text)
    failures = []
    before = measured_int(values, "published_through_before")
    after = measured_int(values, "published_through_after")
    rows_before = measured_int(values, "pin_rows_before")
    rows_after = measured_int(values, "pin_rows_after")
    deleted = measured_int(values, "deleted")
    quarantined = measured_int(values, "quarantined")
    failed_before = measured_int(values, "failed_upload_frontier_before")
    failed_after = measured_int(values, "failed_upload_frontier_after")
    retry_objects = measured_int(values, "retry_object_count")
    retry_new = measured_int(values, "retry_new_keys")
    if (
        values.get("frontier") != FRONTIER
        or before is None
        or after is None
        or before >= FRONTIER_N
        or after < FRONTIER_N
    ):
        failures.append(
            "Frontier %s did not drain on the measured CoW output." % FRONTIER
        )
    if (
        rows_before is None
        or rows_after is None
        or rows_before <= rows_after
        or deleted != 0
        or quarantined != 0
    ):
        failures.append(
            "The CoW output did not record a row drain without delete or quarantine."
        )
    if (
        failed_before is None
        or failed_after is None
        or failed_before != failed_after
        or retry_objects is None
        or retry_objects < 1
        or retry_new != 0
    ):
        failures.append(
            "The CoW output did not measure an unchanged frontier and an idempotent retry."
        )
    notes = []
    if not failures:
        notes.append(
            "- Frontier %s drained on a CoW copy. published_through %s to %s. pin rows %s to %s. deleted=0 quarantined=0."
            % (FRONTIER, before, after, rows_before, rows_after)
        )
        notes.append(
            "- A failed upload left published_through at %s. A retry reused %s object keys and minted 0 new keys."
            % (failed_before, retry_objects)
        )
    return failures, notes


def restore_measure(text):
    values = measured_map(text)
    failures = []
    primary = measured_int(values, "primary_records")
    restored = measured_int(values, "restored_records")
    primary_hash = values.get("primary_projection_sha256")
    restored_hash = values.get("restored_projection_sha256")
    v1_records = measured_int(values, "v1_records")
    v1_restored = measured_int(values, "v1_restored_records")
    partial_before = measured_int(values, "partial_group_frontier_before")
    partial_after = measured_int(values, "partial_group_frontier_after")
    if primary is None or restored is None or primary < 1 or primary != restored:
        failures.append(
            "The restore output does not show equal primary and restored records."
        )
    if (
        primary_hash is None
        or restored_hash is None
        or SHA_RE.fullmatch(primary_hash) is None
        or primary_hash != restored_hash
    ):
        failures.append("The restore output does not show equal projection digests.")
    if (
        v1_records is None
        or v1_restored is None
        or v1_records < 1
        or v1_records != v1_restored
    ):
        failures.append(
            "The restore output does not show a valid V1 single-schema restore."
        )
    if (
        partial_before is None
        or partial_after is None
        or partial_before != partial_after
    ):
        failures.append("A partial group advanced the restore frontier.")
    notes = []
    if not failures:
        notes.append(
            "- An empty-home restore reproduced %s records. projection sha256 %s matched. V1 records %s matched. The partial-group frontier stayed %s."
            % (primary, primary_hash, v1_records, partial_before)
        )
    return failures, notes


def soak_measure(text):
    values = measured_map(text)
    failures = []
    upgrade = measured_time(values, "safe_upgrade_at")
    started = measured_time(values, "soak_started_at")
    ended = measured_time(values, "soak_ended_at")
    canary = measured_time(values, "canary_started_at")
    if upgrade is None or started is None or ended is None or canary is None:
        failures.append("The soak output has no measured window.")
        return failures, []
    if upgrade > started:
        failures.append("The safe upgrade is not before the soak window.")
    window = (ended - started).total_seconds()
    if window < SOAK_SECONDS:
        failures.append("The soak window is shorter than 24 hours.")
    if canary < ended:
        failures.append("The canary started before the soak window ended.")
    notes = []
    if not failures:
        notes.append(
            "- The soak window ran from %s to %s. The canary started at %s after the safe upgrade at %s."
            % (
                values["soak_started_at"],
                values["soak_ended_at"],
                values["canary_started_at"],
                values["safe_upgrade_at"],
            )
        )
    return failures, notes


def evidence_assessment(path):
    raw = path.read_text()
    for marker in PRIMARY_MARKERS:
        if marker in raw:
            return ["The evidence file names a primary home or a credential."], []
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ["The evidence file is not JSON."], []
    if not isinstance(data, dict):
        return ["The evidence file is not a JSON object."], []

    strings = []
    walk_strings(data, strings)
    for item in strings:
        for marker in PRIMARY_MARKERS:
            if marker in item:
                return ["The evidence file names a primary home or a credential."], []

    failures = []
    if data.get("schema") != EVIDENCE_SCHEMA:
        failures.append("The evidence schema is not %s." % EVIDENCE_SCHEMA)

    surface = data.get("surface")
    if not isinstance(surface, dict) or set(surface) != {
        "kind",
        "primary_home_opened",
        "primary_mutated",
        "live_cutover",
    }:
        failures.append("The evidence surface keys do not match the contract.")
    elif (
        surface.get("kind") != "cow"
        or surface.get("primary_home_opened") is not False
        or surface.get("primary_mutated") is not False
        or surface.get("live_cutover") is not False
    ):
        failures.append(
            "The evidence surface is not a CoW copy with the primary home closed."
        )

    cow = data.get("cow_output")
    restore = data.get("restore_output")
    soak = data.get("soak_output")
    if not (
        measured_text(cow) and measured_text(restore) and measured_text(soak)
    ):
        failures.append(
            "The evidence file lacks measured CoW output for frontier %s, the restore, and the soak window."
            % FRONTIER
        )
        return failures, []

    cow_bad, cow_notes = cow_measure(cow)
    restore_bad, restore_notes = restore_measure(restore)
    soak_bad, soak_notes = soak_measure(soak)
    failures.extend(cow_bad)
    failures.extend(restore_bad)
    failures.extend(soak_bad)
    if failures:
        return failures, []
    return [], cow_notes + restore_notes + soak_notes


def main():
    if len(sys.argv) < 2:
        print("The checker needs the pin-log source path.")
        return 1
    source_path = Path(sys.argv[1])
    evidence_arg = sys.argv[2] if len(sys.argv) > 2 else ""
    mode = sys.argv[3] if len(sys.argv) > 3 else "offline"
    try:
        text = source_path.read_text()
    except OSError as exc:
        print("The harness could not read the pin-log source: %s" % exc)
        return 1

    lines = [
        "Mode: %s" % mode,
        "",
        "The harness read the Fold pin-log source.",
        "The harness did not open a LastDB home.",
        "The harness did not start a cloud cutover.",
        "",
        "Source: %s" % source_path,
        "",
    ]
    failures = source_failures(text)
    if failures:
        lines.append("Source contract: FAIL")
        for item in failures:
            lines.append("- %s" % item)
    else:
        lines.append("Source contract: PASS")
        lines.extend(
            [
                "- The publisher seals one shard for each schema.",
                "- The publisher seals the group manifest last.",
                "- A shard carries the group identifier, the writer, the frontier, and the shard count.",
                "- A failed cloud upload leaves the published frontier unchanged.",
                "- A retry uses the same object keys.",
                "- A group without a manifest does not replay.",
                "- A group with a missing shard does not replay.",
                "- A V1 segment stays a non-group replay unit.",
            ]
        )

    lines.append("")
    if not evidence_arg:
        lines.append("Operational evidence: ABSENT")
        lines.append(
            "- Frontier %s did not drain on a CoW copy in this run." % FRONTIER
        )
        lines.append("- An empty-home restore did not run.")
        lines.append("- The 24-hour soak did not run.")
        lines.append("- The live canary did not run.")
        if not failures:
            failures.append("Operational evidence is absent.")
    else:
        evidence_path = Path(evidence_arg)
        evidence_bad, evidence_notes = evidence_assessment(evidence_path)
        if evidence_bad:
            lines.append("Operational evidence: FAIL")
            for item in evidence_bad:
                lines.append("- %s" % item)
            failures.extend(evidence_bad)
        else:
            lines.append("Operational evidence: PASS")
            lines.extend(evidence_notes)

    print("\n".join(lines))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
