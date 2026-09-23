#!/usr/bin/env python3
"""Offline contract check for LastGit pack blobs on the B2 file plane.

Reads LastGit source and an optional measured evidence file.
Does not open a LastDB home and does not start a B2 cutover.
A boolean checklist is not evidence. PASS needs the measured backfill.
"""

import re
import sys
from pathlib import Path

SCHEMA = "lastgit-pack-blobs-b2-proof.v1"
SHA_RE = re.compile(r"^ok ([0-9a-f]{64})$")
PRIMARY_MARKERS = ("/.lastdb", "/.folddb", "~/.lastdb", "~/.folddb")

REQUIRED = (
    "schema",
    "primary_home_opened",
    "primary_mutated",
    "live_cutover",
    "reachable_pack_blobs",
    "pointerless_reachable",
    "backfill_first_failed",
    "backfill_second_uploaded",
    "backfill_second_failed",
    "backfill_second_skipped",
    "backfill_second_verify_pointers",
    "oldest_sha256",
    "largest_sha256",
    "newest_sha256",
    "round_trip_source",
    "new_push_count",
    "new_push_pointerless",
    "disabled_plane_visible",
    "silent_offsite_claim",
    "pack_bytes_in_atoms",
    "db_sync_plane",
    "pack_file_plane",
)


def strip_comments(text):
    text = re.sub(r"/\*.*?\*/", "", text, flags=re.S)
    out = []
    for line in text.split("\n"):
        out.append(line[:line_comment_index(line)] if line_comment_index(line) >= 0 else line)
    return "\n".join(out)


def line_comment_index(line):
    quote = None
    i = 0
    while i < len(line) - 1:
        char = line[i]
        if quote:
            if char == "\\":
                i += 2
                continue
            if char == quote:
                quote = None
            i += 1
            continue
        if char in ("'", '"', "`"):
            quote = char
            i += 1
            continue
        if char == "/" and line[i + 1] == "/":
            return i
        i += 1
    return -1


def method_body(text, signature):
    start = text.find(signature)
    if start < 0:
        return None
    line_start = text.rfind("\n", 0, start) + 1
    indent = len(text[line_start:start]) - len(text[line_start:start].lstrip(" "))
    rest = text[start + len(signature):]
    acc = text[start:start + len(signature)]
    for line in rest.split("\n"):
        stripped = line.lstrip(" ")
        pad = len(line) - len(stripped)
        if pad == indent and stripped.startswith(("/**", "async ", "private ", "public ", "static ", "constructor")):
            break
        acc += "\n" + line
    return acc


def brace_block(text, signature):
    start = text.find(signature)
    if start < 0:
        return None
    brace = text.find("{", start)
    if brace < 0:
        return None
    depth = 0
    i = brace
    while i < len(text):
        char = text[i]
        if char in ("'", '"', "`"):
            quote = char
            i += 1
            while i < len(text) and text[i] != quote:
                if text[i] == "\\":
                    i += 2
                    continue
                i += 1
            i += 1
            continue
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
            if depth == 0:
                return text[start:i + 1]
        i += 1
    return None


def require(body, needle, label, failures):
    if body is None or needle not in body:
        failures.append(label)


def require_order(body, first, second, label, failures):
    if body is None:
        failures.append(label)
        return
    left = body.find(first)
    right = body.find(second)
    if left < 0 or right < 0 or left >= right:
        failures.append(label)


def require_absent(body, needle, label, failures):
    if body is None:
        return
    if re.search(needle, body, flags=re.I):
        failures.append(label)


def source_failures(pointer, client, cli, doctor):
    failures = []
    pointer_lines = [
        line.strip()
        for line in pointer.splitlines()
        if line.strip() == 'export const PACK_BLOB_POINTER_FIELD = "pack_file";'
    ]
    if not pointer_lines:
        failures.append("The pack pointer field is not pack_file.")

    upload = method_body(client, "private async putPackFileBlob(")
    require(upload, 'this.req("POST", "/api/db/file-blob"', "The pack upload does not use the file-blob plane.", failures)
    require(upload, "key: { hash: contentHash, range: null }", "The pack upload key is not a HashRange key.", failures)
    require(upload, 'data: ""', "The pack upload does not keep the atom body empty.", failures)
    require(upload, 'bytes_b64: plaintext.toString("base64")', "The pack upload does not send the pack bytes.", failures)
    require(upload, "cache_local_plaintext: false", "The pack upload caches local plaintext.", failures)
    require(upload, 'mapper?.pack_file ?? mapper?.file ?? "pack_file"', "The pack upload field is not pack_file.", failures)
    require_absent(upload, r"/backup/", "The pack upload uses the backup prefix.", failures)
    require_absent(upload, r"cloudflare", "The pack upload uses the database backup plane.", failures)
    require_absent(upload, r"(^|[^A-Za-z0-9])r2([^A-Za-z0-9]|$)", "The pack upload uses the R2 database plane.", failures)

    put = method_body(client, "async putPackBlob(contentHash: string, data: Buffer)")
    require(put, "this.writePackCas(contentHash, data)", "A new push does not store local pack CAS bytes.", failures)
    require_order(
        put,
        "this.putPackFileBlob(contentHash, data)",
        "file_blob_pointer_not_persisted:",
        "A new push trusts a pointer before the read-back.",
        failures,
    )
    require_order(
        put,
        'LASTGIT_PACK_FILE_BLOB_STRICT === "1"',
        "pack bytes are CAS-only",
        "A disabled file plane can stay silent.",
        failures,
    )
    require(put, 'data: ""', "A new push writes pack bytes into the atom.", failures)
    require_absent(put, "bytes_b64", "A new push embeds pack bytes in the metadata row.", failures)

    recover = method_body(client, "private static packBytesFromFileBlobPlaintext(")
    require_order(
        recover,
        "if (sha256(plaintext) === contentHash) return plaintext;",
        "if (unframed && sha256(unframed) === contentHash) return unframed;",
        "The fetch does not check the pack SHA-256.",
        failures,
    )
    require(recover, "return null;", "A bad fetch can return the wrong bytes.", failures)

    backfill = method_body(client, "async backfillPackFileBlobs(")
    require(
        backfill,
        'const packs = await this.listPacks(repo!, { thin: true, states: ["available"] });',
        "The backfill does not read thin available pack rows.",
        failures,
    )
    require_order(
        backfill,
        "if (!verifyPointers) {",
        "if (status === \"resolved\") {",
        "The backfill does not separate an unverified pointer from a resolved one.",
        failures,
    )
    require(backfill, "skipped += 1", "A second backfill has no skip path.", failures)
    require(backfill, "file_blob_pointer_not_persisted:", "The backfill can report success when the pointer did not persist.", failures)
    if (backfill is None or "listPacks" not in backfill) and "backfillPackCover(" in client:
        failures.append("Cover backfill is not the pack-blob migration.")

    assignment = 'const packBlobDurabilityAudit = args.flags.has("pack-blob-durability-audit");'
    if assignment not in cli:
        failures.append("The durability census is not an explicit flag.")
    audit = brace_block(cli, "if (packBlobDurabilityAudit)")
    require(audit, "auditPackBlobDurabilityForDoctor", "Default doctor runs the pack census.", failures)

    require(doctor, "per-pack plane census not run", "Default doctor claims a per-pack census.", failures)
    require(doctor, "verify-pointers` for a durability verdict", "Doctor can call a pointer count a durability verdict.", failures)
    require(doctor, "DEREFERENCES", "Doctor can omit the dereference result.", failures)
    return failures


def parse_measured(text):
    fields = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            return None, "Evidence line %d is not a measured field." % lineno
        key, value = line.split(":", 1)
        key = key.strip()
        value = value.strip()
        if not re.fullmatch(r"[a-z0-9_]+", key):
            return None, "Evidence line %d has a bad field name." % lineno
        if key in fields:
            return None, "Evidence field %s is duplicated." % key
        for marker in PRIMARY_MARKERS:
            if marker in value:
                return None, "Evidence names a primary LastDB home."
        fields[key] = value
    return fields, None


def need_int(fields, key, failures):
    raw = fields.get(key, "")
    if not re.fullmatch(r"[0-9]+", raw):
        failures.append("Evidence field %s is not a count." % key)
        return None
    return int(raw)


def evidence_failures(text):
    failures = []
    if not text.strip():
        return ["The terminal backfill has no measured evidence."]
    fields, error = parse_measured(text)
    if error:
        return [error]
    missing = [key for key in REQUIRED if key not in fields]
    if missing:
        return ["The evidence omits %s." % ", ".join(missing)]
    if fields["schema"] != SCHEMA:
        failures.append("The evidence schema is not the pack-blob proof.")
    if fields["primary_home_opened"] != "false":
        failures.append("The evidence opened a primary LastDB home.")
    if fields["primary_mutated"] != "false":
        failures.append("The evidence mutated a primary LastDB home.")
    if fields["live_cutover"] != "false":
        failures.append("The evidence records a live B2 cutover.")
    reachable = need_int(fields, "reachable_pack_blobs", failures)
    pointerless = need_int(fields, "pointerless_reachable", failures)
    first_failed = need_int(fields, "backfill_first_failed", failures)
    second_uploaded = need_int(fields, "backfill_second_uploaded", failures)
    second_failed = need_int(fields, "backfill_second_failed", failures)
    second_skipped = need_int(fields, "backfill_second_skipped", failures)
    new_push = need_int(fields, "new_push_count", failures)
    new_pointerless = need_int(fields, "new_push_pointerless", failures)
    atoms = need_int(fields, "pack_bytes_in_atoms", failures)
    if reachable is not None and reachable < 1:
        failures.append("The evidence has no reachable pack blob.")
    if pointerless not in (None, 0):
        failures.append("The evidence still has a pointerless reachable pack blob.")
    if first_failed not in (None, 0):
        failures.append("The first backfill has a failure.")
    if second_uploaded not in (None, 0):
        failures.append("The second backfill uploaded again.")
    if second_failed not in (None, 0):
        failures.append("The second backfill has a failure.")
    if (
        reachable is not None
        and second_skipped is not None
        and second_skipped != reachable
    ):
        failures.append("The second backfill did not skip every reachable pack.")
    if fields["backfill_second_verify_pointers"] != "true":
        failures.append("The second backfill did not verify pointers.")
    hashes = []
    for key in ("oldest_sha256", "largest_sha256", "newest_sha256"):
        match = SHA_RE.fullmatch(fields[key])
        if not match:
            failures.append("The evidence lacks a SHA-256 result for %s." % key)
        else:
            hashes.append(match.group(1))
    if reachable is not None and reachable >= 3 and len(set(hashes)) < 3:
        failures.append("The oldest, largest, and newest samples are not distinct.")
    if fields["round_trip_source"] != "b2":
        failures.append("The round trip did not come from the B2 file plane.")
    if new_push is not None and new_push < 1:
        failures.append("The evidence has no new push.")
    if new_pointerless not in (None, 0):
        failures.append("A new push has no B2 pointer.")
    if fields["disabled_plane_visible"] != "true":
        failures.append("A disabled file plane is not visible.")
    if fields["silent_offsite_claim"] != "false":
        failures.append("The evidence allows a silent offsite claim.")
    if atoms not in (None, 0):
        failures.append("Pack bytes are in atoms.")
    if fields["db_sync_plane"] != "r2":
        failures.append("Database sync does not stay on R2.")
    if fields["pack_file_plane"] != "b2":
        failures.append("Pack files do not stay on B2.")
    return failures


def main():
    if len(sys.argv) != 7:
        print("The checker needs four source paths, an evidence path, and a mode.")
        return 1
    pointer_path, client_path, cli_path, doctor_path, evidence_path, mode = sys.argv[1:]
    if mode not in ("offline", "live"):
        print("The proof mode is invalid.")
        return 1
    try:
        pointer = strip_comments(Path(pointer_path).read_text())
        client = strip_comments(Path(client_path).read_text())
        cli = strip_comments(Path(cli_path).read_text())
        doctor = strip_comments(Path(doctor_path).read_text())
    except OSError as err:
        print("The LastGit source read failed: %s" % err)
        return 1
    source = source_failures(pointer, client, cli, doctor)
    if evidence_path:
        try:
            evidence_text = Path(evidence_path).read_text()
        except OSError as err:
            print("The evidence file read failed: %s" % err)
            return 1
    else:
        evidence_text = ""
    evidence = evidence_failures(evidence_text)
    lines = [
        "Source contract: %s" % ("broken" if source else "hold"),
        "Terminal evidence: %s" % ("absent" if not evidence_text.strip() else "present"),
        "Mode: %s" % mode,
        "The harness did not open a LastDB home.",
        "The harness did not start a B2 cutover.",
        "Pack bytes stay on the B2 file plane. Database sync stays on R2.",
        "Cover backfill is not this proof.",
    ]
    if source:
        lines.append("Source defects:")
        lines.extend("- %s" % item for item in source)
    if evidence:
        lines.append("Evidence defects:")
        lines.extend("- %s" % item for item in evidence)
    print("\n".join(lines))
    if source or evidence:
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
