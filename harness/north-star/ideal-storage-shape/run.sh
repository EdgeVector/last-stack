#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-ideal-storage-shape
# Validate redacted evidence produced by the CoW-first ideal-storage proof.
# This harness never starts, restarts, or mutates a LastDB node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-ideal-storage-shape
MODE="$(ns_mode)"
EVIDENCE_FILE="${LASTDB_IDEAL_STORAGE_SHAPE_PROOF_EVIDENCE_FILE:-}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

if [ -z "$EVIDENCE_FILE" ]; then
  fail "$(cat <<'EOF'
Redacted CoW-plus-dogfood evidence is required.

Set LASTDB_IDEAL_STORAGE_SHAPE_PROOF_EVIDENCE_FILE to the JSON artifact emitted
after the approved CoW proof and dogfood-Mini recheck. The evidence must contain
only refs, timestamps, booleans, counts, and plane names. Never include API
keys, credentials, user data, or paths into the primary LastDB home.
EOF
)"
fi

if [ ! -f "$EVIDENCE_FILE" ]; then
  fail "evidence file not found: $EVIDENCE_FILE"
fi

set +e
proof_out="$(python3 - "$EVIDENCE_FILE" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text())
except (OSError, json.JSONDecodeError) as exc:
    print(f"invalid evidence JSON: {exc}")
    raise SystemExit(1)

failures = []
notes = []


def require(condition, failure, success):
    if condition:
        notes.append(success)
    else:
        failures.append(failure)


surface = data.get("surface", {})
kind = surface.get("kind")
primary_mutated = surface.get("primary_mutated")
dogfood_verified = surface.get("dogfood_mini_verified")
captured_at = surface.get("captured_at")
require(
    kind == "cow" and primary_mutated is False,
    "surface must be kind=cow with primary_mutated=false",
    "CoW proof surface recorded; primary was not mutated",
)
require(
    dogfood_verified is True,
    "surface.dogfood_mini_verified must be true",
    "dogfood Mini recheck recorded",
)
require(
    isinstance(captured_at, str)
    and bool(re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2})?Z", captured_at)),
    "surface.captured_at must be an ISO-8601 UTC timestamp",
    f"evidence timestamp: {captured_at}",
)

protein = data.get("protein_plane", {})
prefixes = set(protein.get("prefixes", []))
required_prefixes = {"protein:", "molprot:", "fldprot:", "pfq:"}
require(
    protein.get("collection") == "proteins" and required_prefixes.issubset(prefixes),
    "protein_plane must route protein:/molprot:/fldprot:/pfq: to proteins",
    "all protein key families route to the proteins collection",
)
require(
    protein.get("create_member_write_fold") is True,
    "protein_plane.create_member_write_fold must be true",
    "protein create/member/write/fold persisted on CoW",
)
require(
    protein.get("legacy_tips_get") is True and protein.get("copy_verify") == "green",
    "protein tips-only dual-read and copy-verify must both be green",
    "tips-only legacy read and proteins copy-verify are green",
)
require(
    protein.get("legacy_hits") == 0,
    "protein_plane.legacy_hits must be zero after copy-verify",
    "protein-plane legacy hits are zero",
)

backup = data.get("backup_manifest", {})
mutable = backup.get("mutable_includes", [])
require(
    isinstance(mutable, list) and "proteins" in mutable,
    "backup_manifest.mutable_includes must include proteins",
    "Mutable backup includes proteins",
)

design = data.get("design", {})
decisions = set(design.get("decisions", []))
require(
    isinstance(design.get("revision"), int)
    and design["revision"] >= 3
    and {"K16", "K17", "K18"}.issubset(decisions),
    "design must be revision >=3 and include settled decisions K16/K17/K18",
    "approved design revision and K16/K17/K18 decisions recorded",
)

plane_map = data.get("plane_map", {})
require(
    plane_map.get("one_tip_home") is True
    and plane_map.get("single_indexes_home") is True
    and plane_map.get("order_log_history_adjacent") is True
    and plane_map.get("cold_ops_classified") is True,
    "plane_map must prove one tip home, one indexes home, retained order-log, and cold/ops classification",
    "ideal tip/index/history/cold plane map is green",
)
require(
    plane_map.get("collapsed_plane_legacy_hits") == 0,
    "plane_map.collapsed_plane_legacy_hits must be zero",
    "collapsed-plane legacy hits are zero",
)

status = data.get("status", {})
require(
    status.get("proteins_present") is True
    and status.get("dual_read_legacy_hits_visible") is True,
    "status must expose proteins and attributed dual-read legacy hits",
    "operator status exposes proteins and dual-read attribution",
)

fkanban = data.get("fkanban", {})
require(
    fkanban.get("protein_primary") is True
    and fkanban.get("boardcards_milestonecards_agree") is True
    and fkanban.get("dual_write_fallback") is False,
    "fkanban must be protein-primary with BoardCards/MilestoneCards agreement and dual-write fallback off",
    "fkanban protein-primary BoardCards/MilestoneCards agreement is green",
)
require(
    fkanban.get("atom_gc_tip_fold_verified") is True,
    "fkanban.atom_gc_tip_fold_verified must be true",
    "atom-GC tip-fold safety gate is green",
)

refs = data.get("refs", {})
require(
    all(isinstance(refs.get(name), str) and refs[name].strip() for name in ("fold", "fkanban")),
    "refs.fold and refs.fkanban must name the proven revisions",
    f"proven refs: fold={refs.get('fold')} fkanban={refs.get('fkanban')}",
)

serialized = json.dumps(data).lower()
for forbidden in (
    "api_key",
    "password",
    "secret",
    "session_token",
    "access_token",
    "private_key",
):
    if forbidden in serialized:
        failures.append(f"evidence contains forbidden secret-like key text: {forbidden}")

print("\n".join(f"- {note}" for note in notes))
if failures:
    print("\nFailures:")
    print("\n".join(f"- {failure}" for failure in failures))
    raise SystemExit(1)
PY
)"
proof_rc=$?
set -e

body="$(cat <<EOF
Ideal LastDB storage-shape terminal proof.

Mode: $MODE
Evidence file: $EVIDENCE_FILE

$proof_out

The harness validates redacted evidence only. Evidence collection remains the
approved CoW-first workflow; primary rollout is separate and uses
lastdb-safe-upgrade after a GREEN candidate probe.
EOF
)"

if [ "$proof_rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$body" || exit 1
  exit 1
fi

ns_write_report "$SLUG" PASS "$body"
