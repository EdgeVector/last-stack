#!/usr/bin/env python3
"""Prove that the exact candidate pair backs up to the DEV relay and restores from the phrase alone.

The proof uses a throwaway identity and generated records. It never reads the identity, the
recovery phrase or any data of the primary home.

1. `lastdb admin backup init` makes a new home and a new recovery phrase offline.
2. The candidate daemon runs on that home with LASTDB_RELAY_URL set to the DEV relay. The proof
   seeds one schema, writes records, waits until the relay confirmed every entry (acked == head),
   takes one snapshot with `lastdb backup snapshot --wait`, writes a tail, and waits again.
3. The daemon stops with a flush receipt. `lastdb backup restore` makes a fresh home from the
   phrase and the relay alone: it installs the snapshot and replays only the tail.
4. The candidate daemon runs on the restored home. Every record matches key by key, and the key
   listing of the schema has no other key.
5. Both daemons stop; the temporary directory and the phrase are deleted.

The DEV relay is the `dev.exemem_api` origin of lastdb_node/environments.json at the candidate
source commit. This follows personal_database_proof.py and personal_proof_deployed.py in
EdgeVector/lastdb, which CI runs against the same relay with a new identity and no secret.
"""

import argparse
import http.client
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import sys
import tempfile
import time

SCHEMA = "SafeUpgradeDevRestore"
FIELDS = ["id", "note"]
SYNC_SECONDS = 300
BOOT_SECONDS = 120
SEED_BATCHES = 3
SEED_BATCH_RECORDS = 10
TAIL_BATCHES = 2
TAIL_BATCH_RECORDS = 5
READ_LIMIT = 64
PHRASE = ""


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def scrub(text):
    return text.replace(PHRASE, "<phrase>") if PHRASE else text


def request(path, route, payload=None, timeout=60):
    with socket.socket(socket.AF_UNIX) as transport:
        transport.settimeout(timeout)
        transport.connect(str(path))
        body = json.dumps(payload).encode() if payload is not None else b""
        method = "POST" if payload is not None else "GET"
        headers = (f"{method} {route} HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
                   f"X-LastDB-Client: lastdb-safe-upgrade\r\n"
                   f"Content-Type: application/json\r\nContent-Length: {len(body)}\r\n\r\n")
        transport.sendall(headers.encode() + body)
        result = http.client.HTTPResponse(transport)
        result.begin()
        raw = result.read(4 * 1024 * 1024)
        require(result.status == 200, f"{route} answered HTTP {result.status}: {scrub(raw[:300].decode(errors='replace'))}")
        return json.loads(raw)


def wait(what, probe, seconds=SYNC_SECONDS):
    deadline, last = time.monotonic() + seconds, None
    while time.monotonic() < deadline:
        last = probe()
        if last:
            return last
        time.sleep(1)
    raise ValueError(f"timed out after {seconds}s waiting for {what}; last value {last!r}")


class Home:
    """One generated home and, while it runs, the candidate daemon on it."""

    def __init__(self, name, root, args, relay):
        self.name, self.args, self.relay = name, args, relay
        self.base = root / name
        self.base.mkdir(mode=0o700)
        self.home = self.base / "home"
        self.sock = root / f"{name}.sock"
        self.process = self.start_ts = self.log = None

    def cli(self, arguments, text=None, env=None, timeout=600):
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.base), "LANG": "C",
                       "FOLDDB_DISABLE_KEYCHAIN": "1", **(env or {})}
        result = subprocess.run([self.args.cli, *arguments], input=text, capture_output=True, text=True,
                                timeout=timeout, check=False, env=environment)
        require(result.returncode == 0,
                f"{self.name}: lastdb {' '.join(arguments[:2])} failed: {scrub(result.stderr[-400:])}")
        return json.loads(result.stdout[result.stdout.index("{"):]) if "{" in result.stdout else {}

    def live_env(self):
        return {"LASTDB_HOME": str(self.home), "LASTDB_SOCKET_PATH": str(self.sock)}

    def init(self):
        """A new identity and home, made offline. Returns the recovery phrase."""
        phrase_file = self.base / "recovery-phrase.txt"
        self.cli(["admin", "backup", "init", "--into", str(self.home), "--recovery-phrase-out",
                  str(phrase_file), "--env", "dev", "--json"])
        return phrase_file.read_text().strip()

    def start(self):
        environment = {"PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": str(self.base), "LANG": "C",
                       "LASTDB_ISOLATED_COPY": "1", "FOLDDB_DISABLE_KEYCHAIN": "1",
                       "LASTDB_SUPPRESS_RECOVERY_PHRASE": "1", "LASTDB_TTL_SWEEP": "0",
                       "RUST_MIN_STACK": "16777216", "LASTDB_HOME": str(self.home),
                       "LASTDB_RELAY_URL": self.relay}
        self.log = open(self.base / "node.log", "ab")
        self.process = subprocess.Popen([self.args.daemon, "--data-dir", str(self.home), "--socket-path",
                                         str(self.sock)], env=environment, stdin=subprocess.DEVNULL,
                                        stdout=self.log, stderr=self.log)
        version = subprocess.check_output([self.args.daemon, "--version"], text=True, timeout=15).split()[-1]

        def booted():
            require(self.process.poll() is None, f"{self.name}: the daemon exited before it served")
            try:
                boot = request(self.sock, "/api/system/boot-identity", timeout=5)
            except (OSError, http.client.HTTPException, ValueError):
                return None
            require(boot["pid"] == self.process.pid and boot["build"] == version, f"{self.name}: another build boots")
            return boot["process_start_ts"]

        self.start_ts = wait(f"{self.name} to serve", booted, BOOT_SECONDS)

    def stop(self):
        """SIGTERM, then the flush receipt of this exact process. A forced stop is a failure."""
        if self.process is None:
            return
        process, self.process = self.process, None
        if process.poll() is None:
            process.terminate()
        try:
            status = process.wait(timeout=150)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=10)
            raise ValueError(f"{self.name}: the daemon did not stop within 150s") from None
        finally:
            self.log.close()
        receipt = self.home / ".shutdown_flush_ready"
        require(status == 0 and json.loads(receipt.read_text()) ==
                {"version": 1, "pid": process.pid, "start_ts": self.start_ts, "flush_ok": True},
                f"{self.name}: the daemon did not prove a durable stop")

    def database(self):
        return json.loads((self.home / "databases" / "registry.json").read_text())["owner"]["id"]

    def spool(self):
        try:
            return json.loads((self.home / "data" / "disk-run" / "accepted-v1" / "state.json").read_text())
        except (OSError, ValueError):
            return None

    def synced_up(self):
        """Every accepted write is confirmed by the relay (acked == head) and no retry is saved."""
        state = self.spool()
        return (state is not None and state["head"] > 0 and state["head"] == state["acked"]
                and not (self.home / "log-sync" / self.database() / "outgoing.json").exists())

    def define_schema(self):
        request(self.sock, "/api/schemas/seed-system", {"isolated_copy": True, "schema": {
            "name": SCHEMA, "descriptive_name": SCHEMA, "source": "system_seed", "schema_type": "Hash",
            "fields": FIELDS, "record_keys": {"primary": {"kind": "hash"}, "alternates": {}},
            "field_types": dict.fromkeys(FIELDS, "String"),
            "field_descriptions": {field: "Safe upgrade DEV restore proof " + field for field in FIELDS},
            "field_versions": dict.fromkeys(FIELDS, 1)}})

    def write(self, records):
        batch = [{"schema": SCHEMA, "op": "create", "key": {"hash": key}, "record": fields}
                 for key, fields in records.items()]
        reply = request(self.sock, "/v1/write", {"mutations": batch})
        require(reply["written"] == len(batch) and len(reply["revisions"]) == len(batch)
                and all(isinstance(item, str) and item for item in reply["revisions"]), f"{self.name}: a write did not flush")

    def read_all(self, keys):
        found = {}
        for start in range(0, len(keys), READ_LIMIT):
            chunk = keys[start:start + READ_LIMIT]
            reply = request(self.sock, "/v1/read", {"reads": [
                {"schema": SCHEMA, "key": {"hash": key}, "limit": 1} for key in chunk]})
            results = reply["results"]
            require(isinstance(results, list) and len(results) == len(chunk), f"{self.name}: a read answered another shape")
            for key, item in zip(chunk, results):
                require("error" not in item and isinstance(item.get("records"), list), f"{self.name}: read of {key} failed")
                found[key] = item["records"][0]["record"] if item["records"] else None
        return found

    def listed_keys(self):
        keys, cursor = [], None
        while True:
            body = {"schema": SCHEMA, "keys_only": True, "limit": 200}
            if cursor:
                body["cursor"] = cursor
            page = request(self.sock, "/v1/read", {"reads": [body]})["results"][0]
            require("error" not in page, f"{self.name}: key listing failed")
            keys.extend(item["hash"] for item in page["keys"])
            cursor = page.get("next_cursor")
            if cursor is None:
                return sorted(keys)


def records_of(kind, count, offset):
    return {f"{kind}-{offset + n:03d}": {"id": f"{kind}-{offset + n:03d}", "note": f"{kind} record {offset + n}"}
            for n in range(count)}


def relay_origin(args):
    if args.relay_url:
        return args.relay_url.rstrip("/")
    text = subprocess.check_output(["git", "-C", args.mirror, "show", f"{args.source}:lastdb_node/environments.json"],
                                   text=True, timeout=30, stderr=subprocess.DEVNULL)
    url = json.loads(text)["environments"]["dev"]["exemem_api"]
    require(url.startswith("https://"), "the DEV relay origin is not https")
    return url.rstrip("/")


def prove(args, root, homes):
    global PHRASE
    relay = relay_origin(args)
    a, b = Home("a", root, args, relay), Home("b", root, args, relay)
    homes.extend((a, b))
    PHRASE = a.init()
    a.start()
    expected = {}
    a.define_schema()
    for _ in range(SEED_BATCHES):
        batch = records_of("seed", SEED_BATCH_RECORDS, len(expected))
        a.write(batch)
        expected.update(batch)
    wait("the relay to confirm every entry of A", a.synced_up)
    taken = a.cli(["backup", "snapshot", "--wait"], env=a.live_env())
    require(taken.get("snapshot_seq") == 1 and taken.get("uploaded_files") == taken.get("files"),
            f"the first snapshot is not complete: {sorted(taken)}")
    at_snapshot = a.spool()["head"]
    for _ in range(TAIL_BATCHES):
        batch = records_of("tail", TAIL_BATCH_RECORDS, len(expected))
        a.write(batch)
        expected.update(batch)
    wait("the relay to confirm the tail of A", a.synced_up)
    entries = a.spool()["head"]
    tail = entries - at_snapshot
    require(tail == TAIL_BATCHES, f"the tail holds {tail} entries, expected {TAIL_BATCHES}")
    original = a.database()
    a.stop()

    started = time.monotonic()
    restored = b.cli(["backup", "restore", "--recovery-phrase-stdin", "--relay-url", relay, "--into", str(b.home),
                      "--json"], text=PHRASE)
    seconds = round(time.monotonic() - started, 1)
    require(restored.get("ok") is True and len(restored.get("database_id", "")) == 64,
            "the restore did not finish")
    snapshot = restored.get("snapshot")
    require(isinstance(snapshot, dict) and snapshot.get("snapshot_seq") == 1,
            "the restore did not install the snapshot")
    require(restored.get("replayed") == tail, f"the restore replayed {restored.get('replayed')} entries, the tail is {tail}")
    b.start()
    require(b.database() == original, "the restored home has another personal database id than A")
    keys = sorted(expected)
    wait("the restored home to hold every record", lambda: b.read_all(keys) == expected)
    require(b.read_all(keys) == expected, "a restored record differs from the written record")
    require(b.listed_keys() == keys, "the restored home lists other keys than the written ones")
    b.stop()
    print(f"DEV_RESTORE_SUMMARY: relay={relay} entries={entries} snapshot_seq=1 snapshot_files={taken.get('files')} "
          f"tail={tail} keys={len(keys)} restore_seconds={seconds}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--daemon", required=True)
    parser.add_argument("--cli", required=True)
    parser.add_argument("--source", required=True, help="full candidate source commit")
    parser.add_argument("--mirror", default=os.path.expanduser("~/.cache/edgevector-git/lastdb.git"))
    parser.add_argument("--relay-url", help="override the DEV relay origin")
    args = parser.parse_args()
    root = Path(tempfile.mkdtemp(prefix="ldb-dev-restore-", dir="/private/tmp")).resolve()
    homes = []
    try:
        prove(args, root, homes)
    except (ValueError, OSError, KeyError, subprocess.SubprocessError, http.client.HTTPException) as error:
        for home in homes:
            for line in recent_warnings(home):
                print(f"{home.name} daemon: {scrub(line)}", file=sys.stderr)
        raise SystemExit(f"DEV restore proof failed: {scrub(str(error))}") from None
    finally:
        # A failure can leave a daemon running. Stop it, then delete only this run's directory.
        for home in homes:
            if home.process is not None and home.process.poll() is None:
                home.process.kill()
                home.process.wait(timeout=30)
        shutil.rmtree(root, ignore_errors=True)


def recent_warnings(home):
    try:
        lines = (home.base / "node.log").read_text(errors="replace").splitlines()
    except OSError:
        return []
    return [line[:300] for line in lines if "WARN" in line or "ERROR" in line][-15:]


if __name__ == "__main__":
    main()
