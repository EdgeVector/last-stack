#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-cloud-sync-storage-lean
WS="$(ns_edgevector_workspace)"
FOLD_DIR="${CLOUD_SYNC_STORAGE_LEAN_PROOF_FOLD_DIR:-$WS/fold}"
EVIDENCE_FILE="${CLOUD_SYNC_STORAGE_LEAN_PROOF_EVIDENCE_FILE:-}"
REF="${CLOUD_SYNC_STORAGE_LEAN_PROOF_REF:-origin/main}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

if [ -z "$EVIDENCE_FILE" ]; then
  fail "$(cat <<'EOF'
Live evidence is required for criteria 1 and 4.

Set CLOUD_SYNC_STORAGE_LEAN_PROOF_EVIDENCE_FILE to a JSON file containing
snapshot listing and storage-meter reconciliation evidence. The file must not
contain raw R2/B2 credentials; retrieve secrets only at the point of collection
with LastSecrets and persist only counts, byte totals, timestamps, and source
metadata.
EOF
)"
fi

if [ ! -f "$EVIDENCE_FILE" ]; then
  fail "evidence file not found: $EVIDENCE_FILE"
fi

if [ ! -d "$FOLD_DIR/.git" ] && [ ! -f "$FOLD_DIR/Cargo.toml" ]; then
  fail "fold checkout missing at $FOLD_DIR"
fi

if [ -d "$FOLD_DIR/.git" ]; then
  git -C "$FOLD_DIR" fetch origin main >/dev/null 2>&1 || true
  if ! git -C "$FOLD_DIR" rev-parse --verify --quiet "$REF" >/dev/null; then
    REF=HEAD
  fi
else
  REF=WORKTREE
fi

fold_read() {
  local path="$1"
  if [ "$REF" != WORKTREE ] && git -C "$FOLD_DIR" cat-file -e "$REF:$path" 2>/dev/null; then
    git -C "$FOLD_DIR" show "$REF:$path"
  elif [ -f "$FOLD_DIR/$path" ]; then
    sed -n '1,$p' "$FOLD_DIR/$path"
  else
    return 1
  fi
}

engine_tmp="$(mktemp "${TMPDIR:-/tmp}/cloud-sync-engine.XXXXXX")"
trap 'rm -f "$engine_tmp"' EXIT
if ! fold_read fold_db/crates/core/src/sync/engine.rs >"$engine_tmp"; then
  fail "missing fold source: fold_db/crates/core/src/sync/engine.rs at $REF"
fi

set +e
python_out="$(python3 - "$EVIDENCE_FILE" "$engine_tmp" <<'PY'
import json
import math
import re
import sys
from pathlib import Path

evidence_path = Path(sys.argv[1])
engine_path = Path(sys.argv[2])
data = json.loads(evidence_path.read_text())
engine = engine_path.read_text()

failures = []
notes = []

snap = data.get("snapshot_retention", {})
latest = bool(snap.get("latest_enc_present"))
snapshot_count = int(snap.get("snapshot_count", -1))
extra = int(snap.get("retention_extra_count", max(snapshot_count - 1, 0)))
source = snap.get("source", "unknown")
if not latest or snapshot_count < 1 or extra > 1:
    failures.append(
        "criterion 1: expected latest.enc plus at most one retained snapshot; "
        f"got latest={latest} snapshot_count={snapshot_count} retention_extra_count={extra}"
    )
else:
    notes.append(
        f"criterion 1 snapshot retention OK: latest.enc={latest}, "
        f"snapshot_count={snapshot_count}, retention_extra_count={extra}, source={source}"
    )

cadence_patterns = [
    r"compaction_log_ratio",
    r"last_snapshot_bytes",
    r"min[_-]?snapshot|snapshot_min|MIN[_A-Z]*SNAPSHOT|24\s*\*\s*60\s*\*\s*60",
    r"max[_-]?snapshot|snapshot_max|MAX[_A-Z]*SNAPSHOT|30\s*\*\s*24\s*\*\s*60\s*\*\s*60",
]
missing_cadence = [p for p in cadence_patterns if not re.search(p, engine, re.I)]
entry_count_only = re.search(r"(entries_since_snapshot|log_entries_since_snapshot).{0,120}(>=|>)\s*100\b", engine, re.I | re.S)
if missing_cadence or entry_count_only:
    failures.append(
        "criterion 2: compaction cadence is not proven size+time based "
        f"(missing={missing_cadence}, entry_count_only_100={bool(entry_count_only)})"
    )
else:
    notes.append("criterion 2 compaction cadence OK: size/time trigger markers present; old 100-entry trigger absent")

parallel_patterns = [
    r"FuturesUnordered",
    r"buffer_unordered",
    r"try_join_all",
    r"join_all",
    r"spawn_blocking",
    r"parallel.*replay|replay.*parallel",
]
if not any(re.search(p, engine, re.I | re.S) for p in parallel_patterns):
    failures.append("criterion 3: bootstrap replay parallelization marker missing in engine.rs")
else:
    notes.append("criterion 3 bootstrap replay OK: parallel replay marker present in engine.rs")

meter = data.get("storage_meter", {})
billing_bytes = int(meter.get("billing_row_bytes", -1))
cloud_bytes = int(meter.get("r2_b2_sum_bytes", -2))
allowed_delta = int(meter.get("allowed_delta_bytes", 0))
hard_quota = meter.get("hard_quota_enforced")
sync_rejected = meter.get("sync_rejected_for_quota")
delta = abs(billing_bytes - cloud_bytes)
if billing_bytes < 0 or cloud_bytes < 0 or delta > allowed_delta or hard_quota is not False or sync_rejected is not False:
    failures.append(
        "criterion 4: storage meter reconciliation failed "
        f"(billing={billing_bytes}, cloud={cloud_bytes}, delta={delta}, "
        f"allowed_delta={allowed_delta}, hard_quota_enforced={hard_quota}, "
        f"sync_rejected_for_quota={sync_rejected})"
    )
else:
    notes.append(
        f"criterion 4 storage meter OK: billing={billing_bytes}, cloud={cloud_bytes}, "
        f"delta={delta}, hard quota disabled, no sync rejection"
    )

print("\n".join(notes))
if failures:
    print("\nFAILURES:")
    print("\n".join(f"- {f}" for f in failures))
    raise SystemExit(1)
PY
)"
python_rc=$?
set -e

body="$(cat <<EOF
Cloud-sync storage lean proof.

Fold dir: $FOLD_DIR
Fold ref: $REF
Evidence file: $EVIDENCE_FILE

\`\`\`text
$python_out
\`\`\`
EOF
)"

if [ "$python_rc" -ne 0 ]; then
  ns_write_report "$SLUG" FAIL "$body" || exit 1
  exit 1
fi

ns_write_report "$SLUG" PASS "$body"
