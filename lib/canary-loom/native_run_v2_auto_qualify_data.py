"""Predeclared synthetic values and complete file reads through normal product APIs."""
import copy
from concurrent.futures import ThreadPoolExecutor
import hashlib
import json
import os
import subprocess
import time

from native_run_v2_auto_qualify_io import hash_file, require, save
from native_run_v2_auto_qualify_catalog import FIELD_MAP, ID_FIELD, NOTE_FIELD, SCHEMA, load


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False).encode()


def file_spec(nonce, number):
    block = hashlib.shake_256((nonce + ":" + str(number)).encode()).digest(1024 * 1024)
    digest = hashlib.sha256()
    for _ in range(8):
        digest.update(block)
    return {"number": number, "bytes": 8388608, "sha256": digest.hexdigest()}


class Data:
    def __init__(self, operation):
        require(operation.plan["field_map"] == FIELD_MAP, "declared_app_field_map")
        self.operation, self.expected, self.files = operation, {}, []
        self.records = operation.plan["records"]

    def file(self, number, pair, key):
        """Write declared file `number` and put it as the file of record `key`."""
        specification = self.operation.plan["files"][number - 1]
        path = self.operation.output / ("file-" + str(number) + ".bin")
        block = hashlib.shake_256((self.operation.plan["nonce"] + ":" + str(number)).encode()).digest(1024 * 1024)
        descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        with os.fdopen(descriptor, "wb") as stream:
            for _ in range(8):
                stream.write(block)
            stream.flush()
            os.fsync(stream.fileno())
        require(path.stat().st_size == specification["bytes"] and hash_file(path) == specification["sha256"],
                "declared_file_bytes")
        reply = pair.command(self.operation.homes / "s",
                             ["db", "put-blob", "--schema", SCHEMA, "--hash", key, "--file", str(path)])
        marker = reply.get("file") if isinstance(reply, dict) and reply.get("ok") is True else None
        require(isinstance(marker, dict) and marker.get("size_bytes") == specification["bytes"]
                and marker.get("sha256") == specification["sha256"], "product_record_file_marker")
        self.files.append({"bytes": specification["bytes"], "sha256": specification["sha256"], "key": key})

    def mutations(self, node, values):
        changes = [{"type": "mutation", "schema": SCHEMA, "key_value": {"hash": key, "range": None},
            "fields_and_values": fields if fields is not None else {ID_FIELD: key},
            "mutation_type": "delete" if fields is None else ("update" if key in self.expected else "create"),
            "durability": "durable"} for key, fields in values.items()]
        result = node.call("/api/mutations/batch", {"mutations": changes})
        require(len(result["mutation_ids"]) == len(changes), "exact_mutation_batch_ack")
        self.expected.update(copy.deepcopy(values))

    def populate(self, node):
        self.operation.catalog_load = load(node, self.operation)
        values = {item["id"]: {ID_FIELD: item["id"], NOTE_FIELD: item["note"]} for item in self.records}
        save(self.operation.output / "initial-expected.json", values)
        self.mutations(node, values)
        self.file(1, self.operation.baseline, self.records[0]["id"])
        self.initial, self.initial_files = copy.deepcopy(self.expected), copy.deepcopy(self.files)

    def update(self, node):
        values = {item["id"]: {ID_FIELD: item["id"], NOTE_FIELD: item["final_note"]}
                  for item in self.records[:14]}
        values.update({item["id"]: None for item in self.records[14:]})
        save(self.operation.output / "final-expected.json", values)
        self.mutations(node, values)
        # A second record gets the second file; the first record keeps its file.
        self.file(2, self.operation.candidate, self.records[1]["id"])

    def reads(self, node, label, expected=None, files=None, accepted=None):
        expected = self.expected if expected is None else expected
        files = self.files if files is None else files
        node.health()
        owner = node.owner
        markers = {item["key"]: item for item in files}
        queries = [{"schema_name": SCHEMA, "fields": list(FIELD_MAP.values()),
            "filter": {"HashKey": key}, "limit": 2, "offset": 0} for key in expected]
        reply = node.call("/api/queries/batch", {"queries": queries})
        require(len(reply["results"]) == len(queries), "exact_read_batch_count")
        for (key, fields), item in zip(expected.items(), reply["results"]):
            result = item["response"]
            require(item["status"] == 200 and result["ok"] is True and not result.get("has_more", False),
                    "complete_keyed_read")
            if fields is None:
                require(result["returned_count"] == 0 and result["results"] == [], "declared_key_absent")
            else:
                require(result["returned_count"] == 1 and len(result["results"]) == 1
                        and result["results"][0]["key"] == {"hash": key, "range": None}
                        and result["results"][0]["fields"] == fields, "predeclared_exact_values")
                marker, file = (result["results"][0].get("metadata") or {}).get("file"), markers.get(key)
                require(marker is None if file is None else isinstance(marker, dict)
                        and (marker.get("size_bytes"), marker.get("sha256")) == (file["bytes"], file["sha256"]),
                        "record_file_marker")
        require(all(expected.get(key) is not None for key in markers), "record_file_owner_exists")
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(lambda item: fetch(node, item), files))
        result = {"source": owner["source"], "programs": owner["programs"], "home": owner["home"],
            "session": {key: owner[key] for key in ("pid", "start_ts")}, "stage": label,
            "operation_sha256": self.operation.operation_sha256,
            "accepted_commit_sha256": None if accepted is None else accepted["commit_sha256"],
            "records_sha256": hashlib.sha256(canonical(expected)).hexdigest(),
            "existing_records": sum(item is not None for item in expected.values()),
            "absent_records": sum(item is None for item in expected.values()),
            "exact_keyed_values": True, "files": files, "full_file_bytes_equal": True}
        original = save(self.operation.output / (label + "-reads.json"), result)
        self.operation.reads[label] = original
        return original


def fetch(node, item):
    """Read the whole file of record `item["key"]` and check its size and hash."""
    response, connection = node.call("/api/db/fetch-blob", {"schema": SCHEMA, "key": {"hash": item["key"]}},
                                     binary=True)
    try:
        total, digest = 0, hashlib.sha256()
        while True:
            block = response.read(min(1048576, item["bytes"] + 1 - total))
            if not block:
                break
            total += len(block)
            require(total <= item["bytes"], "record_file_overflow")
            digest.update(block)
    finally:
        connection.close()
    require(total == item["bytes"] and digest.hexdigest() == item["sha256"], "record_file_hash")


def memory(operation, node):
    started = time.monotonic()
    time.sleep(45)
    samples = []
    for _ in range(15):
        require(node.process is not None and node.process.poll() is None, "memory_owned_child")
        result = subprocess.run(["/bin/ps", "-p", str(node.process.pid), "-o", "rss="],
                                capture_output=True, timeout=10, check=True)
        require(len(result.stdout) <= 128 and result.stdout.strip().isdigit(), "bounded_memory_sample")
        samples.append(int(result.stdout.strip()) * 1024)
        require(0 < samples[-1] < operation.plan["memory_limit_mb"] * 1048576 * 0.9, "memory_guard")
        time.sleep(1)
    node.health()
    native = node.call("/api/db/native-status")
    return {"source": operation.plan["source"], "programs": operation.plan["programs"],
        "owner": node.owner, "operation_sha256": operation.operation_sha256,
        "memory_limit_mb": operation.plan["memory_limit_mb"], "samples_bytes": samples,
        "peak_bytes": max(samples), "settle_seconds": 45, "observation_seconds": 15,
        "elapsed_seconds": time.monotonic() - started,
        "native_health": {"version": operation.candidate.version, "native": native["native_disk"]}}
