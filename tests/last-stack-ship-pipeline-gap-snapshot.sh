#!/usr/bin/env bash
# Smoke: snapshot script is executable and emits JSON with funnel keys when
# board tools are stubbed.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-ship-pipeline-gap-snapshot"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -f "$bin" ] || fail "missing bin"
chmod +x "$bin"
"$bin" --help >/dev/null || fail "help"

export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
export SHIP_PIPELINE_GAP_SNAPSHOT_FIXTURE=1
# Keep real helpers off PATH so factory-health/why-stopped/lastgit don't run.
mkdir -p "$tmp/bin"
command -v jq >/dev/null || fail "jq required"

cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  pickup)
    cat <<'JSON'
{"ready":2,"scanned":5,"counts":{"pickup-ready":2,"unattached-outcome":1,"human-gated":0,"blocked-on-dependency":0,"parked/non-work":0,"collision":0},
 "cards":[
  {"slug":"a","category":"pickup-ready","column":"todo"},
  {"slug":"b","category":"unattached-outcome","column":"todo","repo":"EdgeVector/fold","reason":"missing milestone linkage"},
  {"slug":"c","category":"pickup-ready","column":"doing"}
 ]}
JSON
    ;;
  milestone)
    cat <<'JSON'
[{"slug":"ms-1","state":"active","north_star":"ns-1","title":"T","proof_status":"pending"},
 {"slug":"ms-2","state":"abandoned","north_star":"ns-1","title":"X"}]
JSON
    ;;
  *) echo "unexpected $*" >&2; exit 1 ;;
esac
SH
chmod +x "$tmp/bin/kanban"

out="$("$bin" --json --quiet 2>/dev/null)" || fail "run failed"
echo "$out" | jq -e '.funnel.pickup_ready == 2 and .funnel.unattached_outcome == 1' >/dev/null \
  || fail "funnel fields: $out"
echo "$out" | jq -e '.milestones.total == 2' >/dev/null \
  || fail "milestones: $out"
echo "$out" | jq -e '.ts | length > 10' >/dev/null || fail "ts missing"

echo "ok last-stack-ship-pipeline-gap-snapshot"
