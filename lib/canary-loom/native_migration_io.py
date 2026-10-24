"""Opaque transfer and private target checks for the two-home upgrade."""

import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import tempfile
import time

from native_upgrade_common import (call, durable_batch, exact_read, health, memory,
                                   private_dir, require, save, session, sha, stopped, wait_health)
from native_upgrade_probe import GeneratedNode, FIELDS, SCHEMA


def transfer(source, target, tools):
    data = private_dir(Path(target) / "data")
    physical = data / "disk-pack"
    require(not physical.exists(), "A record transfer requires a fresh target")
    exporter = subprocess.Popen([tools["source"]["path"], "export", "--home",
        str(Path(source) / "data/disk-pack")], stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    try:
        imported = subprocess.run([tools["target"]["path"], "import", "--home", str(physical)],
            stdin=exporter.stdout, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=600)
        exporter.stdout.close()
        _, exported = exporter.communicate(timeout=60)
        require(exporter.returncode == 0 and imported.returncode == 0,
                "The complete native record transfer failed; retain the source")
        source_receipt, target_receipt = json.loads(exported), json.loads(imported.stderr)
        require(source_receipt == target_receipt and source_receipt.get("records", 0) > 0,
                "Complete source and target transfer receipts differ")
        return source_receipt
    finally:
        if exporter.poll() is None:
            # This is our read-only transport worker, never a database daemon.
            exporter.kill()
            exporter.wait(timeout=15)


def prepare(candidate, source, target, primary=False):
    argv = [candidate["lastdb"]["path"], "--data-dir", str(target),
            "db", "prepare-native-transfer", "--source-home", str(source)]
    if primary:
        argv.append("--i-know-this-is-primary")
    from native_upgrade_common import run
    run(argv, timeout=180)


class PrivateTarget:
    def __init__(self, home, output, ceiling, environment):
        self.home, self.output = Path(home), private_dir(output)
        self.socket_root = Path(tempfile.mkdtemp(prefix="ldb-migrate-", dir="/tmp")).resolve()
        self.socket_inode = self.socket_root.stat().st_ino
        self.socket = self.socket_root / "q.sock"
        self.ceiling, self.environment = ceiling, environment
        self.process = self.stream = None

    def start(self, candidate):
        require(self.process is None, "A target process already exists")
        environment = dict(self.environment)
        environment.update({"HOME": str(self.home), "LASTDB_HOME": str(self.home),
            "FOLDDB_HOME": str(self.home), "LASTDB_ISOLATED_COPY": "0",
            "LASTDB_SUPPRESS_RECOVERY_PHRASE": "1", "LASTDBD_STDIO_LOG_ROTATION": "0"})
        self.stream = os.fdopen(os.open(self.output / "target.log",
            os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600), "ab")
        self.process = subprocess.Popen([candidate["lastdbd"]["path"], "--data-dir", str(self.home),
            "--socket-path", str(self.socket), "--full-socket-path", str(self.socket_root / "f.sock")],
            stdin=subprocess.DEVNULL, stdout=self.stream, stderr=self.stream, env=environment)
        save(self.output / "process.json", {"pid": self.process.pid, "home": str(self.home),
             "binary_sha256": candidate["lastdbd"]["sha256"]})
        result = wait_health(self.socket, candidate["lastdbd"]["version"], self.process.pid)
        memory(self.process.pid, self.ceiling)
        return result

    def stop(self):
        require(self.process is not None, "The private target process is absent")
        identity = session(self.home)
        require(identity["pid"] == self.process.pid, "The target session differs")
        if self.process.poll() is None:
            self.process.send_signal(signal.SIGTERM)
        require(self.process.wait(timeout=150) == 0, "Private target clean stop failed")
        proof = stopped(self.home, identity)
        self.process = None
        self.stream.close()
        self.stream = None
        return proof

    def close(self):
        if self.process is not None:
            self.stop()
        require(self.socket_root.resolve() == self.socket_root
                and self.socket_root.stat().st_uid == os.getuid()
                and self.socket_root.stat().st_ino == self.socket_inode,
                "Private target socket directory ownership differs")
        shutil.rmtree(self.socket_root)


def generated_probe(baseline, candidate, tools, output, ceiling, tuning):
    source, target = GeneratedNode(output / "source", ceiling, tuning), GeneratedNode(output / "target", ceiling, tuning)
    result = {"passed": False, "generated_only": True, "primary_copy": False,
              "baseline": baseline, "candidate": candidate, "tools": tools}
    try:
        source.start(baseline["lastdbd"]["path"], baseline["lastdbd"]["version"])
        source.call("/api/schemas/seed-system", {"isolated_copy": True, "schema": {
            "source": "system_seed", "name": SCHEMA, "descriptive_name": SCHEMA,
            "schema_type": "Hash", "key": {"hash_field": FIELDS[0]}, "fields": FIELDS,
            "field_descriptions": {field: "Generated migration " + field for field in FIELDS}}})
        rows = [{"type": "mutation", "schema": SCHEMA, "mutation_type": "create",
                 "key_value": {"hash": key}, "fields_and_values": {
                     FIELDS[0]: key, FIELDS[1]: "source"}} for key in ("retained", "deleted")]
        durable_batch(source.sock, rows)
        durable_batch(source.sock, [{"type": "mutation", "schema": SCHEMA,
            "mutation_type": "delete", "key_value": {"hash": "deleted"}, "fields_and_values": {}}])
        source.stop()
        result["transfer"] = transfer(source.home, target.home, tools)
        prepare(candidate, source.home, target.home)
        expected = {"retained": {FIELDS[0]: "retained", FIELDS[1]: "source"}}
        target.start(candidate["lastdbd"]["path"], candidate["lastdbd"]["version"])
        exact_read(target.sock, SCHEMA, FIELDS, ["retained", "deleted"], expected)
        durable_batch(target.sock, [{"type": "mutation", "schema": SCHEMA, "mutation_type": "update",
            "key_value": {"hash": "retained"}, "fields_and_values": {FIELDS[1]: "target"}}])
        expected["retained"][FIELDS[1]] = "target"
        compact = target.call("/api/db/compact", {"dry_run": False, "grace_ms": 0}, timeout=180)
        require(compact["compact"]["native_disk"].get("executed") is True, "Generated target compaction failed")
        target.settle()
        target.stop()
        target.start(candidate["lastdbd"]["path"], candidate["lastdbd"]["version"])
        exact_read(target.sock, SCHEMA, FIELDS, ["retained", "deleted"], expected)
        target.stop()
        source.start(baseline["lastdbd"]["path"], baseline["lastdbd"]["version"])
        expected["retained"][FIELDS[1]] = "source"
        result["retained_source_read"] = exact_read(source.sock, SCHEMA, FIELDS, ["retained", "deleted"], expected)
        source.stop()
        result.update(passed=True, completed_at=int(time.time()))
    finally:
        try:
            target.close()
        finally:
            source.close()
            save(output / "migration-probe.json", result)
    return result
