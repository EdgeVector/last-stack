#!/usr/bin/env python3
"""Private metadata handoff for an exact stopped synthetic DEV photograph."""
import argparse
import hashlib
import json
import os
import re
import select
from pathlib import Path
import stat
import sys
import time

SCHEMA = "lastdb.dev-photograph.cloud-cleanup-handoff.v1"
CLOSED_SCHEMA = "lastdb.dev-photograph.cloud-cleanup-consumer-closed.v1"
FILES = (("cow/identity.key", (0o600,), 32), ("cow/cloud_sync.json", (0o600,), None),
         ("cow/laststore_high_water.json", (0o600, 0o644), None),
         ("cow/data/.device_id", (0o600,), None),
         ("restore-credentials/identity.key", (0o600,), 32),
         ("restore-credentials/cloud_sync.json", (0o600,), None),
         ("restored/identity.key", (0o600,), 32),
         ("restored/cloud_sync.json.paused", (0o600,), None))


class Refused(Exception):
    pass


def require(value):
    if not value:
        raise Refused()


def unique(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def parse(raw):
    return json.loads(raw.decode("utf-8"), object_pairs_hook=unique,
                      parse_constant=lambda _: (_ for _ in ()).throw(Refused()))


def identity(s):
    return [s.st_uid, stat.S_IMODE(s.st_mode), s.st_nlink, s.st_dev, s.st_ino,
            s.st_size, s.st_mtime_ns, s.st_ctime_ns]


def read(path, cap=65536, modes=(0o600,)):
    require(path.is_absolute() and path == Path(os.path.realpath(path)))
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid()
            and stat.S_IMODE(before.st_mode) in modes and before.st_nlink == 1
            and 0 < before.st_size <= cap)
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK), "rb") as stream:
        require(identity(os.fstat(stream.fileno())) == identity(before))
        raw = stream.read(cap + 1)
        require(identity(os.fstat(stream.fileno())) == identity(before))
    require(identity(path.lstat()) == identity(before) and len(raw) == before.st_size)
    return raw


def directory(path):
    require(path.is_absolute() and path == Path(os.path.realpath(path)))
    s = path.lstat()
    require(stat.S_ISDIR(s.st_mode) and s.st_uid == os.getuid()
            and stat.S_IMODE(s.st_mode) == 0o700)
    return [s.st_uid, stat.S_IMODE(s.st_mode), s.st_dev, s.st_ino]


def write(path, value):
    raw = (json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode()
    require(len(raw) <= 65536 and directory(path.parent))
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    with os.fdopen(fd, "wb") as stream:
        stream.write(raw); stream.flush(); os.fsync(stream.fileno())
    require(read(path) == raw)
    fd = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    return hashlib.sha256(raw).hexdigest()


def receipt(path):
    values = {}
    for line in read(path).decode("utf-8").splitlines():
        key, sep, value = line.partition("=")
        require(sep and key not in values and value)
        values[key] = value
    require(values.get("receipt_version") == "4" and values.get("cleanup_retention") == "required"
            and values.get("cleanup_handoff") == str(path) + ".cloud-cleanup.json")
    return values


def file_metadata(root, green):
    result = {}
    for relative, modes, size in FILES:
        path = root / relative
        try:
            before = path.lstat()
        except FileNotFoundError:
            require(not green)
            result[relative] = None
            continue
        require(path == Path(os.path.realpath(path)) and stat.S_ISREG(before.st_mode)
                and before.st_uid == os.getuid() and before.st_nlink == 1
                and stat.S_IMODE(before.st_mode) in modes and 0 < before.st_size <= 65536
                and (size is None or before.st_size == size))
        # Hold the file for identity only. Never read a config, seed, or device value.
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        try:
            require(identity(os.fstat(fd)) == identity(before) == identity(path.lstat()))
            result[relative] = identity(before)
        finally:
            os.close(fd)
    return result


def owned(root):
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    base = state / "last-stack/dev-photo"
    require(root.parent == Path(os.path.realpath(base)) and root.name.startswith("photo-"))
    root_id = directory(root); home_id = directory(root / "cow"); data_id = directory(root / "cow/data")
    sentinel = root / ".lastdb-dev-photograph-owner"
    require(sentinel.is_file() and not sentinel.is_symlink())
    s = sentinel.lstat()
    require(s.st_uid == os.getuid() and stat.S_IMODE(s.st_mode) == 0o600 and s.st_nlink == 1)
    return root_id, home_id, data_id


def handoff_path(path):
    return Path(str(path) + ".cloud-cleanup.json")


def pending(path):
    raw = read(handoff_path(path)); value = parse(raw)
    require(type(value) is dict and set(value) == {"schema", "state", "receipt", "root", "home", "root_identity", "home_identity", "data_identity", "creator_pid", "candidate_stopped_and_reaped", "proof_verdict", "files", "scope", "source_git_oid", "loom_execution_id"}
            and value["schema"] == SCHEMA and value["state"] == "pending"
            and value["receipt"] == str(path) and value["candidate_stopped_and_reaped"] is True)
    return value, hashlib.sha256(raw).hexdigest()


def validate(path, green_only=True):
    value, digest = pending(path)
    require(value["proof_verdict"] in ("GREEN", "RED")
            and type(value["creator_pid"]) is int and 0 < value["creator_pid"] <= 2147483647
            and type(value["source_git_oid"]) is str
            and re.fullmatch(r"[0-9a-f]{40}", value["source_git_oid"])
            and type(value["loom_execution_id"]) is str and value["loom_execution_id"])
    green = value["proof_verdict"] == "GREEN"
    require(green or not green_only)
    if green:
        fields = receipt(path)
        require(value["home"] == fields["home"] and value["source_git_oid"] == fields["source_git_oid"]
                and value["loom_execution_id"] == fields["loom_execution_id"]
                and value["scope"] == {k: fields[k] for k in ("user_hash", "cloud_db_hash", "manifest_sha256")})
    else:
        require(value["scope"] is None)
    for key in ("root_identity", "home_identity", "data_identity"):
        require(type(value[key]) is list and len(value[key]) == 4
                and all(type(item) is int and item >= 0 for item in value[key]))
    root = Path(value["root"])
    require(value["home"] == str(root / "cow") and owned(root) == (value["root_identity"], value["home_identity"], value["data_identity"])
            and file_metadata(root, green) == value["files"])
    require(owned(root) == (value["root_identity"], value["home_identity"], value["data_identity"]))
    return value, digest


def create(args):
    root = Path(args.root); ids = owned(root)
    require(args.candidate_reaped and 0 < args.creator_pid <= 2147483647)
    path = Path(args.receipt)
    green = args.verdict == "GREEN"
    fields = receipt(path) if green else {}
    if green:
        require(fields["home"] == str(root / "cow"))
    value = {"schema": SCHEMA, "state": "pending", "receipt": str(path), "root": str(root),
             "home": str(root / "cow"), "root_identity": ids[0], "home_identity": ids[1], "data_identity": ids[2],
             "creator_pid": args.creator_pid, "candidate_stopped_and_reaped": True,
             "proof_verdict": args.verdict, "files": file_metadata(root, green),
             "scope": {k: fields[k] for k in ("user_hash", "cloud_db_hash", "manifest_sha256")} if green else None,
             "source_git_oid": fields.get("source_git_oid", args.source_git_oid),
             "loom_execution_id": fields.get("loom_execution_id", args.loom_execution_id)}
    require(re.fullmatch(r"[0-9a-f]{40}", value["source_git_oid"] or "")
            and type(value["loom_execution_id"]) is str and value["loom_execution_id"])
    require(owned(root) == ids)
    write(handoff_path(path), value)


def closure(value, digest):
    require(type(value) is dict and set(value) == {"schema", "consumer_closed", "expected_handoff_sha256", "server_closure_refs"}
            and value["schema"] == CLOSED_SCHEMA and value["consumer_closed"] is True
            and value["expected_handoff_sha256"] == digest and type(value["server_closure_refs"]) is list
            and 1 <= len(value["server_closure_refs"]) <= 16)
    seen = set()
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    proof_base = Path(os.path.realpath(state / "last-stack/proofs"))
    for ref in value["server_closure_refs"]:
        require(type(ref) is dict and set(ref) == {"path", "sha256"} and type(ref["path"]) is str
                and type(ref["sha256"]) is str and re.fullmatch(r"[0-9a-f]{64}", ref["sha256"]))
        path = Path(ref["path"])
        require(proof_base in path.parents and path.suffix in (".json", ".txt") and path not in seen)
        seen.add(path)
        require(hashlib.sha256(read(path, 2 * 1024 * 1024, (0o600, 0o644))).hexdigest() == ref["sha256"])


def fifo_assertion():
    require(stat.S_ISFIFO(os.fstat(0).st_mode))
    os.set_blocking(0, False)
    end = time.monotonic() + 20
    raw = bytearray()
    while True:
        left = end - time.monotonic()
        require(left > 0)
        ready, _, _ = select.select([0], [], [], left)
        require(ready)
        block = os.read(0, 65537 - len(raw))
        if not block:
            require(raw)
            return parse(raw)
        raw.extend(block)
        require(len(raw) <= 65536)


def release(path):
    original, digest = validate(path, green_only=False)
    assertion = fifo_assertion(); closure(assertion, digest)
    current, current_digest = validate(path, green_only=False)
    require(current == original and current_digest == digest)
    root = Path(original["root"])
    closed = {"schema": CLOSED_SCHEMA, "state": "closed", "handoff_sha256": digest,
              "consumer_attestation": assertion, "receipt": str(path), "root": str(root),
              "root_identity": original["root_identity"]}
    write(root / ".dev-photograph-cloud-cleanup-closed.json", closed)
    uid, _, device, inode = original["root_identity"]
    write(root / ".synthetic-seed-owner.json", {"version": 1, "kind": "synthetic-photograph",
        "owner_uid": uid, "device": device, "inode": inode, "creator_pid": os.getpid()})


def verify_release(root):
    ids = owned(root); closed = parse(read(root / ".dev-photograph-cloud-cleanup-closed.json"))
    require(set(closed) == {"schema", "state", "handoff_sha256", "consumer_attestation", "receipt", "root", "root_identity"}
            and closed["schema"] == CLOSED_SCHEMA and closed["state"] == "closed"
            and closed["root"] == str(root) and closed["root_identity"] == ids[0])
    original, digest = validate(Path(closed["receipt"]), green_only=False)
    require(original["root"] == str(root) and original["root_identity"] == ids[0]
            and digest == closed["handoff_sha256"])
    closure(closed["consumer_attestation"], digest)
    marker = parse(read(root / ".synthetic-seed-owner.json"))
    require(type(marker) is dict and set(marker) == {"version", "kind", "owner_uid", "device", "inode", "creator_pid"}
            and marker["version"] == 1 and type(marker["creator_pid"]) is int
            and 0 < marker["creator_pid"] <= 2147483647
            and marker["kind"] == "synthetic-photograph" and marker["owner_uid"] == ids[0][0]
            and marker["device"] == ids[0][2] and marker["inode"] == ids[0][3]
            and owned(root) == ids)


def check_home_change(path):
    state = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state")))
    base = Path(os.path.realpath(state / "last-stack/dev-photo"))
    target = Path(os.path.realpath(path))
    require(target != base and base not in target.parents and target not in base.parents)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("write-pending", "check", "release", "verify-release", "check-home-change"))
    parser.add_argument("--receipt")
    parser.add_argument("--root")
    parser.add_argument("--source-git-oid")
    parser.add_argument("--loom-execution-id")
    parser.add_argument("--creator-pid", type=int, default=0)
    parser.add_argument("--candidate-reaped", action="store_true")
    parser.add_argument("--verdict", choices=("GREEN", "RED"), default="GREEN")
    args = parser.parse_args()
    require(sys.flags.isolated and not sys.flags.optimize)
    if args.action == "write-pending":
        create(args)
    elif args.action == "check":
        validate(Path(args.receipt))
    elif args.action == "release":
        release(Path(args.receipt))
    elif args.action == "verify-release":
        verify_release(Path(args.root))
    else:
        check_home_change(args.root)
    print(json.dumps({"ok": True, "action": args.action, "credential_values_read": False,
                      "cloud_cleanup_inferred": False}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print('{"ok":false,"reason":"RETENTION_CONTRACT_REFUSED"}')
        raise SystemExit(2)
