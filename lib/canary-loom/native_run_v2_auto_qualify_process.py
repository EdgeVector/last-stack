"""Bounded original output and exact child receipts for the Mac DEV operation."""
import http.client
import json
import os
from pathlib import Path
import selectors
import signal
import subprocess
import threading
import time

from native_run_v2_auto_qualify_io import read, reference, require, save
from native_run_v2_auto_qualify_health import health
from native_run_v2_auto_qualify_http import call as http_call


def execute(command, environment, output, input_bytes=None, timeout=120):
    require(input_bytes is None or len(input_bytes) <= 4096, "bounded_cli_stdin")
    output.mkdir(mode=0o700)
    child = subprocess.Popen(command, env=environment, stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, umask=0o077)
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": 4 * 1024 * 1024, "stderr": 65536}
    deadline, failure = time.monotonic() + timeout, None
    try:
        if input_bytes:
            child.stdin.write(input_bytes)
        child.stdin.close()
        with selectors.DefaultSelector() as pending:
            pending.register(child.stdout, selectors.EVENT_READ, "stdout")
            pending.register(child.stderr, selectors.EVENT_READ, "stderr")
            while pending.get_map():
                require(time.monotonic() < deadline, "owned_cli_deadline")
                for key, _ in pending.select(0.2):
                    block = os.read(key.fileobj.fileno(), 65536)
                    if not block:
                        pending.unregister(key.fileobj)
                        continue
                    require(len(buffers[key.data]) + len(block) <= limits[key.data], "owned_cli_output_bound")
                    buffers[key.data].extend(block)
        child.wait(timeout=max(0.1, deadline - time.monotonic()))
        require(child.returncode == 0, "owned_cli_refused")
    except BaseException as error:
        failure = error
    finally:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait(timeout=15)
        for name, value in buffers.items():
            descriptor = os.open(output / (name + ".bin"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(descriptor, "wb") as stream:
                stream.write(value)
                stream.flush()
                os.fsync(stream.fileno())
        save(output / "result.json", {"pid": child.pid, "returncode": child.returncode,
             "stdout": reference(output / "stdout.bin"), "stderr": reference(output / "stderr.bin"),
             "complete": failure is None})
        child.stdout.close()
        child.stderr.close()
        if not child.stdin.closed:
            child.stdin.close()
    if failure is not None:
        raise failure
    return bytes(buffers["stdout"])


class Pair:
    def __init__(self, helpers, directory, version, environment, source, expected, output):
        identities = {name: helpers.programs.executable(Path(directory) / name)["sha256"]
                      for name in ("lastdb", "lastdbd")}
        require(identities == expected, "approved_pair_before_execution")
        self.base = helpers.programs.Programs(Path(directory), version, environment)
        self.directory, self.version, self.environment = self.base.directory, version, environment
        self.source, self.expected, self.output, self.calls = source, expected, output, 0
        require({k: v["sha256"] for k, v in self.base.identities.items()} == expected, "exact_program_hashes")
        self.helpers = helpers

    def verify(self):
        self.base.verify()
        require({k: v["sha256"] for k, v in self.base.identities.items()} == self.expected, "unchanged_pair")

    def command(self, home, arguments, input_bytes=None, timeout=120):
        self.verify()
        self.calls += 1
        require(self.calls <= 16384, "bounded_owner_cli_calls")
        command = [str(self.directory / "lastdb"), "--data-dir", str(home), *arguments]
        environment = dict(self.environment, LASTDB_BYTE_BACKUP_V2_ENABLED="true")
        output = self.output / ("cli-" + str(self.calls).zfill(5))
        raw = execute(command, environment, output, input_bytes, timeout)
        self.last_response_ref = reference(output / "stdout.bin")
        return self.helpers.support.decode_json(raw)

    def restore(self, home, destination, selected, phrase):
        return self.command(home, ["cloud", "backup-v2", "restore", "--recovery-phrase-stdin",
            "--stream", selected["stream_id"], "--generation", selected["account_generation"],
            "--commit", selected["commit_id"], "--commit-sha256", selected["commit_sha256"],
            "--into", str(destination), "--json"], phrase, timeout=1200)

    def resume(self, home, session, phrase):
        return self.command(home, ["cloud", "backup-v2", "restore", "--recovery-phrase-stdin",
            "--resume", str(session), "--json"], phrase, timeout=1200)


class Logs:
    def __init__(self, output):
        self.output, self.threads, self.failure = output, [], False
        self.paths = []
        self.sizes = {}

    def attach(self, child):
        for name in ("stdout", "stderr"):
            path = self.output / ("daemon-" + name + ".bin")
            descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            self.paths.append(path)
            self.sizes[name] = {"observed_bytes": 0, "retained_bytes": 0}
            thread = threading.Thread(target=self.drain, args=(getattr(child, name), descriptor,
                                      self.sizes[name]), daemon=True)
            self.threads.append(thread)
            try:
                thread.start()
            except BaseException:
                os.close(descriptor)
                self.failure = True
                raise

    def drain(self, source, descriptor, sizes):
        try:
            with os.fdopen(descriptor, "wb") as target:
                stored = 0
                for block in iter(lambda: source.read(65536), b""):
                    keep = block[:max(0, 262144 - stored)]
                    sizes["observed_bytes"] += len(block)
                    sizes["retained_bytes"] += len(keep)
                    target.write(keep)
                    stored += len(keep)
                    if len(keep) != len(block):
                        self.failure = True
                target.flush()
                os.fsync(target.fileno())
        except BaseException:
            self.failure = True

    def finish(self, strict=True):
        readers_closed = True
        for thread in self.threads:
            if thread.ident is not None:
                thread.join(timeout=10)
                readers_closed = readers_closed and not thread.is_alive()
        complete = not self.failure and readers_closed
        if strict:
            require(complete, "daemon_log_bound_or_io")
        return {"files": [reference(path) for path in self.paths], "sizes": self.sizes,
                "complete": complete, "readers_closed": readers_closed}


def node(operation, home, pair, label, source=False):
    class QualifiedNode(operation.helpers.node.OwnedNode):
        def __init__(self):
            super().__init__(home, pair, backup_source=source)
            self.folder = operation.output / label
            self.folder.mkdir(mode=0o700)
            self.logs, self.owner = Logs(self.folder), None
            self.http_connection, self.http_decode = operation.helpers.node.Connection, operation.helpers.support.decode_json
            self.http_failures, self.http_lock, self.http_last_failure = 0, threading.Lock(), None

        call = http_call

        def health(self, readiness=False):
            return health(self, operation.account, readiness)

        def start(self):
            require(self.process is None and not self.socket.exists(), "owned_start_absent")
            self.offline()
            pair.verify()
            environment = dict(pair.environment, LASTDB_BYTE_BACKUP_V2_ENABLED="true" if source else "false",
                               LASTDB_ISOLATED_COPY="1" if source else "0", LASTDB_TTL_SWEEP="0")
            self.process = subprocess.Popen([str(pair.directory / "lastdbd"), "--data-dir", str(home)],
                env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                start_new_session=True, umask=0o077)
            save(self.folder / "launch.json", {"pid": self.process.pid, "home": str(home),
                "source": pair.source, "programs": pair.expected, "account": operation.account,
                "operation_sha256": operation.operation_sha256,
                "argv": [str(pair.directory / "lastdbd"), "--data-dir", str(home)]})
            self.logs.attach(self.process)
            deadline = time.monotonic() + 120
            while time.monotonic() < deadline:
                require(self.process.poll() is None and not self.logs.failure, "owned_daemon_start")
                try:
                    if self.health(readiness=True):
                        self.owner = {"source": pair.source, "programs": pair.expected, "home": str(home),
                            "account": operation.account, "pid": self.process.pid, "start_ts": self.start_ts,
                            "host_start_ts": self.host_start_ts,
                            "operation_sha256": operation.operation_sha256}
                        save(self.folder / "owner.json", self.owner)
                        return
                except (OSError, http.client.HTTPException):
                    pass
                time.sleep(0.2)
            require(False, "owned_daemon_start_deadline")

        def stop(self):
            owner = self.owner
            require(owner is not None, "owner_receipt_before_stop")
            super().stop()
            rows = ledger(home)
            identity = {key: owner[key] for key in ("pid", "start_ts")}
            found = [row for row in rows if all(row.get(k) == v for k, v in identity.items())]
            require(len(found) == 1 and found[0].get("exit") == "clean"
                    and found[0].get("end_ts", 0) >= owner["start_ts"], "exact_clean_ledger")
            original = {"owner": owner, "receipt": read(home / ".shutdown_flush_ready", 4096),
                        "session": found[0], "logs": self.logs.finish(strict=False)}
            stop = save(self.folder / "stop.json", original)
            operation.consumers[label] = {"owner": reference(self.folder / "owner.json"), "stop": stop}
            require(original["logs"]["complete"], "complete_owned_daemon_diagnostics")

        def cleanup_stop(self):
            process = self.process
            if process is None:
                return
            diagnostic = {"pid": process.pid, "strict_stop": False}
            try:
                super().cleanup_stop()
            except BaseException as error:
                diagnostic["cleanup_failure_class"] = type(error).__name__
            finally:
                diagnostic.update(returncode=process.poll(), forced=self.forced)
                try:
                    diagnostic["logs"] = self.logs.finish(strict=False)
                except BaseException as error:
                    diagnostic["diagnostic_failure_class"] = type(error).__name__
                save(self.folder / "failed-child-exit.json", diagnostic)

    allowed = getattr(operation, "owned_homes", {operation.homes / name for name in ("s", "r", "b", "t")})
    require(home.parent == operation.homes and home in allowed, "only_owned_home")
    owned = QualifiedNode()
    operation.node = owned
    return owned


def ledger(home):
    path = home / "sessions.jsonl"
    require(path.is_file() and not path.is_symlink() and path.stat().st_size <= 16 * 1024 * 1024,
            "bounded_session_ledger")
    rows = [json.loads(row) for row in path.read_bytes().splitlines() if row.strip()]
    require(len(rows) <= 8192, "bounded_session_rows")
    return rows
