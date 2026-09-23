#!/usr/bin/env python3
"""Print one file from Forgejo's DBFS (sqlite), read-only.

Forgejo keeps a job log in DBFS while the task runs and moves it to
actions_log/ storage afterwards. For jobs on REMOTE runners that move does not
always happen: on 2026-09-23 every green docker-lane fold job (e.g. task 40263)
had action_task.log_in_storage = 0 and its log only in dbfs_meta/dbfs_data,
so last-stack-forge-ci-log printed NO LOG AVAILABLE
(papercut-forge-ci-log-missing-for-remote-runner-jobs-20260923).

The DBFS copy is plain text even when the name ends in .zst. Each block may
have several revisions; the newest revision per offset wins.

Usage: forge-dbfs-read.py --db <forgejo.db> --path <actions_log relative path>
Exit 0 with the bytes on stdout, 3 when the path is not in DBFS, 2 on error.
"""
import argparse
import sqlite3
import sys


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", required=True)
    ap.add_argument("--path", required=True, help="e.g. EdgeVector/fold/47/40263.log.zst")
    args = ap.parse_args()
    try:
        con = sqlite3.connect(f"file:{args.db}?mode=ro", uri=True, timeout=5)
        # dbfs_meta.full_path carries a numeric storage prefix: "4:actions_log/<path>".
        row = con.execute(
            "select id, file_size from dbfs_meta where full_path like ? escape '\\'",
            ("%:actions_log/" + args.path.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_"),),
        ).fetchone()
        if row is None:
            return 3
        meta_id, size = row
        out = bytearray()
        for offset, data in con.execute(
            """select blob_offset, blob_data from dbfs_data d
               where meta_id = ?
                 and revision = (select max(revision) from dbfs_data d2
                                 where d2.meta_id = d.meta_id and d2.blob_offset = d.blob_offset)
               order by blob_offset""",
            (meta_id,),
        ):
            end = offset + len(data)
            if len(out) < end:
                out.extend(b"\0" * (end - len(out)))
            out[offset:end] = data
        sys.stdout.buffer.write(bytes(out[:size]))
        return 0
    except sqlite3.Error as exc:
        print(f"forge-dbfs-read: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
