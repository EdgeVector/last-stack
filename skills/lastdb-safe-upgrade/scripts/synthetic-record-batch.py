#!/usr/bin/env python3
"""Write or verify one complete synthetic seed through the normal owner API.

The seed holds Brain and LastSecrets records only (kanban is off since
2026-10-31): one fixed brain/Reference point record, M brain records,
N brain/TagMembership rows under one bucket (the range read), and a few
lastsecrets/LastSecret records whose envelopes are fixed public test text.
"""

import argparse
import collections
import http.client
import hashlib
import json
import os
from pathlib import Path
import re
import socket
import stat
import sys

STAMP = "2026-10-12T00:00:00.000Z"
CAP = 4 * 1024 * 1024
POINT_SLUG = "synth-point-reference"
RANGE_BUCKET = "synth-tag-bucket"
SECRETS = 4
SCHEMA_NAME = re.compile(r"[0-9a-f]{64}|[a-z][a-z0-9_-]{0,63}/[A-Za-z][A-Za-z0-9_]{0,127}")
RECORD_FIELDS = {"slug": "knowledge_record_slug", "title": "knowledge_record_title",
                 "body": "knowledge_record_markdown", "status": "knowledge_record_status",
                 "tags": "knowledge_record_tag_labels", "created_at": "knowledge_record_created_at",
                 "updated_at": "knowledge_record_updated_at"}


def require(condition):
    if not condition:
        raise ValueError("synthetic seed contract refused")


def pairs(items):
    result = {}
    for key, value in items:
        require(key not in result)
        result[key] = value
    return result


def decode(raw):
    require(len(raw) <= CAP)
    return json.loads(raw.decode("utf-8", errors="strict"), object_pairs_hook=pairs,
                      parse_constant=lambda _value: require(False))


def owned_directory(path):
    info = path.lstat()
    require(stat.S_ISDIR(info.st_mode) and info.st_uid == os.getuid())
    require(stat.S_IMODE(info.st_mode) == 0o700 and path.resolve() == path)


def read_json(path):
    owned_directory(path.parent)
    before = path.lstat()
    require(stat.S_ISREG(before.st_mode) and before.st_uid == os.getuid())
    require(before.st_nlink == 1 and stat.S_IMODE(before.st_mode) == 0o600)
    require(before.st_size <= 65536)
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(metadata(os.fstat(fd)) == metadata(before))
        raw = os.read(fd, 65537)
        require(len(raw) == before.st_size)
        require(metadata(os.fstat(fd)) == metadata(before))
    finally:
        os.close(fd)
    require(metadata(path.lstat()) == metadata(before))
    return decode(raw)


def read_config(path, names_key):
    value = read_json(path)
    require(type(value) is dict and type(value.get(names_key)) in (dict, str))
    require(type(value.get("userHash")) is str and value["userHash"])
    return value


def metadata(info):
    return (info.st_uid, info.st_mode, info.st_dev, info.st_ino, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


class OwnerConnection(http.client.HTTPConnection):
    def __init__(self, path):
        super().__init__("localhost", timeout=600)
        self.path = path

    def connect(self):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(self.timeout)
        self.sock.connect(str(self.path))


def call(path, route, body):
    raw = json.dumps(body, ensure_ascii=False, separators=(",", ":")).encode()
    require(len(raw) <= CAP)
    conn = OwnerConnection(path)
    try:
        conn.request("POST", route, raw, {"Content-Type": "application/json",
                     "X-LastDB-Client": "lastdb-safe-upgrade-synthetic", "Connection": "close"})
        reply = conn.getresponse()
        payload = reply.read(CAP + 1)
        require(reply.status == 200)
        result = decode(payload)
        require(type(result) is dict and result.get("ok") is True)
        return result
    finally:
        conn.close()


def canonical(config, key):
    """The schema name or identity the app's own init pinned for one type."""
    value = config["schemaHashes"].get(key) if key else config["schemaName"]
    require(type(value) is str and SCHEMA_NAME.fullmatch(value))
    return value


def record_fields(config, schema, record):
    """Map logical record names to the schema's own fields."""
    aliases = config.get("schemaFieldAliases", {}).get(schema) or RECORD_FIELDS
    require(type(aliases) is dict and set(RECORD_FIELDS) <= set(aliases))
    return {aliases[name]: record[name] for name in RECORD_FIELDS}


def text(number):
    return "\n".join("Synthetic paragraph %d.%d: a known public seed record. Token %d."
                     % (number, i, (number * 7919 + i * 104729) % 100003) for i in range(8))


def collect(brain, secrets, cards, records):
    operations = []
    expected = collections.OrderedDict()

    def add(schema, key, fields):
        address = (schema, key[0], key[1] or "")
        require(address not in expected)
        expected[address] = fields
        operations.append({"type": "mutation", "schema": schema,
                           "fields_and_values": fields, "key_value": {"hash": key[0], "range": key[1]},
                           "mutation_type": "update", "durability": "durable"})

    def record(kind, slug, number):
        schema = canonical(brain, kind)
        fields = record_fields(brain, schema, {
            "slug": slug, "title": "Synthetic %s %d" % (kind, number), "body": text(number),
            "status": "draft" if kind == "design" else "active", "tags": [],
            "created_at": STAMP, "updated_at": STAMP})
        add(schema, (slug, None), fields)

    # The keyed point read of every probe bar.
    record("reference", POINT_SLUG, 0)
    for n in range(1, records + 1):
        kind = ("reference", "concept", "preference", "design")[n % 4]
        record(kind, "synth-%s-%d" % (kind, n), n)
    # N rows under one hash: the range read and the batch read of its keys.
    member = canonical(brain, "__tagmember__")
    for n in range(1, cards + 1):
        entry = "synth-entry-%03d" % n
        add(member, (RANGE_BUCKET, entry),
            {"tag_membership_bucket_key": RANGE_BUCKET, "tag_membership_entry_key": entry,
             "tag_label_excerpt": "synthetic", "tag_membership_copy_state_json": "{}"})
    # LastSecrets locators. The envelope is fixed public test text, not a secret.
    secret = canonical(secrets, None)
    for n in range(1, SECRETS + 1):
        slug = "synth-secret-%d" % n
        add(secret, (slug, None),
            {"secret_locator_slug": slug, "secret_display_name": "Synthetic secret %d" % n,
             "secret_provider_name": "synthetic", "secret_usage_description": "safe-upgrade probe",
             "secret_environment_name": "dev", "secret_text_envelope": "synthetic-public-envelope-%d" % n,
             "secret_created_at": STAMP, "secret_updated_at": STAMP})
    return operations, expected


def commit(args, expected):
    require(args.pid is not None and args.start_ts is not None)
    try:
        os.kill(args.pid, 0)
    except ProcessLookupError:
        pass
    else:
        require(False)
    receipt = read_json(args.home / ".shutdown_flush_ready")
    require(receipt == {"version": 1, "pid": args.pid, "start_ts": args.start_ts, "flush_ok": True})
    container = args.home.parent
    owned_directory(container)
    for mode in ("write", "verify"):
        proof = read_json(container / ".build" / ("batch-%s.out" % mode))
        require(proof == {"ok": True, "mode": mode, "cards": args.cards, "records": args.records,
                          "known_keys": len(expected), "native_batch_calls": 1})
    meta = container / "seed.meta"
    info = meta.lstat()
    require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid() and info.st_nlink == 1)
    require(stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 4096)
    fd = os.open(meta, os.O_RDONLY | os.O_NOFOLLOW)
    try:
        raw = os.read(fd, 4097)
        require(metadata(os.fstat(fd)) == metadata(info))
        os.fsync(fd)
    finally:
        os.close(fd)
    marker = container / ".complete"
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        payload = json.dumps({"version": 1, "seed_meta_sha256": hashlib.sha256(raw).hexdigest(),
                              "known_keys_verified": True, "shutdown_flush_verified": True}).encode()
        require(os.write(fd, payload) == len(payload))
        os.fsync(fd)
    finally:
        os.close(fd)
    fd = os.open(container, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def verify(path, expected):
    grouped = collections.OrderedDict()
    for (schema, hash_key, range_key), fields in expected.items():
        group = grouped.setdefault(schema, {"keys": [], "fields": set(), "expected": {}})
        group["keys"].append([hash_key, range_key])
        group["expected"][(hash_key, range_key)] = fields
        group["fields"].update(fields)
    queries = [{"schema_name": schema, "fields": sorted(group["fields"]),
                "filter": {"HashRangeKeys": group["keys"]}, "limit": len(group["keys"])}
               for schema, group in grouped.items()]
    require(0 < len(queries) <= 64)
    reply = call(path, "/api/queries/batch", {"queries": queries})
    require(reply.get("count") == len(queries) and type(reply.get("results")) is list)
    require(len(reply["results"]) == len(queries))
    for group, item in zip(grouped.values(), reply["results"]):
        require(type(item) is dict and item.get("status") == 200)
        value = item.get("response")
        require(type(value) is dict and value.get("ok") is True)
        require(type(value.get("unresolved_rows")) is int and value["unresolved_rows"] == 0)
        require(value.get("has_more") is False and value.get("next_cursor") is None)
        require(not value.get("truncated", False) and not value.get("continuation"))
        require(type(value.get("results")) is list)
        require(type(value.get("returned_count")) is int and value["returned_count"] == len(value["results"]))
        seen = set()
        for row in value["results"]:
            require(type(row) is dict and type(row.get("key")) is dict)
            key = (row["key"].get("hash"), row["key"].get("range") or "")
            require(key in group["expected"] and key not in seen)
            require(row.get("fields") == group["expected"][key])
            seen.add(key)
        require(seen == set(group["expected"]))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("write", "verify", "commit"))
    parser.add_argument("--home", required=True, type=Path)
    parser.add_argument("--cli-home", required=True, type=Path)
    parser.add_argument("--primary-home", required=True, type=Path)
    parser.add_argument("--cards", required=True, type=int)
    parser.add_argument("--records", required=True, type=int)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--start-ts", type=int)
    args = parser.parse_args()
    require(1 <= args.cards <= 64 and 1 <= args.records <= 64)
    owned_directory(args.home)
    owned_directory(args.cli_home)
    primary = args.primary_home.resolve(strict=True)
    require(args.home != primary and primary not in args.home.parents and args.home not in primary.parents)
    path = args.home / "data" / "folddb.sock"
    require(path.parent.resolve() == path.parent)
    brain = read_config(args.cli_home / ".brain" / "config.json", "schemaHashes")
    secrets = read_config(args.cli_home / ".lastsecrets" / "config.json", "schemaName")
    require(type(brain["schemaHashes"]) is dict and type(secrets["schemaName"]) is str)
    require(secrets["userHash"] == brain["userHash"])
    require(all(not cfg.get("nodeSocketPath") or Path(cfg["nodeSocketPath"]).resolve() == path
                for cfg in (secrets, brain)))
    operations, expected = collect(brain, secrets, args.cards, args.records)
    if args.mode == "commit":
        require(not path.exists())
        commit(args, expected)
        print(json.dumps({"ok": True, "mode": "commit", "native_batch_calls": 0}))
        return
    require(stat.S_ISSOCK(path.lstat().st_mode) and path.lstat().st_uid == os.getuid())
    before = metadata(path.lstat())
    if args.mode == "write":
        reply = call(path, "/api/mutations/batch", {"mutations": operations, "convergence": "sync"})
        require(type(reply.get("count")) is int and reply["count"] == len(operations))
        require(reply.get("durability") == "durable")
        require(type(reply.get("operations")) is dict and reply["operations"].get("total") == len(operations))
        require(reply.get("background_tasks_drained") is True and reply.get("convergence_pending") is False)
    else:
        verify(path, expected)
    require(metadata(path.lstat()) == before)
    print(json.dumps({"ok": True, "mode": args.mode, "cards": args.cards, "records": args.records,
                      "known_keys": len(expected), "native_batch_calls": 1}))


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, TypeError, KeyError, RecursionError, http.client.HTTPException):
        print("synthetic record batch refused; no automatic retry", file=sys.stderr)
        raise SystemExit(1)
