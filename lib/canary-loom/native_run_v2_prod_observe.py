"""Read a covered primary point and two approved application keys without values in output."""

from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
from pathlib import Path

from native_upgrade_common import call, require, session, sha
from native_run_v2_inputs import digest
from native_run_v2_auto_policy import frontiers, head
from native_run_v2_recovery import wrapped
from native_v2_read import specification

PRIMARY = Path.home() / ".lastdb"
ACCOUNT = "bdad5eed9af93d2dcff449fce3ba32f8"
POST_KEY = "cloud-v2-automatic-20261027-f6cuwttf-1d4b205bb84a-proof-file-3"
POST_SCHEMA = "6a5702288f999a053f79294ee415c2b54392ad5e4b58f1d81c10e73207d478b6"


def specifications(original):
    binding = {"keyed_read": {"input_path": str(original), "input_sha256": sha(original)}}
    before = specification(binding)
    after = {"schema": "lastdb.native-keyed-read.v1", "application": "cloud-v2-automatic-proof",
             "schema_name": POST_SCHEMA, "fields": ["slug", "secret_value"],
             "keys": [{"hash": POST_KEY, "range": ""}]}
    return [before, after]


def query(spec):
    return {"schema_name": spec["schema_name"], "fields": spec["fields"],
            "filter": {"HashRangeKeys": [[k["hash"], k["range"]] for k in spec["keys"]]},
            "limit": len(spec["keys"])}


def record_digest(spec, response):
    keys = {(key["hash"], key["range"]) for key in spec["keys"]}
    require(response.get("ok") is True and response.get("unresolved_rows") == 0
            and response.get("tombstoned_rows") == 0 and response.get("has_more") is False
            and response.get("next_cursor") is None and isinstance(response.get("results"), list)
            and len(response["results"]) == len(keys), "The approved application read is incomplete")
    found = {}
    for row in response["results"]:
        key = (row["key"]["hash"], row["key"]["range"] or "")
        require(key in keys and key not in found and isinstance(row.get("fields"), dict)
                and set(row["fields"]) == set(spec["fields"]), "The approved application key or fields differ")
        found[key] = row["fields"]
    value = [[h, r, found[(h, r)]] for h, r in sorted(found)]
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()
    return {"schema_name": spec["schema_name"], "records": len(found),
            "values_sha256": hashlib.sha256(encoded).hexdigest()}


def records(sock, specs):
    result = call(sock, "/api/queries/batch", {"queries": [query(spec) for spec in specs]})
    rows = result.get("results")
    require(isinstance(rows, list) and len(rows) == len(specs), "The application batch count differs")
    proofs = []
    for spec, row in zip(specs, rows):
        require(row.get("status") == 200, "An approved application query failed")
        proofs.append(record_digest(spec, row["response"]))
    return proofs


def primary(programs, version):
    sock = PRIMARY / "data/folddb.sock"
    with ThreadPoolExecutor(max_workers=3) as pool:
        boot, status, native = list(pool.map(lambda item: call(sock, *item), (
            ("/api/system/boot-identity",), ("/api/sync/byte-backup-v2", {"action": "status"}),
            ("/api/db/native-status",))))
    identity = session(PRIMARY)
    require(boot.get("pid") == identity["pid"] and boot.get("process_start_ts") == identity["start_ts"]
            and boot.get("build") == version and (PRIMARY / "current").is_symlink(),
            "The observed primary session or program differs")
    directory = (PRIMARY / "current").resolve()
    require({name: sha(directory / name) for name in ("lastdb", "lastdbd")} == programs,
            "The primary program pair changed")
    automatic, journal = status.get("automatic_backup"), status.get("mutation_log")
    require(status.get("user_hash") == native.get("user_hash") == ACCOUNT
            and status.get("enabled") is True and status.get("automatic_backup_enabled") is True
            and isinstance(automatic, dict) and automatic.get("enabled") is True
            and automatic.get("paused") is None and automatic.get("attempts") == 0
            and automatic.get("retry_at") == 0 and automatic.get("pending_request_id") is None
            and status.get("phase") == "published" and status.get("running") is False
            and status.get("retained_source_bytes") == 0 and status.get("blocked_reason") is None,
            "The current primary does not have a complete automatic publication")
    require(isinstance(journal, dict) and journal.get("enabled") is True and journal.get("gap") is None
            and journal.get("snapshot_required") is False and journal.get("retained_bytes") == 0,
            "The current primary journal has an uncovered boundary")
    position = head(journal.get("head"))
    require(journal.get("acknowledged_through") == position["sequence"]
            and frontiers(automatic.get("last_backed_up_frontiers")) == position["frontiers"]
            and native["native_disk"].get("writer_failed") is False,
            "The current primary mutations do not all have a cloud acknowledgement")
    accepted = status.get("last_accepted_backup")
    require(isinstance(accepted, dict) and accepted.get("version") == 2
            and accepted["begin"]["job"]["commit_id"] == status["request_id"]
            == automatic["last_completed_request_id"]
            and accepted["begin"]["job"]["stream"]["scope"]["account_id"] == ACCOUNT,
            "The current accepted primary point differs")
    digest(accepted["commit_sha256"])
    return {"session": identity, "build": version, "programs": programs, "accepted": accepted,
            "journal_head": position, "kind": status["backup_kind"],
            "automatic_policy": {key: automatic[key] for key in
                ("revision", "log_interval_seconds", "snapshot_interval_seconds")}}


def snapshot_base(accepted):
    core = wrapped(PRIMARY / "data/disk-run/cloud-byte-source-v2/job.json")
    terminal = core.get("terminal", {}).get("status", {})
    base = terminal.get("backup")
    require(terminal.get("state") == "published" and core.get("released") is True
            and core.get("ready") is True and isinstance(base, dict)
            and base["begin"] == core.get("begin")
            and base["begin"]["job"]["stream"] == accepted["begin"]["job"]["stream"]
            and int(base["ordinal"]) <= int(accepted["ordinal"]),
            "The saved original snapshot does not belong to the selected primary stream")
    return core, base
