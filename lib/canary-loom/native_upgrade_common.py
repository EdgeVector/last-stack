"""Bounded local checks for the native, Cloud-Off LastDB upgrade route."""

import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import stat
import subprocess
import time


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def run(argv, timeout=30, check=True, env=None):
    result = subprocess.run(list(map(str, argv)), capture_output=True, text=True,
                            timeout=timeout, env=env)
    # Do not include subprocess output: a supervisor or daemon can print secrets.
    require(not check or result.returncode == 0, "Command failed: " + str(argv[0]))
    return result


def sha(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def regular(path, private=False, maximum=None):
    info = Path(path).lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(),
            "Expected an owner-controlled regular file: " + str(path))
    require(not private or info.st_mode & 0o077 == 0, "File must be private: " + str(path))
    require(not maximum or info.st_size <= maximum, "File exceeds its bound: " + str(path))
    return info


def load(path, private=True, maximum=1024 * 1024):
    regular(path, private, maximum)
    return json.loads(Path(path).read_text())


def private_dir(path):
    path = Path(path).expanduser()
    require(path.is_absolute(), "A private directory must be absolute")
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    require(path.resolve() == path and path.stat().st_uid == os.getuid()
            and path.stat().st_mode & 0o077 == 0, "Unsafe private directory: " + str(path))
    return path


def save(path, value):
    path = Path(path)
    private_dir(path.parent)
    if path.exists() or path.is_symlink():
        regular(path, True)
    stage = path.with_name(path.name + ".tmp." + str(os.getpid()))
    with os.fdopen(os.open(stage, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as stream:
        json.dump(value, stream, indent=2, sort_keys=True)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(stage, path)
    sync_dir(path.parent)


def sync_dir(path):
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


class Connection(http.client.HTTPConnection):
    def __init__(self, path, timeout):
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


class NotReady(RuntimeError):
    """An explicit temporary startup refusal, not an unhealthy native writer."""


def call(sock, route, body=None, timeout=30):
    connection = Connection(sock, timeout)
    try:
        connection.request("GET" if body is None else "POST", route,
                           None if body is None else json.dumps(body),
                           {"Content-Type": "application/json",
                            "X-LastDB-Client": "lastdb-safe-upgrade-native"})
        response = connection.getresponse()
        raw = response.read(8 * 1024 * 1024 + 1)
        if response.status == 503 and body is None and route in (
                "/health", "/api/version", "/api/status", "/api/db/native-status"):
            raise NotReady("The daemon is not ready")
        require(response.status == 200 and len(raw) <= 8 * 1024 * 1024,
                "Native upgrade request refused: " + route)
        value = json.loads(raw)
        require(value.get("ok") is not False, "Native upgrade request failed: " + route)
        return value.get("data", value)
    finally:
        connection.close()


def _current_health(sock, version=None, pid=None):
    value = call(sock, "/health")
    require(value.get("status") == "ok", "Daemon health is not green")
    if pid:
        require(value.get("instance_id", "").startswith(str(pid) + "-"),
                "Socket and supervised process differ")
    build = call(sock, "/api/version").get("build")
    require(not version or build == version, "Live version differs from the bound pair")
    status = call(sock, "/api/status")["status"]
    require(status.get("durability", {}).get("automatic_enabled") is False,
            "Cloud must stay off")
    sampled = status.get("sampled_at")
    require(type(sampled) is int and 0 <= time.time() - sampled <= 300,
            "The status sample is absent, future, or stale")
    resident = status.get("resident", {})
    require(resident.get("persist_lane_failures") == 0 and resident.get("deferred_persist_failed") == 0,
            "The persist status failure gauges are absent or nonzero")
    native = call(sock, "/api/db/native-status")["native_disk"]
    parts = native["parts"]
    require(native["writer_failed"] is False, "The native writer failure mark is set")
    require(parts["auto_maintenance"] is True, "Automatic maintenance is off")
    require(all(type(parts.get(name)) is int and parts[name] >= 0
                for name in ("maintenance_failures", "reclaim_failures")),
            "Native maintenance failure counters are absent or invalid")
    require(parts["maintenance_last_error"] is None and parts["reclaim_last_error"] is None,
            "Native maintenance reports a failure")
    return {"version": build, "native": native, "cloud_off": True}


def health(sock, version=None, pid=None):
    value = _current_health(sock, version, pid)
    parts = value["native"]["parts"]
    require(parts["maintenance_failures"] == 0 and parts["reclaim_failures"] == 0,
            "Native maintenance reports a failure")
    return value


def baseline_health(sock, version, identity):
    require(isinstance(identity, dict) and set(identity) == {"pid", "start_ts"}
            and all(type(identity[name]) is int and identity[name] > 0 for name in identity),
            "The baseline session identity is invalid")
    value = _current_health(sock, version, identity["pid"])
    parts = value["native"]["parts"]
    require(type(parts.get("maintenance_runs")) is int and parts["maintenance_runs"] >= 0,
            "Baseline maintenance publication count is absent or invalid")
    # A successful publication clears last_error, not the process-lifetime
    # failure counter. Only the unchanged old session can retain that history.
    require(parts["reclaim_failures"] == 0, "Baseline reclaim reports a failure")
    require(parts["maintenance_failures"] == 0 or parts["maintenance_runs"] > 0,
            "Baseline maintenance history lacks a successful publication")
    history = {"session": dict(identity), "maintenance_failures": parts["maintenance_failures"],
               "reclaim_failures": parts["reclaim_failures"], "maintenance_runs": parts["maintenance_runs"]}
    value["maintenance_history"] = history
    return value


def memory(pid, limit_mb):
    value = run(["/bin/ps", "-p", str(pid), "-o", "rss="]).stdout.strip()
    require(value.isdigit(), "The daemon memory size is unavailable")
    size = int(value) * 1024
    require(size < limit_mb * 1024 * 1024 * 0.9, "The daemon exceeds the memory guard with 10 percent headroom")
    return size


def version(path):
    value = run([path, "--version"]).stdout.strip().split()
    require(bool(value), "Binary version is absent")
    return value[-1]


def pair(directory):
    directory = Path(directory)
    result = {}
    for name in ("lastdbd", "lastdb"):
        path = directory / name
        regular(path)
        require(os.access(path, os.X_OK), "Binary is not executable")
        run(["/usr/bin/codesign", "--verify", "--strict", path])
        require(run(["/usr/bin/lipo", "-archs", path]).stdout.strip() == "arm64",
                "Expected the macOS arm64 binary")
        result[name] = {"path": str(path), "sha256": sha(path), "version": version(path)}
    require(result["lastdb"]["version"] == result["lastdbd"]["version"], "Pair versions differ")
    return result


def session(home):
    value = load(Path(home) / "current-session.json", private=False, maximum=4096)
    require(type(value.get("pid")) is int and value["pid"] > 0
            and type(value.get("start_ts")) is int and value["start_ts"] > 0,
            "Invalid daemon session")
    return {name: value[name] for name in ("pid", "start_ts")}


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


def stopped(home, identity):
    require(not alive(identity["pid"]), "The stopped daemon still runs")
    receipt = load(Path(home) / ".shutdown_flush_ready", private=False, maximum=4096)
    require(receipt == {"version": 1, **identity, "flush_ok": True},
            "The shutdown flush receipt differs from the stopped session")
    ledger = Path(home) / "sessions.jsonl"
    regular(ledger, maximum=16 * 1024 * 1024)
    matches = []
    for line in ledger.read_text().splitlines():
        row = json.loads(line)
        if all(row.get(k) == v for k, v in identity.items()):
            matches.append(row)
    require(len(matches) == 1 and matches[0].get("exit") == "clean"
            and type(matches[0].get("end_ts")) is int
            and matches[0]["end_ts"] >= identity["start_ts"],
            "The session ledger does not prove a clean stop")
    return {"receipt": receipt, "session": matches[0]}


def exact_read(sock, schema, fields, keys, expected):
    result = call(sock, "/api/query", {"schema_name": schema, "fields": fields,
                  "filter": ({"HashKey": keys[0]} if len(keys) == 1 else
                             {"HashRangeKeys": [[key, ""] for key in keys]}),
                  "limit": len(keys)})
    require(not result.get("unresolved_rows", 0) and not result.get("has_more", False),
            "The exact keyed read is incomplete")
    found = {row["key"]["hash"]: row["fields"] for row in result.get("results", [])}
    require(len(found) == len(result.get("results", [])) and found == expected,
            "The exact keyed values differ")
    return {"keys": keys, "values_sha256": hashlib.sha256(
        json.dumps(found, sort_keys=True).encode()).hexdigest()}


def durable_batch(sock, mutations):
    before = call(sock, "/api/db/native-status")["native_disk"]
    result = call(sock, "/api/mutations/batch", {"mutations": mutations})
    # This must precede every read, flush, and compaction after the ack.
    after = call(sock, "/api/db/native-status")["native_disk"]
    require(result.get("count") == len(mutations) and result.get("durability") == "durable",
            "The default write acknowledgement is not durable")
    require(after["completed_sequence"] > before["completed_sequence"]
            and after["writer_failed"] is False, "The completed disk boundary did not advance")
    return {"ack": result, "completed_before": before["completed_sequence"],
            "completed_after_ack": after["completed_sequence"], "durability_option": "omitted"}


def wait_health(sock, build, pid, seconds=120):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            return health(sock, build, pid)
        except (OSError, http.client.HTTPException, NotReady):
            time.sleep(0.2)
    raise RuntimeError("The daemon missed its health deadline")
