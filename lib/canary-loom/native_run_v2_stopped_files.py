"""Derive current file reads from original expected values and bind orphan diagnostics."""
import hashlib
import json

from native_upgrade_common import require
from native_run_v2_inputs import reference, uint
from native_run_v2_dev_session import ended


def current(parent, summary):
    original = reference(parent["parent"]["plan"])
    recorded = reference(parent["intent"])["original_metadata"]["final_expected"]
    values = reference(recorded, 1048576)
    field_map = original["field_map"]
    encoded = json.dumps(values, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    expected = reference(parent["reads"]["restored-second"])["records_sha256"]
    require(hashlib.sha256(encoded).hexdigest() == expected and set(field_map) == {"id", "note"}
            and len(set(field_map.values())) == 2 and len(values) == 16
            and sum(value is None for value in values.values()) == 2,
            "The original final values or field identity differ")
    for key, fields in values.items():
        require(fields is None or isinstance(fields, dict) and set(fields) == set(field_map.values())
                and fields[field_map["id"]] == key and isinstance(fields[field_map["note"]], str),
                "The original current record has an unknown field or key")
    files = summary["full_CAS_file_bytes"]
    require(len(files) == 2 and len({item["key"] for item in files}) == 2,
            "The original two record files are incomplete")
    # A file is current while the record that holds it exists.
    used = [item for item in files if values.get(item["key"]) is not None]
    require(used, "The original current file set must not be empty")
    return used, {"ref": recorded}


def diagnostic(proof, original, summary, required, expected_sha):
    value = reference(proof["diagnostic"])
    intent = reference(value["intent"])
    require(value.get("status") == "diagnostic_only" and value.get("diagnostic_only") is True
            and intent.get("schema") == "lastdb.dev5-file-diagnostic-plan.v1"
            and intent.get("diagnostic_only") is True and intent.get("source") == proof["source"]
            and intent.get("programs") == proof["programs"] and intent.get("account") == proof["account"]
            and intent.get("home") == proof["restore"]["destination"]
            and intent.get("files") == summary["full_CAS_file_bytes"]
            and intent.get("expected_records_sha256") == expected_sha
            and intent["prior"]["intent.json"] == proof["original_attempt"]["intent"]
            and intent["prior"]["result.json"] == proof["original_attempt"]["result"]
            and uint(value["finished_at"], True) >= uint(intent["started_at"], True) >= original["started_at"],
            "The actual orphan diagnostic does not follow the original stopped attempt")
    stop_ref = value["strict_stop"]
    owner, stop, read = [reference(ref) for ref in (stop_ref["owner"], stop_ref["stop"], value["record_read"])]
    identity = {name: uint(owner[name], True) for name in ("pid", "start_ts")}
    require(owner.get("source") == proof["source"] and owner.get("programs") == proof["programs"]
            and owner.get("home") == intent["home"] and owner.get("account") == proof["account"]
            and owner.get("operation_sha256") == value["intent"]["sha256"] and stop.get("owner") == owner
            and ended(identity, stop) and read.get("owner") == owner and read.get("records_sha256") == expected_sha
            and read.get("exact_values") is True and read.get("diagnostic_only") is True
            and (read.get("existing_records"), read.get("absent_records"), read.get("file_reads_in_this_record_check")) == (14, 2, 0),
            "The diagnostic lacks its actual record read and clean stopped owner")
    results = [reference(ref) for ref in value["files"]]
    require(len(results) == len(summary["full_CAS_file_bytes"]) == 2,
            "The diagnostic must identify both original file outcomes")
    for index, (item, result) in enumerate(zip(summary["full_CAS_file_bytes"], results)):
        require(type(result.get("index")) is int and result["index"] == index
                and result.get("key") == item["key"] and result.get("expected_bytes") == item["bytes"]
                and result.get("expected_sha256") == item["sha256"] and result.get("diagnostic_only") is True,
                "The diagnostic file outcome belongs to another original record")
        if item in required:
            require(result.get("verified") is True, "A current file did not pass its complete diagnostic hash read")
        else:
            http = reference(result["http_response"])
            require(result.get("verified") is False and result.get("failure_class") == "RuntimeError"
                    and result.get("failure_code") == "socket_http_status" and http.get("http_status") == 404
                    and http.get("complete_response") is True and http.get("truncated") is False,
                    "Only the file of an absent record may lack a postboot read")
    return value
