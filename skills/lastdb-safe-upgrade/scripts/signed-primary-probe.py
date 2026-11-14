#!/usr/bin/env python3
"""Open a generated native home across a proposed signed-primary upgrade."""

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


SCHEMA = "SignedUpgradeGenerated"


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


def check(path, values):
    point = request(path, "/api/query", {"schema_name": SCHEMA, "limit": 1,
                   "filter": {"HashRangeKey": {"hash": "upgrade", "range": "a"}}})
    ranged = request(path, "/api/query", {"schema_name": SCHEMA, "limit": 2,
                     "filter": {"HashRangeRange": {"hash": "upgrade", "start": "a", "end": "z"}}})
    expected = [fields(key, value) for key, value in values.items()]
    require([row["fields"] for row in point["results"]] == expected[:1]
            and [row["fields"] for row in ranged["results"]] == expected, "generated keyed reads differ")
    return point["results"][0]["revision"]


def write(path, values, expected):
    batch = [{"type": "mutation", "schema": SCHEMA, "record": fields(key, value),
              "key_value": {"hash": "upgrade", "range": key}, "alternates": {},
              "mutation_type": "create" if expected["type"] == "absent" else "replace",
              "expected": expected, "durability": "durable", "convergence": "sync"}
             for key, value in values.items()]
    reply = request(path, "/api/mutations/batch", {"mutations": batch})
    require(reply["count"] == len(batch) and reply["durability"] == "durable", "generated write did not flush")


def main():
    old, candidate, limit, settle, samples = sys.argv[1:]
    limit, settle, samples = map(int, (limit, settle, samples))
    require(limit > 0 and settle >= 0 and samples > 0, "invalid memory guard interval or limit")
    with tempfile.TemporaryDirectory(prefix="ldb-signed-probe-", dir="/private/tmp") as folder:
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
        raise SystemExit(f"Signed upgrade probe failed: {error}") from None
