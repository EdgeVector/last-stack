"""One approved keyed data read; retain only its canonical digest and count."""

import hashlib
import json
from pathlib import Path
import re

from native_upgrade_common import call, require
from native_v2_gate import private_json


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
    for name in (value["application"], value["schema_name"]):
        require(isinstance(name, str) and 0 < len(name) <= 256
                and not any(token in name.casefold() for token in ("brain", "kanban", "situation")),
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


def observe(approval):
    spec = specification(approval)
    keys = {(k["hash"], k["range"]) for k in spec["keys"]}
    response = call(Path(approval["primary_home"]) / "data/folddb.sock", "/api/query", {
        "schema_name": spec["schema_name"], "fields": spec["fields"],
        "filter": {"HashRangeKeys": [[k["hash"], k["range"]] for k in spec["keys"]]},
        "limit": len(keys),
    })
    records = response.get("results")
    require(response.get("has_more") is False and response.get("next_cursor") is None
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
