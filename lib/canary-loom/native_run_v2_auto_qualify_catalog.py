"""Load one accepted public type contract into an owned synthetic DEV home."""
import hashlib
import http.client
import json
import os

from native_run_v2_auto_qualify_io import read, reference, require, save

SCHEMA = "9fdab70cdd7275622d11a2c0a2bfc6e505b836f7b7e98282b8de7c8d8dd80e38"
FIELD_MAP = {"id": "file_content_sha256_hex", "note": "file_media_type", "file": "native_file_reference"}
ID_FIELD, NOTE_FIELD, FILE_FIELD = (FIELD_MAP[name] for name in ("id", "note", "file"))
CATALOG_RESULT_SHA256 = "4a4946fe91024cb8dcec2c72d38543d3905537c8fc7d54e45f3a46a630a3ea64"
CATALOG_BODY_SHA256 = "7bbdd173fdfed652450b013f0032301b529fbd45f8c3d041002ee449735d9277"


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()).hexdigest()


def binding(path, pinned=True):
    """A closed route binds its own catalog read by plan hash, not by this pin."""
    original = reference(path)
    require(not pinned or original["sha256"] == CATALOG_RESULT_SHA256, "original_public_catalog_read")
    result = read(path)
    require(result["http_status"] == 200 and result["complete"] is True and result["bounded"] is True
            and result["requests_attempted"] == 1 and result["credentials_sent"] is False
            and result["redirects_followed"] == 0, "completed_public_catalog_read")
    body = result["body"]
    require(reference(body["path"])["sha256"] == body["sha256"]
            and (not pinned or body["sha256"] == CATALOG_BODY_SHA256), "unchanged_public_catalog_reply")
    catalog = read(body["path"])
    require(isinstance(catalog.get("schemas"), list)
            and (len(catalog["schemas"]) == 49 if pinned else 0 < len(catalog["schemas"]) <= 4096),
            "original_bounded_catalog_definitions")
    matches = [item for item in catalog["schemas"] if item.get("name") == SCHEMA]
    require(len(matches) == 1 and matches[0]["system"] is False, "exact_existing_public_contract")
    definition = {key: value for key, value in matches[0].items() if key != "system"}
    require(definition["identity_hash"] == SCHEMA and definition["schema_type"] == "Hash"
            and definition["key"] == {"hash_field": ID_FIELD, "range_field": None}
            and not definition.get("field_mappers") and not definition.get("transform_fields")
            and not definition.get("ref_fields")
            and all(name in definition["fields"] for name in FIELD_MAP.values())
            and {name: definition["field_types"][name] for name in FIELD_MAP.values()}
                == {ID_FIELD: "String", NOTE_FIELD: "String", FILE_FIELD: "Any"},
            "existing_contract_key_fields_and_types")
    return {"identity": SCHEMA, "catalog_result": original, "catalog_body": body,
        "definition": definition, "definition_sha256": digest(definition),
        "public_type_metadata_only": True, "new_registration": False, "pinned_catalog": pinned}


def _raw(path, raw):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    return reference(path)


def _request(node, socket, method, route, output, body=None):
    connection = node.http_connection(socket)
    raw, status, failure, complete, maximum = b"", None, None, False, 65536
    try:
        connection.request(method, route, None if body is None else json.dumps(body, separators=(",", ":")).encode(),
            {"X-LastDB-Client": "cloud-backup-ci", "Content-Type": "application/json"})
        response = connection.getresponse()
        status = response.status
        maximum = 262144 if status == 200 else 65536
        raw = response.read(maximum + 1)
        complete = len(raw) <= maximum
    except http.client.IncompleteRead as error:
        raw, failure = error.partial[:maximum + 1], "IncompleteRead"
    except BaseException as error:
        failure = type(error).__name__
    finally:
        connection.close()
        response_ref = _raw(output.with_suffix(".json"), raw[:maximum])
        save(output.with_suffix(".receipt.json"), {"http_status": status, "body": response_ref,
            "observed_bytes": len(raw), "retained_bytes": min(len(raw), maximum),
            "truncated": len(raw) > maximum, "complete_response": complete, "failure_class": failure})
    require(status == 200 and failure is None and complete, "exact_catalog_http_response")
    return node.http_decode(raw), response_ref


def load(node, operation):
    expected = operation.plan["catalog"]
    require(expected == binding(expected["catalog_result"]["path"], expected.get("pinned_catalog", True)),
            "frozen_catalog_plan_binding")
    folder = operation.output / "existing-catalog-load"
    folder.mkdir(mode=0o700)
    loaded, load_ref = _request(node, node.home / "data/folddb-full.sock", "POST", "/api/schemas/load",
        folder / "load-response", {"schemas": [SCHEMA]})
    require(loaded.get("available_schemas_loaded") == loaded.get("schemas_loaded_to_db") == 1
            and loaded.get("failed_schemas") == [], "one_exact_existing_schema_loaded")
    cached, cached_ref = _request(node, node.socket, "GET", "/api/schema/" + SCHEMA,
                                  folder / "cached-schema-response")
    actual = cached.get("schema")
    require(isinstance(actual, dict) and actual.get("state") == "Available"
            and not actual.get("field_mappers") and not actual.get("transform_fields")
            and not actual.get("ref_fields")
            and all(actual.get(key) == value for key, value in expected["definition"].items()),
            "cached_schema_matches_original_public_definition")
    receipt = {"schema": "lastdb.qualification-existing-catalog-load.v1", "owner": node.owner,
        "identity": SCHEMA, "field_map": FIELD_MAP, "catalog": expected,
        "public_definition_sha256": expected["definition_sha256"],
        "load_response": load_ref, "cached_schema_response": cached_ref,
        "new_schema_registration": False, "public_type_metadata_only": True}
    return save(folder / "verified.json", receipt)
