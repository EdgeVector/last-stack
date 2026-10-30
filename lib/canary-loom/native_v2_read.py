"""One approved keyed data read; retain only its canonical digest and count."""

import hashlib
import json
from pathlib import Path
import re

from native_upgrade_common import call, require
from native_v2_gate import private_json

# Tom, 2026-10-30, for the P2 protein-removal route only. The approval must
# quote this text exactly. Every other keyed read keeps the full guard.
BRAIN_FALLBACK_QUOTE = ("The upgrade check reads one converted Brain Preference record by key. "
                        "This lifts the brain notice for this one read only, and the guard changes "
                        "for the brain namespace only.")
BRAIN_APP = "fbrain"
PREFERENCE_FIELDS = {"slug", "title", "body", "status", "tags", "created_at", "updated_at"}
REFUSAL = "lastdb.upgrade-probe-declare-refusal.v1"


def brain_fallback(approval):
    """True only for Tom's P2 exception after PROD refused the probe schema."""
    fallback = approval.get("keyed_read_fallback")
    if fallback is None:
        return False
    from native_run_v2_routes import APPROVAL, P2
    require(approval.get("schema") == APPROVAL and approval.get("profile") == P2
            and isinstance(fallback, dict)
            and set(fallback) == {"namespace", "schema", "quote", "declare_refusal"}
            and fallback["namespace"] == BRAIN_APP and fallback["schema"] == "Preference"
            and fallback["quote"] == BRAIN_FALLBACK_QUOTE,
            "The brain keyed-read fallback needs the P2 route, a Preference schema, and Tom's exact text")
    refusal = fallback["declare_refusal"]
    require(isinstance(refusal, dict) and set(refusal) == {"path", "sha256"}
            and re.fullmatch(r"[0-9a-f]{64}", refusal["sha256"]) is not None
            and Path(refusal["path"]).is_absolute() and Path(refusal["path"]).resolve() == Path(refusal["path"]),
            "The brain keyed-read fallback needs the retained probe declaration refusal")
    require(refused(private_json(Path(refusal["path"]), 65536, refusal["sha256"])),
            "The probe declaration did not fail; the brain keyed-read fallback does not apply")
    return True


def refused(record):
    """The retained HTTP status and raw body of a refused probe declaration.

    A 5xx reply is content-free plain text, so the record keeps the raw body
    as a string; only a reply that parses to a declared identity is a success.
    """
    if not (isinstance(record, dict) and set(record) == {"schema", "http_status", "body"}
            and record["schema"] == REFUSAL and type(record["http_status"]) is int
            and 400 <= record["http_status"] <= 599 and isinstance(record["body"], str)):
        return False
    try:
        reply = json.loads(record["body"])
    except ValueError:
        return True
    reply = reply.get("data", reply) if isinstance(reply, dict) else reply
    return not (isinstance(reply, dict) and "canonical" in reply)


def specification(approval):
    binding = approval["keyed_read"]
    require(set(binding) == {"input_path", "input_sha256"}
            and re.fullmatch(r"[0-9a-f]{64}", binding["input_sha256"]) is not None,
            "The approved keyed-read input binding is incomplete")
    path = Path(binding["input_path"])
    require(path.is_absolute() and path.resolve() == path, "The keyed-read input path must be canonical")
    value = private_json(path, 16384, binding["input_sha256"])
    require(set(value) == {"schema", "application", "schema_name", "fields", "keys"}
            and value["schema"] == "lastdb.native-keyed-read.v1", "Invalid keyed-read input schema")
    brain = brain_fallback(approval)
    if brain:
        require(value["application"] == BRAIN_APP
                and re.fullmatch(r"[0-9a-f]{64}", value["schema_name"]) is not None
                and len(value["keys"]) == 1 and value["keys"][0].get("range") == ""
                and set(value["fields"]) <= PREFERENCE_FIELDS and "slug" in value["fields"],
                "The brain fallback reads one Preference record by its slug")
    for name in (value["application"], value["schema_name"]):
        tokens = ("kanban", "situation") if brain else ("brain", "kanban", "situation")
        require(isinstance(name, str) and 0 < len(name) <= 256
                and not any(token in name.casefold() for token in tokens),
                "The keyed read must name an approved application outside retired namespaces")
    fields, keys = value["fields"], value["keys"]
    require(isinstance(fields, list) and 1 <= len(fields) <= 16
            and all(isinstance(f, str) and 0 < len(f) <= 256 for f in fields)
            and len(set(fields)) == len(fields), "The keyed read needs at most 16 distinct named fields")
    require(isinstance(keys, list) and 1 <= len(keys) <= 16, "The keyed read needs 1 to 16 exact keys")
    for key in keys:
        require(isinstance(key, dict) and set(key) == {"hash", "range"}
                and all(isinstance(v, str) and len(v) <= 1024 for v in key.values())
                and bool(key["hash"]), "Invalid exact keyed-read coordinates")
    require(len({(k["hash"], k["range"]) for k in keys}) == len(keys), "The approved keyed read repeats a key")
    return value


def preference_schema(approval, name):
    """The installed identity is the converted fbrain Preference schema."""
    schema = call(Path(approval["primary_home"]) / "data/folddb.sock", "/api/schema/" + name).get("schema")
    require(isinstance(schema, dict) and schema.get("identity_hash") == name
            and schema.get("owner_app_id") == BRAIN_APP and schema.get("descriptive_name") == "Preference"
            and schema.get("schema_type") == "Hash" and schema.get("independent_fields") is True
            and (schema.get("key") or {}).get("hash_field") == "slug",
            "The brain fallback names another schema than the converted Preference schema")


def observe(approval):
    spec = specification(approval)
    if brain_fallback(approval):
        preference_schema(approval, spec["schema_name"])
    keys = {(k["hash"], k["range"]) for k in spec["keys"]}
    response = call(Path(approval["primary_home"]) / "data/folddb.sock", "/api/query", {
        "schema_name": spec["schema_name"], "fields": spec["fields"],
        "filter": {"HashRangeKeys": [[k["hash"], k["range"]] for k in spec["keys"]]},
        "limit": len(keys),
    })
    records = response.get("results")
    require(response.get("unresolved_rows") == 0 and response.get("tombstoned_rows") == 0
            and response.get("has_more") is False and response.get("next_cursor") is None
            and isinstance(records, list) and len(records) == len(keys),
            "The approved keyed-data read is empty or incomplete")
    found = {}
    for row in records:
        key = (row["key"]["hash"], row["key"]["range"] or "")
        require(key in keys and key not in found and isinstance(row["fields"], dict)
                and set(row["fields"]) == set(spec["fields"]), "The keyed-data response differs from its exact request")
        found[key] = row["fields"]
    canonical = json.dumps([[h, r, found[(h, r)]] for h, r in sorted(found)],
                           sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return {"input_sha256": approval["keyed_read"]["input_sha256"], "records": len(found),
            "values_sha256": hashlib.sha256(canonical).hexdigest()}


def verify(approval, expected):
    current = observe(approval)
    require(current == expected, "The approved keyed-data values differ from the pre-stop result")
    return current
