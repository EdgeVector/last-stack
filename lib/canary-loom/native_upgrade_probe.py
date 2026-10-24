"""The safe-upgrade operational check on a new generated native home only."""

import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

from native_upgrade_common import (call, durable_batch, exact_read, health, memory, private_dir,
                                   require, save, session, stopped, wait_health)

SCHEMA = "NativeSafeUpgradeReceipt"
FIELDS = ["receipt_id", "receipt_value"]


class GeneratedNode:
    def __init__(self, output, limit_mb, tuning):
        self.output = private_dir(output)
        self.root = Path(tempfile.mkdtemp(prefix="ldb-upgrade-", dir="/tmp")).resolve()
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.sock = self.root / "q.sock"
        self.owner = {"pid": os.getpid(), "uid": os.getuid(), "root": str(self.root),
                      "inode": self.root.stat().st_ino, "generated_only": True}
        save(self.root / "owner.json", self.owner)
        save(self.output / "ownership.json", self.owner)
        self.process = None
        self.stream = None
        self.stops = []
        self.limit_mb, self.tuning = limit_mb, tuning
        self.observed_peak_bytes = 0

    def start(self, binary, build):
        require(self.process is None, "An owned daemon still exists")
        # A fresh synthetic identity, with no inherited account or service configuration.
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "C", "LC_ALL": "C",
                       "HOME": str(self.home), "TMPDIR": str(self.root),
                       "LASTDB_HOME": str(self.home), "FOLDDB_HOME": str(self.home),
                       "LASTDB_ISOLATED_COPY": "1", "LASTDB_SUPPRESS_RECOVERY_PHRASE": "1",
                       "FOLDDB_DISABLE_KEYCHAIN": "1", "LASTDBD_STDIO_LOG_ROTATION": "0",
                       "RUST_MIN_STACK": "16777216"}
        environment.update(self.tuning)
        log = self.output / "generated-node.log"
        self.stream = os.fdopen(os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "ab")
        self.process = subprocess.Popen([str(binary), "--data-dir", str(self.home),
            "--socket-path", str(self.sock), "--full-socket-path", str(self.root / "f.sock")],
            env=environment, stdin=subprocess.DEVNULL, stdout=self.stream, stderr=self.stream)
        result = wait_health(self.sock, build, self.process.pid)
        self.sample_memory()
        return result

    def sample_memory(self):
        self.observed_peak_bytes = max(self.observed_peak_bytes,
                                      memory(self.process.pid, self.limit_mb))

    def settle(self):
        # Retain the skill's 45-second settle plus 15-second observation bar.
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            self.sample_memory()
            time.sleep(min(1, max(0, deadline - time.monotonic())))

    def stop(self):
        if self.process is None:
            return
        process = self.process
        identity, proof_error = None, None
        try:
            identity = session(self.home)
            require(identity["pid"] == process.pid, "The generated node session differs")
        except Exception as error:
            proof_error = error
        if process.poll() is None:
            process.send_signal(signal.SIGTERM)
        try:
            code = process.wait(timeout=120)
        except subprocess.TimeoutExpired:
            # This PID is an owned generated node, never the primary. A forced
            # cleanup cannot produce a green operational check.
            process.kill()
            process.wait(timeout=10)
            raise RuntimeError("The generated node failed its strict shutdown deadline")
        finally:
            if process.poll() is not None:
                self.process = None
                self.stream.close()
                self.stream = None
        require(code == 0, "The generated daemon exited with an error")
        if proof_error is not None:
            raise RuntimeError("The stopped generated node lacks a valid session") from proof_error
        self.stops.append(stopped(self.home, identity))

    def close(self):
        try:
            self.stop()
        finally:
            require(self.process is None and self.root.resolve() == self.root
                    and self.root.stat().st_uid == os.getuid()
                    and self.root.stat().st_ino == self.owner["inode"], "Generated home ownership changed")
            from native_upgrade_common import load
            require(load(self.root / "owner.json") == self.owner, "Generated home owner receipt changed")
            # Exact owned temporary root, with no primary files or external symlinks.
            shutil.rmtree(self.root)
            save(self.output / "cleanup.json", {"removed": str(self.root), "stopped": True})

    def call(self, route, body=None, timeout=30):
        self.sample_memory()
        result = call(self.sock, route, body, timeout)
        self.sample_memory()
        return result


def probe(baseline, candidate, output, limit_mb, tuning):
    node = GeneratedNode(output, limit_mb, tuning)
    receipt = {"generated_only": True, "primary_copy": False, "passed": False,
               "started_at": int(time.time()), "baseline": baseline, "candidate": candidate}
    try:
        node.start(baseline["lastdbd"]["path"], baseline["lastdbd"]["version"])
        node.call("/api/schemas/seed-system", {"isolated_copy": True, "schema": {
            "source": "system_seed", "name": SCHEMA, "descriptive_name": SCHEMA,
            "schema_type": "Hash", "key": {"hash_field": FIELDS[0]}, "fields": FIELDS,
            "field_descriptions": {field: "Generated safe upgrade " + field for field in FIELDS}}})
        expected = {"retained": {FIELDS[0]: "retained", FIELDS[1]: "baseline"},
                    "deleted": {FIELDS[0]: "deleted", FIELDS[1]: "baseline"}}
        receipt["baseline_ack"] = durable_batch(node.sock, [
            {"type": "mutation", "schema": SCHEMA, "mutation_type": "create",
             "key_value": {"hash": key}, "fields_and_values": fields}
            for key, fields in expected.items()])
        node.stop()
        node.start(candidate["lastdbd"]["path"], candidate["lastdbd"]["version"])
        receipt["baseline_read"] = exact_read(node.sock, SCHEMA, FIELDS, list(expected), expected)
        receipt["candidate_ack"] = durable_batch(node.sock, [
            {"type": "mutation", "schema": SCHEMA, "mutation_type": "update",
             "key_value": {"hash": "retained"}, "fields_and_values": {FIELDS[1]: "candidate"}},
            {"type": "mutation", "schema": SCHEMA, "mutation_type": "delete",
             "key_value": {"hash": "deleted"}, "fields_and_values": {}}])
        expected["retained"][FIELDS[1]] = "candidate"
        del expected["deleted"]
        receipt["candidate_read"] = exact_read(node.sock, SCHEMA, FIELDS,
                                                ["retained", "deleted"], expected)
        compact = node.call("/api/db/compact", {"dry_run": False, "grace_ms": 0}, timeout=180)
        require(compact["compact"]["native_disk"].get("executed") is True,
                "Generated native compaction did not execute")
        receipt["compaction"] = compact
        node.settle()
        node.stop()
        # Reopen candidate output with the saved baseline before a live cutover.
        # No primary data participates in this compatibility check.
        node.start(baseline["lastdbd"]["path"], baseline["lastdbd"]["version"])
        receipt["baseline_reopen_read"] = exact_read(node.sock, SCHEMA, FIELDS,
                                                       ["retained", "deleted"], expected)
        node.stop()
        node.start(candidate["lastdbd"]["path"], candidate["lastdbd"]["version"])
        receipt["candidate_reopen_read"] = exact_read(node.sock, SCHEMA, FIELDS,
                                                        ["retained", "deleted"], expected)
        receipt["final_health"] = health(node.sock, candidate["lastdbd"]["version"], node.process.pid)
        node.stop()
        receipt["stops"] = node.stops
        receipt["memory_limit_mb"] = limit_mb
        receipt["observed_peak_bytes"] = node.observed_peak_bytes
        receipt["passed"] = True
        receipt["completed_at"] = int(time.time())
    finally:
        try:
            node.close()
        finally:
            save(Path(output) / "probe.json", receipt)
    return receipt
