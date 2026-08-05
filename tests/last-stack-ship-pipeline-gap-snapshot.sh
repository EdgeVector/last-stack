#!/usr/bin/env bash
# Smoke: snapshot script is executable and emits JSON with funnel keys when
# board tools are stubbed. Also covers why_stopped / factory_health embed
# contract: good JSON embeds; garbage/missing → explicit error object (not bare {}).
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
# Keep real helpers off PATH so factory-health/why-stopped/lastgit don't run
# unless this test installs stubs under $tmp/bin.
mkdir -p "$tmp/bin"
command -v jq >/dev/null || fail "jq required"
command -v python3 >/dev/null || fail "python3 required"

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

# --- Case 1: helpers missing → explicit reason=missing (not bare {}) ---
out="$("$bin" --json --quiet 2>/dev/null)" || fail "run failed (missing helpers)"
echo "$out" | jq -e '.funnel.pickup_ready == 2 and .funnel.unattached_outcome == 1' >/dev/null \
  || fail "funnel fields: $out"
echo "$out" | jq -e '.milestones.total == 2' >/dev/null \
  || fail "milestones: $out"
echo "$out" | jq -e '.ts | length > 10' >/dev/null || fail "ts missing"
echo "$out" | jq -e '
  .why_stopped.reason == "missing"
  and .why_stopped.helper == "why_stopped"
  and (.why_stopped | has("error"))
' >/dev/null || fail "why_stopped missing contract: $out"
echo "$out" | jq -e '
  .factory_health.reason == "missing"
  and .factory_health.helper == "factory_health"
  and (.factory_health | has("error"))
' >/dev/null || fail "factory_health missing contract: $out"

# --- Case 2: good JSON embeds (heartbeat prefix noise + object) ---
cat >"$tmp/bin/last-stack-why-stopped" <<'SH'
#!/usr/bin/env bash
# Simulate a long-running classifier that still prints pure JSON on --json.
# Heartbeat-style noise on stderr must not break embed.
echo "why-stopped: probing..." >&2
printf '%s\n' '{"classes":"D+F","detail":"doing=8 unattached-outcome=3","actions":"closeout"}'
exit 0
SH
chmod +x "$tmp/bin/last-stack-why-stopped"

cat >"$tmp/bin/last-stack-factory-health" <<'SH'
#!/usr/bin/env bash
# factory-health prints a human heartbeat line on stdout BEFORE JSON.
echo "factory-health 2026-08-05T00:00:00Z ok alerts=0 factory=up"
printf '%s\n' '{"snapshot":{"todo":2,"doing":1},"alerts":[],"status":"ok"}'
exit 0
SH
chmod +x "$tmp/bin/last-stack-factory-health"

out="$("$bin" --json --quiet 2>/dev/null)" || fail "run failed (good JSON)"
echo "$out" | jq -e '
  .why_stopped.classes == "D+F"
  and .why_stopped.detail == "doing=8 unattached-outcome=3"
  and (.why_stopped | has("error") | not)
' >/dev/null || fail "why_stopped good embed: $out"
echo "$out" | jq -e '
  .factory_health.status == "ok"
  and .factory_health.snapshot.todo == 2
  and (.factory_health | has("error") | not)
' >/dev/null || fail "factory_health good embed: $out"

# --- Case 3: garbage stdout → reason=parse (not bare {}) ---
cat >"$tmp/bin/last-stack-why-stopped" <<'SH'
#!/usr/bin/env bash
echo "not json at all, just a line"
exit 0
SH
chmod +x "$tmp/bin/last-stack-why-stopped"

out="$("$bin" --json --quiet 2>/dev/null)" || fail "run failed (garbage)"
echo "$out" | jq -e '
  .why_stopped.reason == "parse"
  and (.why_stopped | has("error"))
  and (.why_stopped | keys | length) >= 2
' >/dev/null || fail "why_stopped parse contract: $out"
# factory_health stub still good from case 2
echo "$out" | jq -e '.factory_health.status == "ok"' >/dev/null \
  || fail "factory_health still good after why_stopped garbage: $out"

# --- Case 4: empty stdout + non-zero exit → reason=exit ---
cat >"$tmp/bin/last-stack-factory-health" <<'SH'
#!/usr/bin/env bash
exit 7
SH
chmod +x "$tmp/bin/last-stack-factory-health"

out="$("$bin" --json --quiet 2>/dev/null)" || fail "run failed (exit)"
echo "$out" | jq -e '
  .factory_health.reason == "exit"
  and (.factory_health | has("error"))
' >/dev/null || fail "factory_health exit contract: $out"

echo "ok last-stack-ship-pipeline-gap-snapshot"
