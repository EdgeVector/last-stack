#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "papercut list --status open --json" ] || exit 2
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

printf 'ok last-stack-papercut-queue\n'
