#!/usr/bin/env bash
# lib/forge-dbfs-read.py rebuilds a job log from Forgejo's DBFS tables (newest
# revision per block wins) so last-stack-forge-ci-log can read green remote-
# runner jobs whose log never moved to actions_log/
# (papercut-forge-ci-log-missing-for-remote-runner-jobs-20260923).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
READ="$ROOT/lib/forge-dbfs-read.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/forge-dbfs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

DB="$WORK/forgejo.db"
sqlite3 "$DB" <<'SQL'
CREATE TABLE dbfs_meta (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, full_path TEXT NOT NULL, block_size INTEGER NOT NULL, file_size INTEGER NOT NULL, create_timestamp INTEGER NOT NULL, modify_timestamp INTEGER NOT NULL);
CREATE TABLE dbfs_data (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, revision INTEGER NOT NULL, meta_id INTEGER NOT NULL, blob_offset INTEGER NOT NULL, blob_size INTEGER NOT NULL, blob_data BLOB NOT NULL);
INSERT INTO dbfs_meta VALUES (7, '4:actions_log/EdgeVector/fold/47/40263.log.zst', 4, 10, 0, 0);
INSERT INTO dbfs_data (revision, meta_id, blob_offset, blob_size, blob_data) VALUES
  (1, 7, 0, 0, CAST('OLD!' AS BLOB)),
  (2, 7, 0, 0, CAST('line' AS BLOB)),
  (5, 7, 4, 0, CAST(' one' AS BLOB)),
  (9, 7, 8, 0, CAST(char(10) || 'Xtrailing' AS BLOB));
INSERT INTO dbfs_meta VALUES (8, '4:actions_log/EdgeVector/fold/47/40519.log.zst', 4, 3, 0, 0);
INSERT INTO dbfs_data (revision, meta_id, blob_offset, blob_size, blob_data) VALUES (1, 8, 0, 0, CAST('abc' AS BLOB));
SQL

out="$(python3 "$READ" --db "$DB" --path EdgeVector/fold/47/40263.log.zst)"
[ "$out" = $'line one\nX' ] || fail "rebuilt log: [$out]"
set +e; python3 "$READ" --db "$DB" --path EdgeVector/fold/47/1.log.zst >/dev/null; rc=$?; set -e
[ "$rc" -eq 3 ] || fail "absent path should exit 3, got $rc"
# A LIKE wildcard in the path must not match another task's file.
set +e; python3 "$READ" --db "$DB" --path 'EdgeVector/fold/47/405_9.log.zst' >/dev/null; rc=$?; set -e
[ "$rc" -eq 3 ] || fail "underscore in the path matched as a wildcard"
grep -q 'dbfs_log "\$task_id"' "$ROOT/bin/last-stack-forge-ci-log" || fail "forge-ci-log does not use the DBFS fallback"
echo "ok last-stack-forge-dbfs-read"
