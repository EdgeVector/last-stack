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
    "$bin" --json --quiet
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

printf 'ok last-stack-why-stopped-class-g-scheduler-freeze\n'
