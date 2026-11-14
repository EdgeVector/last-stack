#!/usr/bin/env python3
"""Read the local and production recovery boundaries of a signed primary."""

import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import time
from concurrent.futures import ThreadPoolExecutor


FORMAT_FILE = "data/laststore-pack-node-v1"
FORMAT_SOURCE = "fold_db/crates/core/src/storage/format.rs"
SPOOL = "data/disk-run/accepted-v1/state.json"
PROD_TABLE = "ExememMutationLog-prod"


def require(ok, reason):
    if not ok:
        raise ValueError(reason)


def read_file(path):
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW), "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == os.getuid(), "unsafe local recovery metadata")
        raw = stream.read(1024 * 1024 + 1)
    require(len(raw) <= 1024 * 1024, "oversized local recovery metadata")
    return raw


def load(path):
    return json.loads(read_file(path))


def number(value):
    require(type(value) is int and 0 <= value < 2**64, "invalid recovery sequence")
    return value


def layout(mirror, source):
    require(re.fullmatch(r"[0-9a-f]{40}", source), "full LastDB source required")
    code = subprocess.check_output(["git", "-C", mirror, "show", f"{source}:{FORMAT_SOURCE}"],
                                   stderr=subprocess.DEVNULL, text=True, timeout=15)
    format_number = re.search(r"^pub const HOME_FORMAT: u32 = (\d+);$", code, re.M)
    marker = re.search(r'^pub const RECORD_NODE_BYTES: &\[u8\] = b("[^"]*");$', code, re.M)
    profile = re.search(r"^pub\(in crate::storage\) const RECORD_PROFILE: u16 = (\d+);$", code, re.M)
    require(format_number and marker and profile, "cannot identify the candidate disk format")
    marker = json.loads(marker[1])
    require(marker.startswith(f"format={format_number[1]}\n"), "source format marker differs")
    return marker.encode(), int(profile[1])


def compatible(home, mirror, baseline, candidate):
    old, new = (layout(mirror, source) for source in (baseline, candidate))
    if old != new or old[0] != read_file(home / FORMAT_FILE):
        raise ValueError("disk format changed: one-time logical export and import into a fresh home required")


def local(home, database):
    state = load(home / SPOOL)
    sync = home / "log-sync" / database
    cursor = number(load(sync / "session.json")["cursor"])
    prefix = number(load(sync / "prefix.json")["through"])
    head, acked, retained = (number(state[key]) for key in ("head", "acked", "retained_bytes"))
    require(state["gap"] is False and state["snapshot_required"] is False and acked <= head,
            "signed capture has a gap or requires a snapshot")
    return (head, acked, retained, prefix, cursor)


def get_item(partition, entry, projection):
    key = json.dumps({"database_id": {"S": partition}, "record_id": {"S": entry}})
    result = subprocess.run(
        ["aws", "dynamodb", "get-item", "--table-name", PROD_TABLE, "--region", "us-east-1",
         "--consistent-read", "--key", key, "--projection-expression", projection,
         "--expression-attribute-names", '{"#doc":"json"}',
         "--output", "json", "--no-cli-pager"],
        capture_output=True, timeout=15,
    )
    require(result.returncode == 0, "production recovery metadata read failed")
    return json.loads(result.stdout).get("Item", {})


def remote(database, account):
    with ThreadPoolExecutor(max_workers=2) as pool:
        head_read = pool.submit(get_item, database, "head", "delivery_seq,#doc")
        snapshot_read = pool.submit(get_item, f"{database}#snap", "native-files", "#doc")
        item = head_read.result()
        saved = json.loads(snapshot_read.result()["json"]["S"])
    meta = json.loads(item["json"]["S"])
    require(meta["database_id"] == database and meta["kind"] == "personal"
            and meta["private_scope"]["account_id"] == account, "production owner or database differs")
    head = number(meta["head"]["delivery_seq"])
    require(head == int(item["delivery_seq"]["N"]), "production head metadata differs")
    snapshot = saved["snapshot"]
    cut = number(int(snapshot["through"]))
    require(snapshot["name"] is None and re.fullmatch(r"[0-9a-f]{64}", saved["id"]) is not None
            and number(meta["trimmed_through"]) <= cut <= head and len(snapshot["files"]) == len(saved["versions"])
            and {row["destination"] for row in snapshot["files"]} == {"r2", "b2"},
            "production does not have a verified native recovery snapshot")
    return head, cut


def recovery_point(home, account, seconds, min_local, min_cloud):
    owner = load(home / "databases/registry.json")["owner"]
    database = owner["id"]
    require(owner["kind"] == "personal" and re.fullmatch(r"[0-9a-f-]{36}", database),
            "local personal database is unavailable")
    deadline = time.monotonic() + seconds
    while True:
        before = local(home, database)
        head, acked, retained, prefix, cursor = before
        if head == acked and retained == 0 and prefix == cursor:
            cloud, snapshot = remote(database, account)
            if cursor == cloud and before == local(home, database):
                require(head >= min_local and cloud >= min_cloud, "signed recovery point regressed")
                return {"database": database, "local": head, "cloud": cloud, "snapshot": snapshot}
        if time.monotonic() >= deadline:
            raise ValueError("signed upload or download cursor is behind")
        time.sleep(min(2, max(0, deadline - time.monotonic())))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    gate = sub.add_parser("format")
    gate.add_argument("home", type=Path)
    gate.add_argument("mirror", type=Path)
    gate.add_argument("baseline")
    gate.add_argument("candidate")
    written = sub.add_parser("written")
    written.add_argument("home", type=Path)
    written.add_argument("database")
    point = sub.add_parser("point")
    point.add_argument("home", type=Path)
    point.add_argument("owner")
    point.add_argument("seconds", type=int)
    point.add_argument("--min-local", type=int, default=0)
    point.add_argument("--min-cloud", type=int, default=0)
    args = parser.parse_args()
    if args.command == "format":
        compatible(args.home, args.mirror, args.baseline, args.candidate)
    elif args.command == "written":
        require(re.fullmatch(r"[0-9a-f-]{36}", args.database), "invalid database id")
        print(local(args.home, args.database)[0])
    else:
        print(json.dumps(recovery_point(args.home, args.owner, args.seconds, args.min_local, args.min_cloud)))


if __name__ == "__main__":
    try:
        main()
    except (json.JSONDecodeError, KeyError, TypeError, OSError, subprocess.SubprocessError):
        raise SystemExit("signed recovery metadata is unavailable or incomplete") from None
    except ValueError as error:
        raise SystemExit(str(error)) from None
