#!/usr/bin/env python3
"""Offline contract check for cloud transaction groups.

Reads one pin-log source file and an optional redacted evidence file.
Does not open a LastDB home and does not start a cloud cutover.
"""

import json
import sys
from pathlib import Path

FRONTIER = "1787974212509104000"
EVIDENCE_SCHEMA = "lastdb-cloud-transaction-groups-proof.v1"
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


def evidence_failures(path):
    raw = path.read_text()
    for marker in PRIMARY_MARKERS:
        if marker in raw:
            return ["The evidence file names a primary home or a credential."]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ["The evidence file is not JSON."]
    if not isinstance(data, dict):
        return ["The evidence file is not a JSON object."]

    strings = []
    walk_strings(data, strings)
    for item in strings:
        for marker in PRIMARY_MARKERS:
            if marker in item:
                return ["The evidence file names a primary home or a credential."]

    failures = []
    expected_keys = {
        "schema",
        "surface",
        "frontier_drain",
        "publish",
        "restore",
        "canary",
    }
    if set(data) != expected_keys:
        failures.append("The evidence object keys do not match the contract.")
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

    drain = data.get("frontier_drain")
    if not isinstance(drain, dict) or set(drain) != {
        "frontier",
        "drained_on_cow_copy",
        "deleted",
        "quarantined",
    }:
        failures.append("The frontier drain keys do not match the contract.")
    elif (
        drain.get("frontier") != FRONTIER
        or drain.get("drained_on_cow_copy") is not True
        or drain.get("deleted") is not False
        or drain.get("quarantined") is not False
    ):
        failures.append(
            "Frontier %s did not drain on a CoW copy without delete or quarantine."
            % FRONTIER
        )

    publish = data.get("publish")
    if not isinstance(publish, dict) or set(publish) != {
        "failed_upload_leaves_frontier_unchanged",
        "retry_idempotent",
    }:
        failures.append("The publish evidence keys do not match the contract.")
    elif (
        publish.get("failed_upload_leaves_frontier_unchanged") is not True
        or publish.get("retry_idempotent") is not True
    ):
        failures.append("The publish evidence does not prove the frontier and the retry.")

    restore = data.get("restore")
    if not isinstance(restore, dict) or set(restore) != {
        "empty_home",
        "brain_primary_reproduced",
        "projections_exact",
        "v1_single_schema_valid",
        "partial_group_advances_restore_frontier",
    }:
        failures.append("The restore evidence keys do not match the contract.")
    elif (
        restore.get("empty_home") is not True
        or restore.get("brain_primary_reproduced") is not True
        or restore.get("projections_exact") is not True
        or restore.get("v1_single_schema_valid") is not True
        or restore.get("partial_group_advances_restore_frontier") is not False
    ):
        failures.append("The restore evidence does not prove one atomic empty-home restore.")

    canary = data.get("canary")
    soak = canary.get("soak_hours") if isinstance(canary, dict) else None
    if not isinstance(canary, dict) or set(canary) != {
        "safe_upgrade_before_start",
        "soak_hours",
        "live_canary_passed",
    }:
        failures.append("The canary evidence keys do not match the contract.")
    elif (
        canary.get("safe_upgrade_before_start") is not True
        or not isinstance(soak, int)
        or isinstance(soak, bool)
        or soak < 24
        or canary.get("live_canary_passed") is not True
    ):
        failures.append("The live canary did not follow a safe upgrade and a 24-hour soak.")
    return failures


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
        evidence_bad = evidence_failures(evidence_path)
        if evidence_bad:
            lines.append("Operational evidence: FAIL")
            for item in evidence_bad:
                lines.append("- %s" % item)
            failures.extend(evidence_bad)
        else:
            lines.append("Operational evidence: PASS")
            lines.append(
                "- Frontier %s drained on a CoW copy without delete or quarantine."
                % FRONTIER
            )
            lines.append("- A failed upload left the published frontier unchanged.")
            lines.append("- A retry did not duplicate the transaction.")
            lines.append("- An empty-home restore reproduced the Brain primary and the projections.")
            lines.append("- A V1 single-schema restore stayed valid.")
            lines.append("- A partial group did not advance the restore frontier.")
            lines.append("- The live canary followed a safe upgrade and a 24-hour soak.")

    print("\n".join(lines))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
