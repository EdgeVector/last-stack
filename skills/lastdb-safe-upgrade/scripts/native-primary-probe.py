#!/usr/bin/env python3
"""Open a generated native home across a proposed primary upgrade."""

from contextlib import contextmanager
import http.client
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time


SCHEMA = "NativeUpgradeGenerated"


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def request(path, route, payload=None):
    with socket.socket(socket.AF_UNIX) as transport:
        transport.settimeout(15)
        transport.connect(str(path))
        body = json.dumps(payload).encode() if payload is not None else b""
        method = "POST" if payload is not None else "GET"
        headers = (f"{method} {route} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
                   f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n")
        transport.sendall(headers.encode() + body)
        result = http.client.HTTPResponse(transport)
        result.begin()
        require(result.status == 200, f"generated daemon refused {route} (HTTP {result.status})")
        return json.loads(result.read(1024 * 1024))


def sample(pid, limit_mb):
    rss = int(subprocess.check_output(["ps", "-p", str(pid), "-o", "rss="], text=True).strip())
    require(0 < rss < limit_mb * 1024, "generated daemon exceeded the memory guard headroom")


def await_boot(path, process, version):
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline and process.poll() is None:
        try:
            boot = request(path, "/api/system/boot-identity")
            require(boot["pid"] == process.pid and boot["build"] == version, "generated boot differs")
            return boot["process_start_ts"]
        except (OSError, http.client.HTTPException):
            time.sleep(0.2)
    raise ValueError("generated daemon did not boot")


@contextmanager
def node(program, home, path, limit):
    env = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(home), "LANG": "C",
           "LASTDB_ISOLATED_COPY": "1", "FOLDDB_DISABLE_KEYCHAIN": "1",
           "LASTDB_SUPPRESS_RECOVERY_PHRASE": "1", "LASTDB_TTL_SWEEP": "0"}
    version = subprocess.check_output([program, "--version"], text=True, timeout=15).strip().split()[-1]
    with subprocess.Popen([program, "--data-dir", home, "--socket-path", path], env=env,
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as process:
        start = None
        try:
            start = await_boot(path, process, version)
            sample(process.pid, limit)
            yield process.pid
        finally:
            if process.poll() is None:
                process.terminate()
            try:
                status = process.wait(timeout=150)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=10)
                raise ValueError("owned generated daemon did not stop cleanly") from None
            receipt = home / ".shutdown_flush_ready"
            if start is not None:
                require(status == 0 and json.loads(receipt.read_text()) ==
                        {"version": 1, "pid": process.pid, "start_ts": start, "flush_ok": True},
                        "generated daemon did not prove a durable stop")


def fields(key, value):
    return {"bucket": "upgrade", "id": key, "value": value}


def record_page(item):
    require(isinstance(item, dict) and "error" not in item and isinstance(item.get("records"), list),
            "generated keyed reads differ")
    return [row["record"] for row in item["records"]]


def check(path, values):
    reply = request(path, "/v1/read", {"reads": [
        {"schema": SCHEMA, "key": {"hash": "upgrade", "range": "a"}, "limit": 1},
        {"schema": SCHEMA, "range": {"hash": "upgrade", "start": "a", "end": "z"}, "limit": 2},
    ]})
    results = reply["results"]
    require(isinstance(results, list) and len(results) == 2, "generated keyed reads differ")
    expected = [fields(key, value) for key, value in values.items()]
    require(record_page(results[0]) == expected[:1] and record_page(results[1]) == expected,
            "generated keyed reads differ")
    revision = results[0]["records"][0]["revision"]
    require(isinstance(revision, str) and revision, "generated keyed reads differ")
    return revision


def write(path, values, expected):
    absent = expected["type"] == "absent"
    batch = []
    for key, value in values.items():
        item = {"schema": SCHEMA, "op": "create" if absent else "replace",
                "key": {"hash": "upgrade", "range": key}, "record": fields(key, value)}
        if not absent:
            item["revision"] = expected["revision"]
        batch.append(item)
    reply = request(path, "/v1/write", {"mutations": batch})
    revisions = reply["revisions"]
    require(reply["written"] == len(batch) and isinstance(revisions, list) and len(revisions) == len(batch)
            and all(isinstance(item, str) and item for item in revisions),
            "generated write did not flush")


def main():
    old, candidate, limit, settle, samples = sys.argv[1:]
    limit, settle, samples = map(int, (limit, settle, samples))
    require(limit > 0 and settle >= 0 and samples > 0, "invalid memory guard interval or limit")
    with tempfile.TemporaryDirectory(prefix="ldb-native-probe-", dir="/private/tmp") as folder:
        home, path = Path(folder) / "home", Path(folder) / "db.sock"
        home.mkdir(mode=0o700)
        with node(old, home, path, limit):
            keys = ["bucket", "id", "value"]
            request(path, "/api/schemas/seed-system", {"isolated_copy": True, "schema": {
                "name": SCHEMA, "descriptive_name": SCHEMA, "source": "system_seed",
                "schema_type": "HashRange", "fields": keys,
                "record_keys": {"primary": {"kind": "hash_range", "range_type": "String"}, "alternates": {}},
                "field_types": dict.fromkeys(keys, "String"),
                "field_descriptions": {key: "Generated upgrade " + key for key in keys},
                "field_versions": dict.fromkeys(keys, 1)}})
            write(path, {"a": "old", "b": "old"}, {"type": "absent"})
        with node(candidate, home, path, limit) as pid:
            revision = check(path, {"a": "old", "b": "old"})
            write(path, {"a": "new"}, {"type": "revision", "revision": revision})
            check(path, {"a": "new", "b": "old"})
            for _ in range(settle + samples):
                sample(pid, limit)
                time.sleep(1)
        with node(old, home, path, limit):
            check(path, {"a": "new", "b": "old"})


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, http.client.HTTPException) as error:
        raise SystemExit(f"Native upgrade probe failed: {error}") from None
