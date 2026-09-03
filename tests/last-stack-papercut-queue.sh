#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in "papercut list --status open --index-only --json"|"papercut list --status open --json") ;; *) exit 2 ;; esac
printf '%s\n' '{"event":"verb_timing","duration_ms":2,"verb":"papercut"}'
printf '%s\n' '{"rows":[{"slug":"papercut-a","status":"open"},{"slug":"papercut-b","status":"open"},{"slug":"papercut-c","status":"open"}],"total":3,"method":"method: status-keyed papercut index (one keyed partition)"}'
SH
chmod +x "$tmp/brain"

snapshot="$tmp/open.json"
out="$($ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/brain" --output "$snapshot" --json)"
printf '%s\n' "$out" | jq -e '.ok and .discovered == 3 and .phase == "snapshot"' >/dev/null
jq -e '.ok and .discovered == 3 and (.rows | length) == 3' "$snapshot" >/dev/null

printf 'papercut-a\n' >"$tmp/reconciled"
printf 'papercut-b\n' >"$tmp/deferred"
printf 'papercut-c\n' >"$tmp/already"
: >"$tmp/failed"
verified="$($ROOT/bin/last-stack-papercut-queue verify --snapshot "$snapshot" --reconciled-file "$tmp/reconciled" --deferred-file "$tmp/deferred" --already-handled-file "$tmp/already" --failed-file "$tmp/failed" --json)"
printf '%s\n' "$verified" | jq -e '.ok and .conserved and .accounted == .discovered' >/dev/null

set +e
: >"$tmp/deferred"
$ROOT/bin/last-stack-papercut-queue verify --snapshot "$snapshot" --reconciled-file "$tmp/reconciled" --deferred-file "$tmp/deferred" --already-handled-file "$tmp/already" --failed-file "$tmp/failed" --json >"$tmp/mismatch.json"
rc=$?
set -e
[ "$rc" -eq 1 ]
jq -e '.ok == false and .conserved == false and .missing == ["papercut-b"]' "$tmp/mismatch.json" >/dev/null

# Compound filer -> keyed discovery -> point hydration -> reconciliation
# accounting -> lifecycle transition. The fake owns only transport/state; the
# production helper and exact CLI shapes are exercised unchanged.
cat >"$tmp/stateful-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "papercut file")
    slug="$3"
    jq -n --arg slug "$slug" '[{slug:$slug,title:"Synthetic queue canary",status:"open",component:"test",severity:"p3",kind:"complaint"}]' >"$BRAIN_STATE.tmp"
    mv "$BRAIN_STATE.tmp" "$BRAIN_STATE"
    printf 'filed %s\n' "$slug"
    ;;
  "papercut list")
    rows="$(jq -c '[.[] | select(.status == "open")]' "$BRAIN_STATE")"
    total="$(printf '%s' "$rows" | jq 'length')"
    jq -cn --argjson rows "$rows" --argjson total "$total" \
      '{rows:$rows,total:$total,method:"method: status-keyed papercut index (canary)"}'
    ;;
  "get papercut-queue-compound-canary")
    jq -c '.[] | select(.slug == "papercut-queue-compound-canary")' "$BRAIN_STATE"
    ;;
  "papercut close")
    slug="$3"
    jq --arg slug "$slug" 'map(if .slug == $slug then .status = "fixed" else . end)' "$BRAIN_STATE" >"$BRAIN_STATE.tmp"
    mv "$BRAIN_STATE.tmp" "$BRAIN_STATE"
    printf 'closed %s\n' "$slug"
    ;;
  *)
    echo "unexpected stateful brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$tmp/stateful-brain"
export BRAIN_STATE="$tmp/brain-state.json"
printf '[]\n' >"$BRAIN_STATE"
"$tmp/stateful-brain" papercut file papercut-queue-compound-canary \
  --component test --severity p3 --kind complaint --symptom canary --title canary --body canary >/dev/null
compound_snapshot="$tmp/compound-open.json"
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/stateful-brain" --output "$compound_snapshot" --json \
  | jq -e '.discovered == 1' >/dev/null
"$tmp/stateful-brain" get papercut-queue-compound-canary --type papercut --json \
  | jq -e '.slug == "papercut-queue-compound-canary" and .status == "open"' >/dev/null
printf 'papercut-queue-compound-canary\n' >"$tmp/compound-reconciled"
: >"$tmp/compound-deferred"
: >"$tmp/compound-already"
: >"$tmp/compound-failed"
$ROOT/bin/last-stack-papercut-queue verify --snapshot "$compound_snapshot" \
  --reconciled-file "$tmp/compound-reconciled" --deferred-file "$tmp/compound-deferred" \
  --already-handled-file "$tmp/compound-already" --failed-file "$tmp/compound-failed" --json \
  | jq -e '.ok and .conserved and .reconciled == 1' >/dev/null
"$tmp/stateful-brain" papercut close papercut-queue-compound-canary \
  --status fixed --evidence canary --fixed-by canary >/dev/null
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/stateful-brain" --output "$tmp/compound-after.json" --json \
  | jq -e '.discovered == 0' >/dev/null

# First-party producers must enter through the keyed filing door. This is the
# writer half of the compound path; a legacy reference put can never appear in
# the typed open partition the snapshot proves above.
for producer in \
  routines/papercut-reconciler.md \
  routines/pipeline-health.md \
  routines/dogfood-rotate.md \
  routines/self-improvement-loop.md \
  routines/lastdb-ops-offenders.md \
  routines/disk-reclaim.md \
  skills/session-miner/SKILL.md; do
  grep -q 'brain papercut file' "$ROOT/$producer" || {
    echo "producer missing typed papercut filing door: $producer" >&2
    exit 1
  }
done

# One unprefixed live slug must not fail-close the whole snapshot
# (papercut-last-stack-queue-rejects-valid-unprefixed-typed-slugs).
cat >"$tmp/brain-mixed" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in "papercut list --status open --index-only --json"|"papercut list --status open --json") ;; *) exit 2 ;; esac
printf '%s\n' '{"rows":[{"slug":"papercut-a","status":"open"},{"slug":"brain-bare-unprefixed","status":"open"},{"slug":"papercut-b","status":"open"}],"total":3,"method":"method: status-keyed papercut index (one keyed partition)"}'
SH
chmod +x "$tmp/brain-mixed"
mixed="$tmp/mixed.json"
mixed_out="$($ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/brain-mixed" --output "$mixed" --json 2>"$tmp/mixed.err")"
printf '%s\n' "$mixed_out" | jq -e '.ok and .discovered == 2 and .quarantined == 1' >/dev/null
jq -e '.ok and .discovered == 2 and (.rows | length) == 2 and (.quarantined | length) == 1 and .quarantined[0].slug == "brain-bare-unprefixed"' "$mixed" >/dev/null
grep -q 'quarantined 1 slug' "$tmp/mixed.err"
printf 'papercut-a\n' >"$tmp/mixed-reconciled"
printf 'papercut-b\n' >"$tmp/mixed-deferred"
: >"$tmp/mixed-already"
: >"$tmp/mixed-failed"
$ROOT/bin/last-stack-papercut-queue verify --snapshot "$mixed" \
  --reconciled-file "$tmp/mixed-reconciled" --deferred-file "$tmp/mixed-deferred" \
  --already-handled-file "$tmp/mixed-already" --failed-file "$tmp/mixed-failed" --json \
  | jq -e '.ok and .conserved and .discovered == 2' >/dev/null

# An unreadable queue is rc=3 (dependency degraded), NOT rc=1 (queue invalid).
# The reconciler reports rc=3 as noop, so conflating the two makes a degraded
# brain index look like a routine defect
# (routine-error-last-stack-papercut-reconciler-20260829).
cat >"$tmp/brain-index-incomplete" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in "papercut list --status open --index-only --json"|"papercut list --status open --json") ;; *) exit 2 ;; esac
printf '%s\n' '{"error":"the status-keyed papercut index is registered but not marked complete, so the ledger cannot trust it without enumerating the whole papercut partition.","hint":"Run `fbrain reindex --papercut-status-index` (admin/offline) to rebuild the index from source of truth, then retry."}'
echo "error: the status-keyed papercut index is registered but not marked complete." >&2
exit 1
SH
chmod +x "$tmp/brain-index-incomplete"
set +e
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/brain-index-incomplete" \
  --output "$tmp/unavailable.json" --json >"$tmp/unavailable.out" 2>"$tmp/unavailable.err"
rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "expected rc=3 for an unreadable queue, got $rc" >&2; exit 1; }
jq -e '.ok == false and .reason == "status-index-incomplete" and .retryable == true and (.hint | test("reindex"))' "$tmp/unavailable.out" >/dev/null
# It must not leave a snapshot behind: a later pass would read it as membership.
[ ! -e "$tmp/unavailable.json" ] || { echo "unavailable snapshot must not be written" >&2; exit 1; }
grep -q 'papercut queue unavailable' "$tmp/unavailable.err"

# Node backpressure is the same class, not a queue defect.
cat >"$tmp/brain-busy" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in "papercut list --status open --index-only --json"|"papercut list --status open --json") ;; *) exit 2 ;; esac
echo "error: service_timeout: node did not respond within 30000ms" >&2
exit 1
SH
chmod +x "$tmp/brain-busy"
set +e
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/brain-busy" \
  --output "$tmp/busy.json" --json >"$tmp/busy.out" 2>/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || { echo "expected rc=3 for a busy node, got $rc" >&2; exit 1; }
jq -e '.ok == false and .reason == "brain-unavailable"' "$tmp/busy.out" >/dev/null

# An INVALID queue must still be rc=1. Degrading this to noop would let a lying
# instrument pass silently, which is the thing rc=3 must never buy.
cat >"$tmp/brain-bad-method" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in "papercut list --status open --index-only --json"|"papercut list --status open --json") ;; *) exit 2 ;; esac
printf '%s\n' '{"rows":[{"slug":"papercut-a","status":"open"}],"total":1,"method":"method: ranked search sample"}'
SH
chmod +x "$tmp/brain-bad-method"
set +e
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/brain-bad-method" \
  --output "$tmp/bad.json" --json >/dev/null 2>"$tmp/bad.err"
rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "expected rc=1 for an invalid queue, got $rc" >&2; exit 1; }
grep -q 'papercut queue invalid' "$tmp/bad.err"

# The routine prompt must actually carry the rc=3 -> noop rule.
grep -q 'snapshot_rc' "$ROOT/routines/papercut-reconciler.md"
grep -q 'queue_snapshot_unavailable' "$ROOT/routines/papercut-reconciler.md"

printf 'ok last-stack-papercut-queue\n'

# An installed brain that predates --index-only refuses the flag; the helper
# must fall back to the hydrated list instead of reporting the queue invalid.
cat >"$tmp/old-brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "papercut list --status open --index-only --json")
    echo "error: Unknown option '--index-only'" >&2
    exit 2
    ;;
  "papercut list --status open --json")
    printf '%s\n' '{"rows":[{"slug":"papercut-old-a","status":"open"},{"slug":"papercut-old-b","status":"open"}],"total":2,"method":"method: status-keyed papercut index with batched hydrate"}'
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/old-brain"
old_snapshot="$tmp/old-open.json"
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/old-brain" --output "$old_snapshot" --json \
  | jq -e '.ok and .discovered == 2' >/dev/null

# A node that rejects the list query at the grammar never read the queue:
# unavailable (rc=3), not "queue invalid" (rc=1), and no snapshot file.
cat >"$tmp/grammar-brain" <<'SH'
#!/usr/bin/env bash
echo "error: Node /api/query returned HTTP 400 [a key was present with a value outside its grammar]." >&2
exit 1
SH
chmod +x "$tmp/grammar-brain"
set +e
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/grammar-brain" --output "$tmp/grammar-open.json" --json >"$tmp/grammar.json"
rc=$?
set -e
[ "$rc" -eq 3 ]
jq -e '.ok == false and .reason == "brain-unavailable" and .retryable == true' "$tmp/grammar.json" >/dev/null
[ ! -e "$tmp/grammar-open.json" ]

# A list that outlives --timeout is reported as unavailable, not as a traceback.
cat >"$tmp/slow-brain" <<'SH'
#!/usr/bin/env bash
sleep 5
SH
chmod +x "$tmp/slow-brain"
set +e
$ROOT/bin/last-stack-papercut-queue snapshot --brain-bin "$tmp/slow-brain" --output "$tmp/slow-open.json" --timeout 1 --json >"$tmp/slow.json" 2>"$tmp/slow.err"
rc=$?
set -e
[ "$rc" -eq 3 ]
jq -e '.ok == false and .reason == "brain-unavailable" and (.detail | test("timed out after 1s"))' "$tmp/slow.json" >/dev/null
! grep -q Traceback "$tmp/slow.err"
[ ! -e "$tmp/slow-open.json" ]
