#!/usr/bin/env bash
# Run the refcount audit against a pre-created real-data LastDB CoW copy.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/python-cache.sh"

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
PRODUCE="$ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/produce.py"
AUDIT="$ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/audit.py"

# The release lane creates this copy with lastdb-dev. Ordinary CI has no
# real-data copy and must not make or inspect the primary home.
if [ -z "${LASTDB_REFCOUNT_AUDIT_REAL_COPY_HOME:-}" ]; then
  echo "ok last-stack-lastdb-refcount-audit-real-copy (skipped: no isolated copy)"
  exit 0
fi

WORK="$(mktemp -d /private/tmp/last-stack-refcount-real-copy.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

python3 -m py_compile "$PRODUCE" "$AUDIT"
python3 "$PRODUCE" --copy-home "$LASTDB_REFCOUNT_AUDIT_REAL_COPY_HOME" --out-dir "$WORK/input"
python3 "$AUDIT" --candidates "$WORK/input/candidates.json" \
  --reachability "$WORK/input/reachability.json" --out "$WORK/report.json"
python3 - "$WORK/input/candidates.json" "$WORK/input/reachability.json" "$WORK/report.json" <<'PY'
import json
import sys

candidates, reachability, report = [json.load(open(path, encoding="utf-8")) for path in sys.argv[1:]]
assert candidates["surface"]["kind"] == "isolated-copy", candidates
assert candidates["surface"]["copy_id"] == reachability["surface"]["copy_id"]
assert report["terminal_gate"] is False, report
for row in candidates["candidates"]:
    assert row["refcount"] == 0 and row["grace_elapsed"] is True, row
print("ok real-data refcount audit candidates=%d result=%s" % (len(candidates["candidates"]), report["result"]))
PY
