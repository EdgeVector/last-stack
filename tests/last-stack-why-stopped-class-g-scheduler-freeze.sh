#!/usr/bin/env bash
# Class G: routinesd has dispatched nothing for hours.
#
# On 2026-09-29T03:50Z to 2026-10-01T15:38Z routinesd dispatched nothing across
# four daemon generations, and this helper — which already opens the heartbeat
# log for its pickup-poison grep — ran 17 minutes after the fleet came back and
# answered "no Class A-F freeze detected; factory may be idle or healthy".
#
# The cases below pin BOTH fields the verdict depends on: the age, and WHICH
# producer's lines count toward it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-why-stopped"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

chmod +x "$bin"
bash -n "$bin"

mkdir -p "$tmp/bin"
hb="$tmp/heartbeats.log"
# routinesd's own daemon log. Cases 1-5 below leave this file ABSENT on purpose:
# they exercise the heartbeat source alone, which is what a host whose daemon log
# launchd rotated away actually has. Without this seam they would read the LIVE
# /Users/<me>/.routines/daemon/routinesd.err.log, whose freshness would make
# every "must be Class G" case pass or fail on the state of the real host.
dlog="$tmp/routinesd.err.log"

cat >"$tmp/bin/heal" <<'SH'
#!/usr/bin/env bash
printf 'LAST_STACK_CLASS_A_HEAL result=ok detail=already-healthy reason=why-stopped\n'
exit 0
SH
cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
jq -n '{app:"last-stack",install_mode:"artifact",stale:false,freshness:"fresh",artifact_problem:null}'
SH
cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"ready":0,"counts":{},"cards":[]}'
SH
chmod +x "$tmp/bin/heal" "$tmp/bin/host-track" "$tmp/bin/kanban"

# A routinesd dispatch line, exactly heartbeatLine()'s shape, `age_s` seconds old.
routinesd_line() {
  local age_s="$1"
  local ts
  ts="$(AGE="$age_s" python3 -c 'import os; from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(seconds=int(os.environ["AGE"]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
  printf '%s last-stack-why-stopped ok harness=codex model=gpt-test exit=0 dur=12.3s run=/tmp/r\n' "$ts"
}

# A line from some OTHER producer, `age_s` seconds old. These share the log but
# say nothing about whether routinesd is dispatching.
other_line() {
  local age_s="$1"
  local ts
  ts="$(AGE="$age_s" python3 -c 'import os; from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(seconds=int(os.environ["AGE"]))).strftime("%Y-%m-%dT%H:%M:%SZ"))')"
  printf '%s machine-leak-scan ok soft=0 hard=0 new=0\n' "$ts"
}

run_why() {
  LASTSTACK_CLASS_A_HEAL_BIN="$tmp/bin/heal" \
  LASTSTACK_WHY_STOPPED_HOST_TRACK_BIN="$tmp/bin/host-track" \
  LASTSTACK_WHY_STOPPED_KANBAN_BIN="$tmp/bin/kanban" \
  LASTSTACK_WHY_STOPPED_NO_HEARTBEAT=1 \
  LAST_STACK_HEARTBEATS_PATH="$hb" \
  LASTSTACK_WHY_STOPPED_ROUTINESD_LOG="$dlog" \
    "$bin" --json --quiet
}

# One routinesd daemon record of the given kind, `age_s` seconds old, in
# routinesd's own JSON-lines shape.
routinesd_record() {
  local kind="$1" age_s="$2"
  local ts
  ts="$(AGE="$age_s" python3 -c 'import os; from datetime import datetime, timedelta, timezone; print((datetime.now(timezone.utc) - timedelta(seconds=int(os.environ["AGE"]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
  case "$kind" in
    tick)    printf '{"ts":"%s","kind":"tick","detail":"81 routines in_flight=0 unspawned=0 stagger=60000ms"}\n' "$ts" ;;
    dispatch) printf '{"ts":"%s","kind":"dispatch","id":"some-routine","detail":"codex/gpt-5.6-luna"}\n' "$ts" ;;
    complete) printf '{"ts":"%s","kind":"complete","id":"some-routine","detail":"exit=0 run=/tmp/r"}\n' "$ts" ;;
    coalesce) printf '{"ts":"%s","kind":"coalesce-backlog","id":"some-routine","detail":"since=2026-10-01T21:48:00.000Z"}\n' "$ts" ;;
  esac
}

classes_of() {
  printf '%s\n' "$1" | awk '/^\{/{print; exit}' | jq -r '.classes'
}
has_class_g() {
  case "+$(classes_of "$1")+" in
    *+G+*) return 0 ;;
  esac
  return 1
}

# Case 1 — the measured incident. Newest routinesd dispatch is 59h48m old.
printf '%s' "$(routinesd_line 215310)" > "$hb"
out="$(run_why)"
has_class_g "$out" || fail "a 59h48m-old last dispatch must be Class G, got: $out"
printf '%s\n' "$out" | grep -q 'scheduler freeze' \
  || fail "Class G must name the freeze in detail, got: $out"
printf '%s\n' "$out" | grep -q 'no Class A' \
  && fail "Class G must replace the healthy wording, got: $out"

# Case 2 — the field that actually decided this, with the value that makes it
# bite. The newest line in the file is TEN MINUTES old and belongs to another
# producer, while the newest routinesd dispatch is still 59h48m old. That is the
# live shape, not a contrivance: on 2026-10-01 the log carried
# `worktree-cleanup ... ok cleanup-completed reclaimed=18` and
# `north-star-rollup ... ok refreshed dashboard` minutes apart, neither with a
# harness= field, through the whole freeze. A check that read "newest line in the
# file" passes Case 1 and reports this host healthy.
#
# The masking line must be YOUNGER than the bound. An older one (the 16h shape of
# 2026-09-30) leaves the verdict unchanged and so cannot discriminate — the first
# draft of this case used 57600s and the mutation probe stayed green on it.
{ routinesd_line 215310; other_line 600; } > "$hb"
out="$(run_why)"
has_class_g "$out" || fail "a recent non-routinesd line must not refresh dispatch age, got: $out"

# Case 3 — a lull, not a freeze. 2h is inside the measured p99 (3432s is p99 over
# 18085 dispatches; gaps above 2h happened 17 times in 79 days and were all
# ordinary). Must stay silent.
printf '%s' "$(routinesd_line 7200)" > "$hb"
out="$(run_why)"
if has_class_g "$out"; then
  fail "a 2h gap is a lull, not a scheduler freeze, got: $out"
fi

# Case 4 — an empty log is "I did not look", never "nothing to see". A host that
# has never written a heartbeat must not read as frozen.
: > "$hb"
out="$(run_why)"
if has_class_g "$out"; then
  fail "an empty heartbeat log must not assert a freeze, got: $out"
fi

# Case 5 — an unparseable stamp must stay silent for the same reason.
printf 'not-a-timestamp some-routine ok harness=codex model=m exit=0 dur=1.0s run=/tmp/r\n' > "$hb"
out="$(run_why)"
if has_class_g "$out"; then
  fail "an unparseable stamp must not assert a freeze, got: $out"
fi

# ---------------------------------------------------------------------------
# Cases 6-10 pin the SOURCE of the age, which is what produced a live false
# FROZEN on 2026-10-03: the heartbeat harness= line is written only for registry
# entries that set `heartbeat_slug`, zero active entries set it, and the line
# froze 40.1h before routinesd's own records did.
# ---------------------------------------------------------------------------

# Case 6 — the measured defect. routinesd dispatched 179s ago; the heartbeat
# harness= line is 144576s old. Must be SILENT. These are the live numbers.
#
# The heartbeat fixture must carry a WRONG value, not an absent one: with an
# empty heartbeat log Case 4 already keeps Class G quiet, so the branch that
# decides this case would never be reached and a mutation probe would stay green.
printf '%s' "$(routinesd_line 144576)" > "$hb"
routinesd_record dispatch 179 > "$dlog"
out="$(run_why)"
if has_class_g "$out"; then
  fail "a fresh routinesd dispatch must outrank a 40h-stale heartbeat line, got: $out"
fi

# Case 7 — the freeze this class exists for is still caught when BOTH sources
# are stale. Newest-wins must not become never-fires.
printf '%s' "$(routinesd_line 215310)" > "$hb"
routinesd_record dispatch 215310 > "$dlog"
out="$(run_why)"
has_class_g "$out" || fail "both sources stale must still be Class G, got: $out"

# Case 8 — ticks must NEVER count. Through the measured 59h48m freeze the daemon
# kept ticking `80 routines in_flight=0` and dispatched nothing, so a matcher
# that accepted ticks would read this log as fresh forever and mask the exact
# outage Class G catches — looking healthier than the code it replaced.
#
# Again a wrong value, not an absent one: the ticks here are 10s old, well inside
# the bound, so accepting them flips the verdict.
{ routinesd_record dispatch 215310; routinesd_record tick 30; routinesd_record tick 10; } > "$dlog"
printf '%s' "$(routinesd_line 215310)" > "$hb"
out="$(run_why)"
has_class_g "$out" || fail "fresh ticks must not refresh dispatch age, got: $out"

# Case 9 — `coalesce-backlog` is a backlog note, not a dispatch, and is excluded
# for the same reason as a tick. It is written when the daemon NOTICES overdue
# work, which is exactly what a wedged scheduler keeps doing.
{ routinesd_record dispatch 215310; routinesd_record coalesce 10; } > "$dlog"
printf '%s' "$(routinesd_line 215310)" > "$hb"
out="$(run_why)"
has_class_g "$out" || fail "a fresh coalesce-backlog note must not refresh dispatch age, got: $out"

# Case 10 — `complete` counts. It is written per finished dispatch and is the
# newest record on a healthy host between dispatches, so excluding it would
# report a freeze in every ordinary gap.
printf '%s' "$(routinesd_line 215310)" > "$hb"
routinesd_record complete 200 > "$dlog"
out="$(run_why)"
if has_class_g "$out"; then
  fail "a fresh complete record must count as dispatch liveness, got: $out"
fi

# Case 11 — the verdict must name which source it came from. Two passes that
# disagree about this host are otherwise indistinguishable, and the whole defect
# above was one source being read as if it were the other.
printf '%s' "$(routinesd_line 215310)" > "$hb"
routinesd_record dispatch 215310 > "$dlog"
out="$(run_why)"
printf '%s\n' "$out" | grep -q 'newest source routinesd.err.log' \
  || fail "Class G must name the source its age came from, got: $out"

printf 'ok last-stack-why-stopped-class-g-scheduler-freeze\n'
