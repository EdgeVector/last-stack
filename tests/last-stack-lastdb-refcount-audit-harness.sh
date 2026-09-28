#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)/lib/python-cache.sh"  # writable py_compile cache

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
AUDIT="$ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/audit.py"
ROUTINE="$ROOT/bin/last-stack-lastdb-refcount-audit-routine"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-refcount-audit.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

python3 -m py_compile "$AUDIT"
bash -n "$ROUTINE"

python3 - "$WORK/candidates.json" "$WORK/reachability.json" <<'PY'
import json
import sys

candidates, reachability = sys.argv[1:]
surface = {"kind": "isolated-copy", "copy_id": "cow-fixture"}
json.dump(
    {
        "schema": "lastdb-atom-refcount-grace-window-delete.v1",
        "surface": surface,
        "candidates": [{"atom_id": "residue-atom", "refcount": 0, "grace_elapsed": True}],
    },
    open(candidates, "w", encoding="utf-8"),
)
json.dump(
    {
        "schema": "lastdb-schema-root-reachability.v1",
        "surface": surface,
        "roots": {"schema_catalogs": ["schema-a"], "retention": ["history-a"], "system": ["system-a"]},
        "objects": [
            {"id": "schema-a", "references": ["protein-a"]},
            {"id": "protein-a", "references": ["live-atom"]},
            {"id": "history-a", "references": ["history-atom"]},
            {"id": "system-a", "references": ["system-atom"]},
        ],
    },
    open(reachability, "w", encoding="utf-8"),
)
PY

python3 "$AUDIT" --candidates "$WORK/candidates.json" --reachability "$WORK/reachability.json" --out "$WORK/agreement.json"
python3 - "$WORK/agreement.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["result"] == "agreement", report
assert report["terminal_gate"] is False, report
assert report["reachable_candidate_count"] == 0, report
PY

# A zero-count atom is still live through a protein sibling. The audit reports
# it but returns success, so it cannot become a terminal DONE-WHEN gate.
python3 - "$WORK/reachability.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["objects"][1]["references"].append("residue-atom")
json.dump(data, open(path, "w", encoding="utf-8"))
PY
python3 "$AUDIT" --candidates "$WORK/candidates.json" --reachability "$WORK/reachability.json" --out "$WORK/disagreement.json"
python3 - "$WORK/disagreement.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["result"] == "disagreement", report
assert report["action"] == "file-refcount-bookkeeping-bug", report
assert report["reachable_candidates"] == [{"atom_id": "residue-atom", "root_groups": ["schema_catalogs"]}], report
PY

python3 - "$WORK/candidates.json" <<'PY'
import json
import sys
path = sys.argv[1]
data = json.load(open(path, encoding="utf-8"))
data["surface"]["kind"] = "primary"
json.dump(data, open(path, "w", encoding="utf-8"))
PY
if python3 "$AUDIT" --candidates "$WORK/candidates.json" --reachability "$WORK/reachability.json"; then
  fail "the audit accepted a primary surface"
fi

prompt="$WORK/lastdb-refcount-audit.md"
printf '%s\n' '---' 'name: lastdb-refcount-audit' '---' >"$prompt"
out="$("$ROUTINE" --registry-dir "$WORK/registry" --prompt-path "$prompt" --dry-run)"
printf '%s\n' "$out" | grep -q 'FREQ=DAILY' || fail "routine has no daily schedule"
"$ROUTINE" --registry-dir "$WORK/registry" --prompt-path "$prompt"
entry="$WORK/registry/last-stack-lastdb-refcount-audit.toml"
grep -q 'status = "active"' "$entry" || fail "routine is not active"
grep -q 'BYMINUTE=15' "$entry" || fail "routine has no audit slot"

if "$ROOT/bin/last-stack-north-star-proof" --list | grep -q 'north-star-lastdb-schema-root-data-attribution'; then
  fail "the retired attribution proof remains a North Star terminal gate"
fi
test ! -e "$ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/check_contract.py" \
  || fail "the retired terminal check contract remains"

echo "ok last-stack-lastdb-refcount-audit-harness"
