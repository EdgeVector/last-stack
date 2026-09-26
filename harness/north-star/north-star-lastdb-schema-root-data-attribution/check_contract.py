#!/usr/bin/env python3
"""Offline contract check for schema-root data attribution.

Reads Fold source files, classifies one throwaway object graph, and reads an
optional redacted evidence file. Does not open a LastDB home. Does not delete
from a source home. Does not run a production cutover.
"""

import json
import re
import sys
from datetime import datetime
from pathlib import Path

EVIDENCE_SCHEMA = "lastdb-schema-root-data-attribution-proof.v1"
UTC_FMT = "%Y-%m-%dT%H:%M:%SZ"
STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"')
BLOCK_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
LINE_COMMENT_RE = re.compile(r"//.*?$", re.M)
ENUM_RE = re.compile(r"enum\s+AttributionClass\s*\{([^}]*)\}", re.S)
VARIANT_RE = re.compile(r"\b([A-Z][A-Za-z0-9]*)\b")
FN_RE = re.compile(r"^[ \t]*(?:pub(?:\([^)]*\))? )?(?:async )?fn ", re.M)
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
    "fold_db/crates/core/src/db_operations/attribution_ledger.rs": "attribution-ledger",
    "lastdb_node/src/attribution_epoch.rs": "attribution-epoch",
    "fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs": "write-path",
    "fold_db/crates/core/src/schema/core/tests.rs": "schema-root-test",
}
REQUIRED_VARIANTS = (
    "SchemaAttributed",
    "RetentionAttributed",
    "SystemAttributed",
    "DerivedAttributed",
    "UnattributedResidue",
    "Unknown",
)
ROOT_VARIANTS = (
    "SchemaAttributed",
    "RetentionAttributed",
    "SystemAttributed",
    "DerivedAttributed",
)


def strip_strings(text):
    return STRING_RE.sub('""', text)


def code_text(text):
    stripped = strip_strings(text)
    stripped = BLOCK_COMMENT_RE.sub("", stripped)
    return LINE_COMMENT_RE.sub("", stripped)


def require_code(text, needle, label, failures):
    if needle not in code_text(text):
        failures.append(label)


def require_raw(text, needle, label, failures):
    if needle not in text:
        failures.append(label)


def require_prose(text, needle, label, failures):
    prose = re.sub(r"(?m)^[ \t]*//[!/]? ?", "", text)
    prose = re.sub(r"\s+", " ", prose)
    if needle not in prose:
        failures.append(label)


def kebab(name):
    chars = []
    for index, char in enumerate(name):
        if char.isupper() and index:
            chars.append("-")
        chars.append(char.lower())
    return "".join(chars)


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


def enum_variants(text):
    match = ENUM_RE.search(code_text(text))
    if not match:
        return []
    return VARIANT_RE.findall(match.group(1))


FN_NAME_RE = re.compile(r"\bfn\s+([A-Za-z_][A-Za-z0-9_]*)")


def function_name(span):
    match = FN_NAME_RE.search(span)
    return match.group(1) if match else None


def function_spans(text):
    lines = code_text(text).splitlines()
    starts = [index for index, line in enumerate(lines) if FN_RE.match(line)]
    spans = []
    for position, start in enumerate(starts):
        end = starts[position + 1] if position + 1 < len(starts) else len(lines)
        spans.append("\n".join(lines[start:end]))
    return spans


def source_failures(texts):
    failures = []
    ledger = texts["fold_db/crates/core/src/db_operations/attribution_ledger.rs"]
    epoch = texts["lastdb_node/src/attribution_epoch.rs"]
    write = texts["fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs"]
    schema_tests = texts["fold_db/crates/core/src/schema/core/tests.rs"]

    ledger_code = code_text(ledger)
    enum_at = ledger_code.find("enum AttributionClass")
    rename_at = ledger_code.rfind("rename_all", 0, enum_at if enum_at >= 0 else 0)
    if enum_at < 0 or rename_at < 0:
        failures.append("The attribution class enum is absent.")
    variants = enum_variants(ledger)
    for name in REQUIRED_VARIANTS:
        if name not in variants:
            failures.append("The attribution class %s is absent." % name)
    for name in ROOT_VARIANTS:
        require_code(
            ledger,
            "Self::%s" % name,
            "The root class %s does not require a root." % name,
            failures,
        )
    require_code(
        ledger,
        "AttributionClass::UnattributedResidue",
        "Residue rows can claim a root path.",
        failures,
    )
    require_code(
        ledger,
        "AttributionClass::Unknown",
        "Unknown rows can claim a root path.",
        failures,
    )
    require_code(
        ledger,
        "self.root_count == 0",
        "The ledger does not reject a root count on residue or unknown.",
        failures,
    )
    require_code(
        ledger,
        "self.path_set_digest.is_some()",
        "The ledger does not reject a path digest on residue or unknown.",
        failures,
    )
    require_raw(
        ledger,
        "The ledger never puts a schema list in an atom.",
        "The ledger no longer keeps schema lists out of atoms.",
        failures,
    )

    require_code(
        epoch,
        "fn complete(",
        "The attribution epoch has no completion gate.",
        failures,
    )
    require_code(
        epoch,
        "self.walk_complete",
        "Completion does not require a finished object walk.",
        failures,
    )
    require_code(
        epoch,
        "self.copy_snapshot_id.is_none()",
        "Completion does not require an exact copy snapshot.",
        failures,
    )
    require_code(
        epoch,
        "self.unknown_scopes.is_empty()",
        "An unknown scope can complete the epoch.",
        failures,
    )
    require_code(
        epoch,
        "fn has_complete_attribution_proof(",
        "The epoch has no complete-proof predicate.",
        failures,
    )
    require_prose(
        epoch,
        "It never authorizes a delete.",
        "The epoch proof can authorize a delete.",
        failures,
    )

    # The ordering rule -- a pending scope is opened before its event is
    # appended -- is a property of the CALL PATH, not of one function body. Two
    # upstream pipelines share one attribution tail, so the append lives in a
    # helper and each caller begins first. A span-local reading calls that
    # correct shape a violation: it went red on every last-stack gate run on
    # 2026-09-26 for fold's `consolidate attribution write duplication`, which
    # moved the append into `record_attribution_scopes` and left both
    # `begin_pending_scopes` calls in the callers.
    # papercut-north-star-attribution-ordering-rule-is-span-local-20260926
    #
    # So: follow one hop. A function that appends without its own begin is
    # compliant when it HAS callers in this file and EVERY caller begins before
    # calling it. No caller is a failure too — an append nothing reaches after a
    # begin has no proved ordering.
    ordering_failure = "A write appends an attribution event before its pending scope."
    spans = list(function_spans(write))
    event_functions = 0
    append_helpers = []
    for body in spans:
        append_at = body.find("append_events_and_clear_pending_scopes")
        if append_at < 0:
            continue
        event_functions += 1
        begin_at = body.find("begin_pending_scopes")
        if 0 <= begin_at < append_at:
            continue
        name = function_name(body)
        if name is None:
            failures.append(ordering_failure)
            continue
        append_helpers.append(name)
    for name in append_helpers:
        call = "%s(" % name
        callers = [
            body for body in spans if function_name(body) != name and call in body
        ]
        if not callers:
            failures.append(ordering_failure)
            continue
        for body in callers:
            call_at = body.find(call)
            begin_at = body.find("begin_pending_scopes")
            if not 0 <= begin_at < call_at:
                failures.append(ordering_failure)
                break
    if event_functions == 0:
        failures.append("The write path does not append an attribution source event.")
    require_code(
        write,
        "fn attribution_source_events_enabled(",
        "The write path has no attribution source-event gate.",
        failures,
    )
    require_raw(
        write,
        "LASTDB_ATTRIBUTION_SOURCE_EVENTS",
        "The write path lost the attribution source-event flag.",
        failures,
    )
    require_code(
        schema_tests,
        "fn schema_root_attribution_persists_one_molecule_proof_per_declared_field(",
        "The schema-root molecule proof test is absent.",
        failures,
    )
    return failures


def classify_graph(variants):
    names = {name: kebab(name) for name in variants}
    root = names["SchemaAttributed"]
    retention = names["RetentionAttributed"]
    system = names["SystemAttributed"]
    residue = names["UnattributedResidue"]
    unknown = names["Unknown"]
    rooted = {root, retention, system, names["DerivedAttributed"]}
    objects = [
        {"id": "molecule-a", "class": root, "roots": ["schema-a"]},
        {"id": "molecule-b", "class": root, "roots": ["schema-b"]},
        {"id": "shared-atom", "class": root, "roots": ["schema-a", "schema-b"]},
        {"id": "blob-a", "class": root, "roots": ["schema-a"]},
        {"id": "history-atom", "class": retention, "roots": ["history-policy"]},
        {"id": "system-catalog", "class": system, "roots": ["system-catalog"]},
        {"id": "injected-orphan", "class": residue, "roots": []},
    ]
    return objects, rooted, residue, unknown


def object_failures(objects, rooted, residue, unknown):
    failures = []
    for obj in objects:
        roots = obj["roots"]
        if obj["class"] in rooted and not roots:
            failures.append("The object %s has a root class and no root." % obj["id"])
        if obj["class"] in (residue, unknown) and roots:
            failures.append("The object %s claims a root path." % obj["id"])
    return failures


def scrub_copy(objects, residue, unknown):
    if any(obj["class"] == unknown for obj in objects):
        return list(objects), []
    deleted = [obj for obj in objects if obj["class"] == residue]
    kept = [obj for obj in objects if obj["class"] != residue]
    return kept, deleted


def exercise_failures(variants):
    failures = []
    for name in REQUIRED_VARIANTS:
        if name not in variants:
            failures.append("The offline exercise lacks class %s." % name)
            return failures
    objects, rooted, residue, unknown = classify_graph(variants)
    failures.extend(object_failures(objects, rooted, residue, unknown))
    if failures:
        return failures

    kept, deleted = scrub_copy(objects, residue, unknown)
    deleted_ids = {obj["id"] for obj in deleted}
    kept_ids = {obj["id"] for obj in kept}
    if deleted_ids != {"injected-orphan"}:
        failures.append("The copy did not remove only the injected residue object.")
    rooted_ids = {
        "molecule-a",
        "molecule-b",
        "shared-atom",
        "blob-a",
        "history-atom",
        "system-catalog",
    }
    if not rooted_ids.issubset(kept_ids):
        failures.append("The copy removed rooted data.")
    shared = next(obj for obj in kept if obj["id"] == "shared-atom")
    if shared["roots"] != ["schema-a", "schema-b"]:
        failures.append("The shared atom lost a schema path.")
    residue_left = sum(1 for obj in kept if obj["class"] == residue)
    unknown_left = sum(1 for obj in kept if obj["class"] == unknown)
    if residue_left != 0 or unknown_left != 0:
        failures.append("The restore still has residue or an unknown user object.")

    blocked_objects = objects + [
        {"id": "unreadable-atom", "class": unknown, "roots": []}
    ]
    blocked_kept, blocked_deleted = scrub_copy(blocked_objects, residue, unknown)
    if blocked_deleted or len(blocked_kept) != len(blocked_objects):
        failures.append("An unknown object did not block copy scrub.")
    return failures


def exercise_summary():
    return "\n".join(
        [
            "The copy kept rooted data.",
            "The copy removed only the injected residue object.",
            "The restore has zero unattributed-residue user objects.",
            "The restore has zero unknown user objects.",
            "An unknown object blocks copy scrub.",
        ]
    )


def require_bool(section, key, expected, failures):
    value = section.get(key)
    if not isinstance(value, bool):
        failures.append("The evidence field %s is not a boolean." % key)
        return
    if value is not expected:
        failures.append("The evidence field %s is not %s." % (key, str(expected).lower()))


def require_count(section, key, minimum, exact, failures):
    value = section.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        failures.append("The evidence field %s is not a measured integer." % key)
        return
    if exact is not None and value != exact:
        failures.append("The evidence field %s is not %s." % (key, exact))
    elif minimum is not None and value < minimum:
        failures.append("The evidence field %s is below %s." % (key, minimum))


def require_time(section, key, failures):
    value = section.get(key)
    if not isinstance(value, str):
        failures.append("The evidence field %s is not a UTC timestamp." % key)
        return
    try:
        datetime.strptime(value, UTC_FMT)
    except ValueError:
        failures.append("The evidence field %s is not a UTC timestamp." % key)


def evidence_failures(path):
    raw = path.read_text(encoding="utf-8", errors="replace")
    for marker in PRIMARY_MARKERS:
        if marker in raw:
            return ["The evidence names a LastDB home or a secret."]
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return ["The evidence file is not JSON."]
    if not isinstance(data, dict):
        return ["The evidence file is not a JSON object."]
    failures = []
    if data.get("schema") != EVIDENCE_SCHEMA:
        failures.append("The evidence schema is not %s." % EVIDENCE_SCHEMA)
    surface = data.get("surface")
    copy = data.get("copy")
    restore = data.get("restore")
    writes = data.get("writes")
    for name, section in (
        ("surface", surface),
        ("copy", copy),
        ("restore", restore),
        ("writes", writes),
    ):
        if not isinstance(section, dict):
            failures.append("The evidence section %s is absent." % name)
    if failures:
        return failures
    if surface.get("kind") != "isolated-copy":
        failures.append("The evidence surface is not an isolated copy.")
    require_bool(surface, "primary_opened", False, failures)
    require_bool(surface, "primary_mutated", False, failures)
    require_bool(surface, "source_delete", False, failures)
    require_bool(surface, "prod_cutover", False, failures)
    require_time(surface, "captured_at", failures)
    require_bool(copy, "source_digest_unchanged", True, failures)
    require_bool(copy, "injected_object_deleted", True, failures)
    require_bool(copy, "rooted_objects_preserved", True, failures)
    require_count(copy, "second_scrub_extra_deletes", None, 0, failures)
    require_count(restore, "unattributed_residue_user_objects", None, 0, failures)
    require_count(restore, "unknown_user_objects", None, 0, failures)
    require_count(restore, "schema_attributed_objects", 2, None, failures)
    require_count(restore, "retention_attributed_objects", 1, None, failures)
    require_count(restore, "system_attributed_objects", 1, None, failures)
    require_count(restore, "shared_atom_schema_paths", 2, None, failures)
    require_count(writes, "concurrent_write_source_events", None, 1, failures)
    require_count(writes, "concurrent_write_attribution_paths", None, 1, failures)
    require_bool(writes, "later_write_source_event_before_response", True, failures)
    require_bool(writes, "later_write_inline_size_before_response", True, failures)
    return failures


def measured_summary(path):
    data = json.loads(path.read_text(encoding="utf-8"))
    restore = data["restore"]
    copy = data["copy"]
    writes = data["writes"]
    return "\n".join(
        [
            "Isolated copy kept the source digest.",
            "Schema-attributed objects: %s." % restore["schema_attributed_objects"],
            "Retention-attributed objects: %s." % restore["retention_attributed_objects"],
            "System-attributed objects: %s." % restore["system_attributed_objects"],
            "Shared atom schema paths: %s." % restore["shared_atom_schema_paths"],
            "Unattributed-residue user objects: %s."
            % restore["unattributed_residue_user_objects"],
            "Unknown user objects: %s." % restore["unknown_user_objects"],
            "Second scrub extra deletes: %s." % copy["second_scrub_extra_deletes"],
            "Concurrent write source events: %s." % writes["concurrent_write_source_events"],
            "Concurrent write attribution paths: %s."
            % writes["concurrent_write_attribution_paths"],
        ]
    )


def main():
    source_dir = Path(sys.argv[1])
    evidence_arg = sys.argv[2] if len(sys.argv) > 2 else ""
    texts, missing = read_source(source_dir)
    failures = []
    for rel in missing:
        failures.append("The Fold %s source is absent." % SOURCE_FILES[rel])
    if not missing:
        failures.extend(source_failures(texts))
    ledger_rel = "fold_db/crates/core/src/db_operations/attribution_ledger.rs"
    variants = enum_variants(texts[ledger_rel]) if ledger_rel in texts else []
    exercise = [] if failures else exercise_failures(variants)
    lines = [
        "Source contract: FAIL" if failures else "Source contract: PASS",
        "Offline exercise: FAIL" if failures or exercise else "Offline exercise: PASS",
        "The harness did not open a LastDB home.",
        "The harness did not reclaim residue on a shared node.",
        "The harness did not delete from a source home.",
        "The harness did not run a production cutover.",
    ]
    if failures:
        lines.append("")
        lines.append("Source failures:")
        lines.extend("- %s" % item for item in failures)
    elif exercise:
        lines.append("")
        lines.append("Exercise failures:")
        lines.extend("- %s" % item for item in exercise)
    else:
        lines.append("")
        lines.append(exercise_summary())

    if not evidence_arg:
        lines.insert(2, "Operational evidence: ABSENT")
        lines.append("")
        lines.append("Operational evidence is absent.")
        lines.append(
            "Set SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE to redacted JSON with schema %s."
            % EVIDENCE_SCHEMA
        )
        lines.append("The file must record an isolated copy.")
        lines.append("The harness does not read a LastDB home to build that file.")
        print("\n".join(lines))
        return 1

    evidence_path = Path(evidence_arg)
    op_failures = evidence_failures(evidence_path)
    if op_failures:
        lines.insert(2, "Operational evidence: FAIL")
        lines.append("")
        lines.append("Evidence failures:")
        lines.extend("- %s" % item for item in op_failures)
        print("\n".join(lines))
        return 1

    lines.insert(2, "Operational evidence: PASS")
    lines.append("")
    lines.append(measured_summary(evidence_path))
    print("\n".join(lines))
    return 0 if not failures and not exercise else 1


if __name__ == "__main__":
    sys.exit(main())
