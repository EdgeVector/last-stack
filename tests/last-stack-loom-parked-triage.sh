#!/usr/bin/env bash
# Regression cover for last-stack-loom-parked-triage.
#
# One sweep holds every shape, so a rule that swallows everything (or
# nothing) fails: two walks must be signalled, three must stay parked.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$ROOT/bin/last-stack-loom-parked-triage"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/loom-parked-triage-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
stub="$tmp/stub"
mkdir -p "$stub"
export LAST_STACK_LOOM_TRIAGE_STATE="$tmp/state"
export CALLS="$tmp/calls"
: >"$CALLS"

cat >"$stub/loom" <<'EOF'
#!/usr/bin/env bash
echo "loom $*" >>"$CALLS"
case "$1" in
  list)
    printf '%s\n' \
      "t	lx-stall	parked	AWAIT_HUMAN	land-card" \
      "t	lx-merged	parked	AWAIT_HUMAN	land-card" \
      "t	lx-normal	parked	AWAIT_HUMAN	land-card" \
      "t	lx-other	parked	AWAIT_HUMAN	land-card" \
      "t	lx-running	running	WAIT_CI	land-card" \
      "t	lx-unreadable	parked	AWAIT_HUMAN	land-card"
    ;;
  show)
    case "$2" in
      lx-stall) cat <<'V'
lx-stall
status: parked
state: AWAIT_HUMAN
error: node `REVISE` exited Exited(2): SessionEnd hook failed: Hook cancelled
loom-card-revise: reviser produced no commit
context.card: "card-stall"
context.card_difficulty: "fast"
context.park_reason: "node error"
context.pr_url: "http://forge.test/EdgeVector/fold/pulls/1"
node REVISE#3 failed: -
V
      ;;
      lx-merged) cat <<'V'
lx-merged
status: parked
state: AWAIT_HUMAN
context.card: "card-merged"
context.card_difficulty: "fast"
context.park_reason: "review escalated at cap"
context.pr_url: "http://forge.test/EdgeVector/routines/pulls/36"
V
      ;;
      lx-normal) cat <<'V'
lx-normal
status: parked
state: AWAIT_HUMAN
error: loom-card-revise: reviser produced no commit
context.card: "card-normal"
context.card_difficulty: "normal"
context.pr_url: "http://forge.test/EdgeVector/fold/pulls/3"
V
      ;;
      lx-other) cat <<'V'
lx-other
status: parked
state: AWAIT_HUMAN
error: node `BRIEF` exited Exited(1): iconv
context.card: "card-other"
context.card_difficulty: "fast"
context.pr_url: "http://forge.test/EdgeVector/fold/pulls/4"
V
      ;;
      *) echo "no such execution" >&2; exit 1 ;;
    esac
    ;;
  signal) echo "signal-ran $2 $5" >>"$CALLS" ;;
esac
EOF
cat >"$stub/forge-api" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  */routines/pulls/36) echo true ;;
  *) echo false ;;
esac
EOF
cat >"$stub/kanban" <<'EOF'
#!/usr/bin/env bash
echo "kanban $*" >>"$CALLS"
EOF
chmod +x "$stub"/*
export LOOM_BIN="$stub/loom" KANBAN_BIN="$stub/kanban" FORGE_API_BIN="$stub/forge-api"

fail() { echo "FAIL: $*" >&2; cat "$CALLS" >&2; exit 1; }

# Dry run: classifies, signals nothing, writes no state.
out="$("$bin")"
tail -1 <<<"$out" | grep -qx 'parked_seen=5 escalated=1 resumed=1 left=2 errors=1' || fail "dry-run counts: $out"
grep -q '^escalate	lx-stall	card-stall' <<<"$out" || fail "stall not escalated"
grep -q '^resume	lx-merged	card-merged' <<<"$out" || fail "merged not resumed"
grep -q '^left	lx-normal' <<<"$out" || fail "normal walk must stay parked"
grep -q '^left	lx-other' <<<"$out" || fail "unknown park must stay parked"
grep -q 'signal' "$CALLS" && fail "dry run signalled"
[ ! -e "$tmp/state/state.json" ] || fail "dry run wrote state"

# Apply: exactly two detached signals with the right payloads, one mark each.
"$bin" --apply >/dev/null
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [ "$(grep -c '^signal-ran' "$CALLS")" -ge 2 ] && break
  sleep 0.5
done
grep -q '^loom signal lx-stall card-decision --payload {"human_decision": "retry", "card_difficulty": "normal", "triage_escalated": true}' "$CALLS" \
  || fail "escalate payload"
grep -q '^loom signal lx-merged card-decision --payload {"human_decision": "merge"}' "$CALLS" || fail "resume payload"
[ "$(grep -c '^loom signal' "$CALLS")" -eq 2 ] || fail "signal count"
[ "$(grep -c '^kanban mark' "$CALLS")" -eq 2 ] || fail "mark count"

# Second apply: escalation is once per walk; resume is rate-limited.
: >"$CALLS"
out="$("$bin" --apply)"
tail -1 <<<"$out" | grep -qx 'parked_seen=5 escalated=0 resumed=0 left=4 errors=1' || fail "second pass counts: $out"
sleep 1
grep -q '^loom signal' "$CALLS" && fail "second pass signalled again"

# Gate form: applies, prints the routinesd trailer, exits 0.
out="$("$bin" --gate)" || fail "gate exit"
grep -q '^ROUTINE_RESULT outcome=noop detail=parked_seen=5,escalated=0' <<<"$out" || fail "gate trailer: $out"

echo "ok: loom parked triage escalates once, resumes merged, leaves the rest"
