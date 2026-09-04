#!/usr/bin/env bash
set -euo pipefail

# A HEAL-node-spawned agent exports the ambient live-loom contract
# (LOOM_LIVE=1 etc.), and `lastgit ci run` from such an agent inherits it —
# observed 2026-08-30: the stand-in assertions below went live in CI. This
# suite must exercise the stand-in paths regardless of ambient env.
unset LOOM_LIVE LOOM_CANARY_LIVE LOOM_CANARY_RED_LIVE \
  LOOM_EXEC_ID LOOM_INPUT LOOM_IDEMPOTENCY_KEY LOOM_SCRIPTS || true

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-red-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
bash -n "$ROOT/bin/last-stack-canary-red-heal-routine"
bash -n "$ROOT/lib/canary-red/loom-canary-collect.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-heal.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-retry-upgrade.sh"
bash -n "$ROOT/lib/canary-red/loom-canary-report.sh"

[ -f "$ROOT/routines/lastdb-canary-red-heal.md" ] || fail "canary-red-heal prompt missing"
grep -q 'This routine is paused' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing v2 retirement state"
grep -q 'stateless reconciler' "$ROOT/routines/lastdb-canary-red-heal.md" \
  || fail "heal prompt missing v2 reconciliation rule"

[ -f "$ROOT/lib/canary-red/canary-red-heal.json" ] || fail "lib graph missing"
python3 -c 'import json,sys; json.load(open(sys.argv[1]))' \
  "$ROOT/lib/canary-red/canary-red-heal.json" \
  || fail "lib graph is not JSON"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-red.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

# --- the gate lists from the same system that orchestrates the lane ---
LANE="$ROOT/bin/last-stack-canary-loom"
LISTER="$ROOT/bin/last-stack-loom-exec-latest"
[ -x "$LISTER" ] || fail "loom execution lister missing"

# What starts a lane execution, read from what executes, not from a comment.
lane_orch="$(grep -oE '^[^#]*[^a-zA-Z_-]?([a-z][a-z-]*) run lastdb-canary-release' "$LANE" \
  | sed -E 's/.*[^a-zA-Z_-]([a-z][a-z-]*) run lastdb-canary-release.*/\1/' | sort -u)"
[ "$lane_orch" = "loom" ] || fail "lane orchestrator is '$lane_orch', expected loom"

# What the gate lists from: the lister resolves loom's own schema over loom's
# socket. A retired `sm` read is the defect this card closes.
grep -q 'last-stack-loom-exec-latest' "$BIN" || fail "gate does not use the loom lister"
grep -q 'LoomExecution' "$LISTER" || fail "lister does not read loom's LoomExecution schema"
grep -q 'LOOM_SCHEMA_MAP' "$LISTER" || fail "lister does not read loom's schema map"
gate_orch="loom"
[ "$gate_orch" = "$lane_orch" ] \
  || fail "gate lists from '$gate_orch' but the lane runs on '$lane_orch'"

if grep -vE '^[[:space:]]*#' "$BIN" | grep -nE '(^|[^a-zA-Z_-])sm (list|get|start|show)' \
    >"$tmp/sm-hits.txt"; then
  fail "gate still reads the retired state machine: $(cat "$tmp/sm-hits.txt")"
fi

now_iso() { python3 -c 'import datetime,sys; print((datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(hours=float(sys.argv[1]))).strftime("%Y-%m-%dT%H:%M:%S.000Z"))' "$1"; }

# --- a loom execution that failed inside the window is picked by its lx id ---
cat >"$tmp/loom-list.json" <<JSON
[
  {
    "id": "lx-20200101T000000.000-1-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "2020-01-01T00:00:00.000Z"
  },
  {
    "id": "lx-20260830T030901.571-75984-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 1)"
  }
]
JSON

export LAST_STACK_CANARY_RED_STAMP="$tmp/stamp.json"
export CANARY_RED_LOOM_LIST_FILE="$tmp/loom-list.json"
# No heal execution has run for any of these reds. Keeping the fixture explicit
# stops the gate from reading the live loom node during the test.
printf '%s\n' '[]' >"$tmp/heal-empty.json"
export CANARY_RED_LOOM_HEAL_LIST_FILE="$tmp/heal-empty.json"

out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'lx-20260830T030901.571-75984-1' \
  || fail "dry-run json missing newest loom fail: $out"
printf '%s\n' "$out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("idle") is False, d
assert d.get("exec_id")=="lx-20260830T030901.571-75984-1", d'

# --- a running lane stays idle ---
cat >"$tmp/loom-idle.json" <<JSON
[{"id":"lx-20260830T031951.253-85350-1","definition_name":"lastdb-canary-release","status":"running","state":"SOAK_WAIT","updated_at":"$(now_iso 1)"}]
JSON
idle_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/loom-idle.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$idle_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="lane_busy", d'

# --- a busy lane must not hide the reds behind it ---
# A canary soak sits `waiting` for a full 24 h. On 2026-08-31 four FAILED
# canary releases idled behind one, and the gate reported `noop lane_busy`
# every hour. The heal still must not start under a live execution, but the
# backlog has to reach the fleet as an error.
cat >"$tmp/busy-masking.json" <<JSON
[
  {
    "id": "lx-20260830T140407.992-49336-1",
    "definition_name": "lastdb-canary-release",
    "status": "waiting",
    "state": "SOAK_WAIT",
    "updated_at": "$(now_iso 0.2)"
  },
  {
    "id": "lx-20260831T062355.999-25291-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 2)"
  },
  {
    "id": "lx-20260831T031319.081-31192-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 3)"
  }
]
JSON
busy_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/busy-masking.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$busy_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True, d
assert d.get("reason")=="lane_busy_masking_reds", d
assert d.get("masked")==2, d
assert d.get("exec_id")=="lx-20260830T140407.992-49336-1", d
assert d.get("oldest_failed")=="lx-20260831T031319.081-31192-1", d'
printf '%s\n' "$busy_out" | grep -q 'outcome=error detail=lane_busy_masking_reds masked=2' \
  || fail "busy lane masking reds must report outcome=error: $busy_out"

# A busy lane whose reds have all been healed is genuinely quiet.
cat >"$tmp/heal-done.json" <<JSON
[
  {"id":"h1","idempotency_key":"canary-red-lx-20260831T062355.999-25291-1","status":"succeeded"},
  {"id":"h2","idempotency_key":"canary-red-lx-20260831T031319.081-31192-1","status":"failed"}
]
JSON
quiet_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/busy-masking.json" \
  CANARY_RED_LOOM_HEAL_LIST_FILE="$tmp/heal-done.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$quiet_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="lane_busy", d
assert "masked" not in d, d
assert d.get("lane_stale") is False, d'

# --- a live lane that stops advancing must not stay a healthy noop ---
# lx-20260902T172952.304-31149-1 held status=running in state DECIDE_BUILD from
# `updated_at` 2026-09-02T22:25:22Z through 2026-09-03T09:37Z. Eleven hourly
# fires each reported `noop idle reason=lane_busy` on that same exec id, so a
# ~20 h wedge read as a quiet lane
# (papercut-canary-red-heal-fifth-consecutive-day-same-class-20260903).
cat >"$tmp/lane-wedged.json" <<JSON
[{"id":"lx-20260902T172952.304-31149-1","definition_name":"lastdb-canary-release","status":"running","state":"DECIDE_BUILD","updated_at":"$(now_iso 17)"}]
JSON
wedged_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/lane-wedged.json" \
  LAST_STACK_CANARY_RED_LOOKBACK_HOURS=24 "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$wedged_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True, d
assert d.get("reason")=="lane_stale", d
assert d.get("lane_stale") is True, d
assert d.get("exec_id")=="lx-20260902T172952.304-31149-1", d
assert d.get("state")=="DECIDE_BUILD", d
assert d.get("lane_stale_hours")==6.0, d
assert d.get("lane_age_hours") >= 16.5, d'
printf '%s\n' "$wedged_out" | grep -q 'outcome=error detail=lane_stale' \
  || fail "wedged lane must report outcome=error: $wedged_out"

# The same wedge on the live (non-dry-run) path. The gate must exit 3 so
# routinesd records `error`, not another hourly `noop`.
set +e
wedged_live="$(CANARY_RED_LOOM_LIST_FILE="$tmp/lane-wedged.json" \
  LAST_STACK_CANARY_RED_LOOKBACK_HOURS=24 \
  LAST_STACK_CANARY_RED_STAMP="$tmp/stamp-wedged.json" "$BIN" --json --quiet)"
wedged_rc=$?
set -e
[ "$wedged_rc" -eq 3 ] || fail "wedged lane must exit 3, got $wedged_rc: $wedged_live"
printf '%s\n' "$wedged_live" | grep -q 'outcome=error detail=lane_stale' \
  || fail "live wedged lane missing error trailer: $wedged_live"
python3 -c 'import json,sys
d=json.load(open(sys.argv[1]))
assert d.get("outcome")=="error", d
assert d.get("exec_id")=="lx-20260902T172952.304-31149-1", d
assert "reason=lane_stale" in (d.get("detail") or ""), d' "$tmp/stamp-wedged.json" \
  || fail "wedged lane stamp did not record the error"

# A canary soak legitimately parks for a day. It re-checks, so `updated_at`
# stays young (2.5 h observed on lx-20260830T140407.992-49336-1 after two
# days). The guard must not page on that.
cat >"$tmp/lane-soaking.json" <<JSON
[{"id":"lx-20260830T140407.992-49336-1","definition_name":"lastdb-canary-release","status":"waiting","state":"SOAK_WAIT","updated_at":"$(now_iso 2.5)"}]
JSON
soak_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/lane-soaking.json" \
  LAST_STACK_CANARY_RED_LOOKBACK_HOURS=24 "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$soak_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="lane_busy", d
assert d.get("lane_stale") is False, d'
printf '%s\n' "$soak_out" | grep -q 'outcome=noop' \
  || fail "a soaking lane must stay noop: $soak_out"

# The bar is tunable, so an operator can tighten it without a code change.
tight_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/lane-soaking.json" \
  LAST_STACK_CANARY_RED_LOOKBACK_HOURS=24 "$BIN" --dry-run --json --quiet \
  --lane-stale-hours 2)"
printf '%s\n' "$tight_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("reason")=="lane_stale", d
assert d.get("lane_stale_hours")==2.0, d'

# Masked reds name the louder problem, so they keep the reason slot. The
# staleness flag still has to travel with them.
cat >"$tmp/lane-wedged-masking.json" <<JSON
[
  {"id":"lx-20260902T172952.304-31149-1","definition_name":"lastdb-canary-release","status":"running","state":"DECIDE_BUILD","updated_at":"$(now_iso 17)"},
  {"id":"lx-20260902T031319.081-31192-1","definition_name":"lastdb-canary-release","status":"failed","state":"FAILED","updated_at":"$(now_iso 18)"}
]
JSON
both_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/lane-wedged-masking.json" \
  LAST_STACK_CANARY_RED_LOOKBACK_HOURS=24 "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$both_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("reason")=="lane_busy_masking_reds", d
assert d.get("lane_stale") is True, d
assert d.get("masked")==1, d'
printf '%s\n' "$both_out" | grep -q 'outcome=error detail=lane_busy_masking_reds' \
  || fail "masked reds must keep their own error detail: $both_out"

# --- a newer cancelled row must not mask an older failed one ---
# The lister defaults to one row, and `pick_failed` used to test only that row.
# Seven reds sat unhealed behind a single cancelled execution.
cat >"$tmp/masked.json" <<JSON
[
  {
    "id": "lx-20260830T140407.992-49336-1",
    "definition_name": "lastdb-canary-release",
    "status": "cancelled",
    "state": "CANCELLED",
    "updated_at": "$(now_iso 0.5)"
  },
  {
    "id": "lx-20260830T030901.571-75984-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 2)"
  },
  {
    "id": "lx-20260829T030901.571-75984-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 3)"
  }
]
JSON
masked_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/masked.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$masked_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("idle") is False, d
assert d.get("exec_id")=="lx-20260830T030901.571-75984-1", d
assert d.get("candidates")==2, d'

# The gate must still ask the lister for more than one row.
grep -q -- '--limit "\$LIST_LIMIT"' "$BIN" \
  || fail "gate still lists the lane without a row limit"

# --- a red whose heal already ended is skipped, not relaunched hourly ---
cat >"$tmp/heal-terminal.json" <<JSON
[
  {
    "id": "lx-20260830T040000.000-1-1",
    "definition_name": "canary-red-heal",
    "status": "failed",
    "state": "FAILED",
    "idempotency_key": "canary-red-lx-20260830T030901.571-75984-1",
    "updated_at": "$(now_iso 1)"
  }
]
JSON
healed_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/masked.json" \
  CANARY_RED_LOOM_HEAL_LIST_FILE="$tmp/heal-terminal.json" \
  "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$healed_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("ok") is True and d.get("idle") is False, d
assert d.get("exec_id")=="lx-20260829T030901.571-75984-1", d
assert d.get("skipped_healed")==["lx-20260830T030901.571-75984-1"], d'

# Every red in the window already healed to a terminal state: idle, with the
# reason named, rather than a spent key relaunched every hour.
cat >"$tmp/heal-all.json" <<JSON
[
  {
    "id": "lx-20260830T040000.000-1-1",
    "definition_name": "canary-red-heal",
    "status": "failed",
    "state": "FAILED",
    "idempotency_key": "canary-red-lx-20260830T030901.571-75984-1",
    "updated_at": "$(now_iso 1)"
  },
  {
    "id": "lx-20260830T040000.000-1-2",
    "definition_name": "canary-red-heal",
    "status": "succeeded",
    "state": "DONE",
    "idempotency_key": "canary-red-lx-20260829T030901.571-75984-1",
    "updated_at": "$(now_iso 1)"
  }
]
JSON
allhealed_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/masked.json" \
  CANARY_RED_LOOM_HEAL_LIST_FILE="$tmp/heal-all.json" \
  "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$allhealed_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="heal_already_terminal", d'

# A nonterminal heal does not block a relaunch under the same resume key.
cat >"$tmp/heal-running.json" <<JSON
[{"id":"lx-20260830T040000.000-1-1","definition_name":"canary-red-heal","status":"running","state":"HEAL","idempotency_key":"canary-red-lx-20260830T030901.571-75984-1","updated_at":"$(now_iso 1)"}]
JSON
running_heal_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/masked.json" \
  CANARY_RED_LOOM_HEAL_LIST_FILE="$tmp/heal-running.json" \
  "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$running_heal_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("exec_id")=="lx-20260830T030901.571-75984-1", d'

# --- no failed row in the window is idle, and says which row it saw ---
cat >"$tmp/green.json" <<JSON
[{"id":"lx-20260830T050000.000-1-1","definition_name":"lastdb-canary-release","status":"succeeded","state":"DONE","updated_at":"$(now_iso 1)"}]
JSON
green_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/green.json" "$BIN" --dry-run --json --quiet)"
printf '%s\n' "$green_out" | python3 -c 'import json,sys
d,_=json.JSONDecoder().raw_decode(sys.stdin.read())
assert d.get("idle") is True and d.get("reason")=="no_failed_in_window", d'

# The lister must carry the resume key, or gate 2 cannot recover one.
grep -q 'idempotency_key' "$LISTER" \
  || fail "lister drops idempotency_key from the row"

# --- an empty listing is a noop, never a fleet error ---
# Seed a stale resume key first: the gate must drop it when the listing
# has no lastdb-canary-release execution in the window.
printf '%s\n' '{"ts":"2026-09-01T12:58:48Z","status":"unavailable","exec_id":"lx-20260901T125848.060-84424-1","detail":"reason=listing_stale","key":"canary-red-lx-20260901T125848.060-84424-1","outcome":"error","engine":"loom"}' \
  >"$tmp/stamp.json"
printf '%s\n' '[]' >"$tmp/empty.json"
set +e
empty_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/empty.json" "$BIN" --dry-run --json --quiet)"
empty_rc=$?
set -e
[ "$empty_rc" -eq 0 ] || fail "empty listing must exit 0, got $empty_rc: $empty_out"
printf '%s\n' "$empty_out" | grep -q 'listing_stale' \
  || fail "empty listing missing listing_stale: $empty_out"
printf '%s\n' "$empty_out" | grep -q 'outcome=noop' \
  || fail "empty listing must report outcome=noop: $empty_out"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("outcome") == "noop", d
assert d.get("exec_id") in ("", None), d
assert d.get("key") in ("", None), d
' "$tmp/stamp.json" || fail "empty listing did not drop the stale exec key: $(cat "$tmp/stamp.json")"

# --- a listing whose newest row predates the window is also noop ---
cat >"$tmp/stale.json" <<'JSON'
[{"id":"lx-20200101T000000.000-1-1","definition_name":"lastdb-canary-release","status":"failed","state":"FAILED","updated_at":"2020-01-01T00:00:00.000Z"}]
JSON
printf '%s\n' '{"ts":"2026-09-01T12:58:48Z","status":"unavailable","exec_id":"lx-20200101T000000.000-1-1","detail":"reason=listing_stale","key":"canary-red-lx-20200101T000000.000-1-1","outcome":"error","engine":"loom"}' \
  >"$tmp/stamp.json"
set +e
stale_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/stale.json" "$BIN" --dry-run --json --quiet)"
stale_rc=$?
set -e
[ "$stale_rc" -eq 0 ] || fail "stale listing must exit 0, got $stale_rc: $stale_out"
printf '%s\n' "$stale_out" | grep -q 'listing_stale' \
  || fail "stale listing missing listing_stale: $stale_out"
printf '%s\n' "$stale_out" | grep -q 'outcome=noop' \
  || fail "stale listing must report outcome=noop: $stale_out"
printf '%s\n' "$stale_out" | grep -qv 'failed_too_old' \
  || fail "stale listing must not report the old failed_too_old idle reason: $stale_out"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("outcome") == "noop", d
assert d.get("exec_id") in ("", None), d
assert d.get("key") in ("", None), d
' "$tmp/stamp.json" || fail "stale listing did not drop the stale exec key: $(cat "$tmp/stamp.json")"

# Live (non-dry-run) empty listing: same noop, no loom needed.
printf '%s\n' '{"ts":"2026-09-01T12:58:48Z","status":"unavailable","exec_id":"lx-20260901T125848.060-84424-1","detail":"reason=listing_stale","key":"canary-red-lx-20260901T125848.060-84424-1","outcome":"error","engine":"loom"}' \
  >"$tmp/stamp.json"
set +e
live_empty_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/empty.json" "$BIN" --json --quiet --no-heal)"
live_empty_rc=$?
set -e
[ "$live_empty_rc" -eq 0 ] || fail "live empty listing must exit 0, got $live_empty_rc: $live_empty_out"
printf '%s\n' "$live_empty_out" | grep -q 'ROUTINE_RESULT outcome=noop' \
  || fail "live empty listing missing ROUTINE_RESULT outcome=noop: $live_empty_out"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("outcome") == "noop", d
assert d.get("exec_id") in ("", None), d
assert d.get("key") in ("", None), d
' "$tmp/stamp.json" || fail "live empty listing did not drop the stale exec key: $(cat "$tmp/stamp.json")"

# --- the same listing_stale exec must not remain the resume key on the next tick ---
# Live 2026-09-04: 12 hourly fires reported
# `noop idle reason=listing_stale exec=lx-20260902T215510.402-45278-1`.
# Stamp drop alone was not enough: ROUTINE_RESULT kept reprinting picked_id,
# and the 48h lister kept returning the same out-of-window row.
STALE_RESUME="lx-20260902T215510.402-45278-1"
cat >"$tmp/stale-resume.json" <<JSON
[{"id":"$STALE_RESUME","definition_name":"lastdb-canary-release","status":"failed","state":"FAILED","updated_at":"$(now_iso 36)"}]
JSON
printf '%s\n' "{\"ts\":\"2026-09-04T03:37:00Z\",\"status\":\"idle\",\"exec_id\":\"$STALE_RESUME\",\"detail\":\"reason=listing_stale\",\"key\":\"canary-red-$STALE_RESUME\",\"outcome\":\"noop\",\"engine\":\"loom\"}" \
  >"$tmp/stamp.json"
set +e
tick1_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/stale-resume.json" "$BIN" --dry-run --json --quiet)"
tick1_rc=$?
set -e
[ "$tick1_rc" -eq 0 ] || fail "listing_stale tick1 must exit 0, got $tick1_rc: $tick1_out"
printf '%s\n' "$tick1_out" | grep -q 'ROUTINE_RESULT outcome=noop detail=idle reason=listing_stale exec=' \
  || fail "listing_stale tick1 must drop exec from ROUTINE_RESULT: $tick1_out"
if printf '%s\n' "$tick1_out" | grep -E 'ROUTINE_RESULT .* exec='"$STALE_RESUME"; then
  fail "listing_stale tick1 ROUTINE_RESULT still carries the resume exec: $tick1_out"
fi
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("outcome") == "noop", d
assert d.get("exec_id") in ("", None), d
assert d.get("key") in ("", None), d
assert d.get("listing_stale_exec") == sys.argv[2], d
assert int(d.get("listing_stale_hits") or 0) == 1, d
' "$tmp/stamp.json" "$STALE_RESUME" \
  || fail "listing_stale tick1 did not drop the resume key: $(cat "$tmp/stamp.json")"

set +e
tick2_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/stale-resume.json" "$BIN" --dry-run --json --quiet)"
tick2_rc=$?
set -e
[ "$tick2_rc" -eq 0 ] || fail "listing_stale tick2 dry-run must exit 0, got $tick2_rc: $tick2_out"
printf '%s\n' "$tick2_out" | grep -q 'ROUTINE_RESULT outcome=error detail=listing_stale_expired' \
  || fail "listing_stale tick2 must page listing_stale_expired: $tick2_out"
if printf '%s\n' "$tick2_out" | grep -E 'ROUTINE_RESULT .* exec='"$STALE_RESUME"; then
  fail "listing_stale tick2 ROUTINE_RESULT restored the resume exec: $tick2_out"
fi
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("outcome") == "error", d
assert d.get("exec_id") in ("", None), d
assert d.get("key") in ("", None), d
assert d.get("listing_stale_exec") == sys.argv[2], d
assert int(d.get("listing_stale_hits") or 0) == 2, d
' "$tmp/stamp.json" "$STALE_RESUME" \
  || fail "listing_stale tick2 restored the resume key: $(cat "$tmp/stamp.json")"

set +e
tick3_out="$(CANARY_RED_LOOM_LIST_FILE="$tmp/stale-resume.json" "$BIN" --dry-run --json --quiet)"
tick3_rc=$?
set -e
[ "$tick3_rc" -eq 0 ] || fail "listing_stale tick3 must exit 0, got $tick3_rc: $tick3_out"
printf '%s\n' "$tick3_out" | grep -q 'ROUTINE_RESULT outcome=noop detail=idle reason=listing_stale exec=' \
  || fail "listing_stale tick3 must stay noop without the exec after one page: $tick3_out"
python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("outcome") == "noop", d
assert d.get("exec_id") in ("", None), d
assert d.get("key") in ("", None), d
' "$tmp/stamp.json" \
  || fail "listing_stale tick3 restored the resume key: $(cat "$tmp/stamp.json")"

# stand-in scripts (no live agent)
cat >"$tmp/get.json" <<'JSON'
{"id":"exec_test","status":"failed","state":"FAILED","inputJson":"{\"main_oid\":\"abc\"}","contextJson":"{\"source_git_oid\":\"abc\",\"version\":\"0.1\"}"}
JSON
stand="$(
  LOOM_INPUT='{"exec_id":"exec_test","max_attempts":3}' \
  CANARY_RED_SM_GET_FILE="$tmp/get.json" \
    "$ROOT/lib/canary-red/loom-canary-collect.sh"
)"
printf '%s\n' "$stand" | grep -q 'verdict":"red"' || fail "collect stand-in missing red: $stand"
printf '%s\n' "$stand" | grep -q PASS || fail "collect missing PASS"

LOOM_IDEMPOTENCY_KEY=test-key LOOM_INPUT='{"exec_id":"exec_test","attempt":0}' \
  "$ROOT/lib/canary-red/loom-canary-heal.sh" | grep -q 'stand-in' \
  || fail "heal stand-in missing"

LOOM_INPUT='{"heal_status":"stand-in","attempt":2,"max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-retry-upgrade.sh" | grep -q 'exhausted' \
  || fail "retry stand-in missing exhausted at attempt 3"

CANARY_RED_SKIP_BRAIN=1 LOOM_INPUT='{"exec_id":"exec_test","verdict":"exhausted","attempt":3,"max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-report.sh" | grep -q PASS \
  || fail "report stand-in missing PASS"

# --- no loom → exit 3 ---
set +e
HOME="$tmp" PATH="/usr/bin:/bin" LAST_STACK_CANARY_RED_STAMP="$tmp/stamp2.json" \
  CANARY_RED_LOOM_LIST_FILE="$tmp/loom-list.json" \
  "$BIN" --json --quiet --no-heal >"$tmp/noloom.out" 2>"$tmp/noloom.err"
nrc=$?
set -e
[ "$nrc" -eq 3 ] || fail "expected exit 3 without loom, got $nrc $(cat "$tmp/noloom.err")"

# --- mock loom run ---
mkdir -p "$tmp/bin"
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish) echo "published $(basename "$2" .json)"; exit 0 ;;
  run)
    cat <<'VIEW'
lx-canary-1
status: succeeded
state: DONE
context.verdict: "green"
context.heal_status: "fixed"
context.attempt: 1
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export LAST_STACK_CANARY_RED_STAMP="$tmp/stamp3.json"
export CANARY_RED_LOOM_LIST_FILE="$tmp/loom-list.json"
export LOOM_CANARY_RED_KEY="canary-red-test-key"
set +e
mout="$("$BIN" --json --quiet --no-heal)"
mrc=$?
set -e
[ "$mrc" -eq 0 ] || fail "mock loom exit $mrc: $mout"
printf '%s\n' "$mout" | grep -q '"outcome":"ok"' || fail "json missing outcome=ok: $mout"
printf '%s\n' "$mout" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $mout"
printf '%s\n' "$mout" | grep -q 'verdict=green' || fail "missing verdict=green: $mout"

# --- COLLECT reads loom, never the retired sm ---
# The fixture case above bypasses the reader entirely, which is how a COLLECT
# that shelled out to `sm get` with an `lx-*` id shipped and failed every live
# red. This exercises the reader itself.
ctmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-collect.XXXXXX")"
trap 'rm -rf "$ctmp"' EXIT
mkdir -p "$ctmp/bin"

cat >"$ctmp/bin/last-stack-loom-exec-latest" <<'SH'
#!/usr/bin/env bash
# Stub: answer --exec <lx-id> --full with a loom-shaped row.
want=""
full=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --exec) want="${2:-}"; shift 2 ;;
    --full) full=1; shift ;;
    *) shift ;;
  esac
done
[ "$full" -eq 1 ] || { echo "stub: --full not requested" >&2; exit 9; }
case "$want" in
  lx-collect-test-1)
    cat <<'JSON'
[{"id":"lx-collect-test-1","definition_name":"lastdb-canary-release","status":"failed","state":"FAILED","input_json":"{\"main_oid\":\"deadbeefcafe0001\",\"max_attempts\":3}","last_error":"graph reached a fail state","hot_context_patch_json":"{\"version\":\"0.23.3\"}","parent_execution_id":""}]
JSON
    ;;
  *) echo "[]" ;;
esac
SH
chmod 755 "$ctmp/bin/last-stack-loom-exec-latest"

# Any call to the retired orchestrator must fail the test loudly.
cat >"$ctmp/bin/sm" <<'SH'
#!/usr/bin/env bash
echo "RETIRED_SM_WAS_CALLED $*" >&2
exit 1
SH
chmod 755 "$ctmp/bin/sm"

set +e
cout="$(
  PATH="$ctmp/bin:/usr/bin:/bin" \
  LOOM_INPUT='{"exec_id":"lx-collect-test-1","max_attempts":3}' \
    "$ROOT/lib/canary-red/loom-canary-collect.sh" 2>"$ctmp/collect.err"
)"
crc=$?
set -e
[ "$crc" -eq 0 ] || fail "collect against loom exited $crc: $(cat "$ctmp/collect.err")"
grep -q RETIRED_SM_WAS_CALLED "$ctmp/collect.err" && fail "collect still shells out to sm"
printf '%s\n' "$cout" | grep -q '"verdict":"red"' || fail "collect missing red verdict: $cout"
printf '%s\n' "$cout" | grep -q 'deadbeefcafe0001' || fail "collect lost source oid: $cout"
printf '%s\n' "$cout" | grep -q PASS || fail "collect missing PASS: $cout"

# An id loom does not hold must fail loudly, not silently collect an empty row.
set +e
PATH="$ctmp/bin:/usr/bin:/bin" \
LOOM_INPUT='{"exec_id":"lx-not-a-real-exec","max_attempts":3}' \
  "$ROOT/lib/canary-red/loom-canary-collect.sh" >"$ctmp/miss.out" 2>"$ctmp/miss.err"
mrc2=$?
set -e
[ "$mrc2" -ne 0 ] || fail "collect must fail on an execution loom does not hold"
grep -q 'loom get failed' "$ctmp/miss.err" \
  || fail "missing-exec error must name the loom read: $(cat "$ctmp/miss.err")"

# The two shipped copies of the node must not drift.
cmp -s "$ROOT/lib/canary-red/loom-canary-collect.sh" \
       "$ROOT/lib/canary-loom/loom-canary-collect.sh" \
  || fail "lib/canary-red and lib/canary-loom copies of loom-canary-collect.sh differ"

# --- the probe window must clear a whole 24 h soak ---
# The lister windows on the START stamp embedded in the execution id, not on
# updated_at. A 24 h floor therefore drops a canary soak at exactly the moment
# it finishes its 24 h park. Measured 2026-08-31T16:05Z: --window-hours 24
# returned 8 rows WITHOUT the live SOAK_WAIT execution
# lx-20260830T140407.992-49336-1 (updated 13:34:44Z); --window-hours 96
# returned it. With the soak invisible the `waiting` guard never fires and the
# gate heals underneath a live lane.
wtmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-window.XXXXXX")"
trap 'rm -rf "$wtmp"' EXIT
mkdir -p "$wtmp/bin"
cp "$BIN" "$wtmp/bin/last-stack-canary-red-loom"

# Stub the lister: record every --window-hours it is asked for, answer empty.
cat >"$wtmp/bin/last-stack-loom-exec-latest" <<'SH'
#!/usr/bin/env bash
win=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --window-hours) win="${2:-}"; shift 2 ;;
    --window-hours=*) win="${1#*=}"; shift ;;
    *) shift ;;
  esac
done
[ -z "$win" ] || printf '%s\n' "$win" >>"$CANARY_WINDOW_LOG"
echo "[]"
SH
chmod 755 "$wtmp/bin/last-stack-loom-exec-latest"

: >"$wtmp/windows.txt"
# The fixture cases above export a canned listing, which bypasses the lister
# entirely. This case must reach the real call site.
unset CANARY_RED_LOOM_LIST_FILE CANARY_RED_LOOM_HEAL_LIST_FILE
set +e
CANARY_WINDOW_LOG="$wtmp/windows.txt" PATH="/usr/bin:/bin"   "$wtmp/bin/last-stack-canary-red-loom" --dry-run --json --quiet   >"$wtmp/win.out" 2>"$wtmp/win.err"
set -e

[ -s "$wtmp/windows.txt" ] || fail "lister was never asked for a window: $(cat "$wtmp/win.err")"
while IFS= read -r w; do
  [ -n "$w" ] || continue
  case "$w" in
    ''|*[!0-9]*) fail "non-numeric --window-hours: $w" ;;
  esac
  [ "$w" -ge 48 ]     || fail "probe window ${w}h cannot cover a 24h soak (need >=48)"
done <"$wtmp/windows.txt"

# A longer lookback must still widen the window, not clamp it to the floor.
: >"$wtmp/windows.txt"
set +e
CANARY_WINDOW_LOG="$wtmp/windows.txt" LAST_STACK_CANARY_RED_LOOKBACK_HOURS=36 PATH="/usr/bin:/bin"   "$wtmp/bin/last-stack-canary-red-loom" --dry-run --json --quiet \
  >"$wtmp/win2.out" 2>"$wtmp/win2.err"
set -e
[ -s "$wtmp/windows.txt" ] || fail "lister was never asked for a window at lookback=36"
head -n1 "$wtmp/windows.txt" | grep -qx '72' \
  || fail "lookback=36 must probe 72h, got $(head -n1 "$wtmp/windows.txt")"


# --- an unavailable exit must still say WHY ---
# 2026-08-31T16:36Z the hourly healer recorded `error exit 3` and nothing else.
# The run dir held one stderr line, "loom publish canary-red-heal failed", and
# the reason had been discarded by `>/dev/null 2>&1`. A manual retry published
# fine, so the cause was a busy node — but nothing in the record could
# distinguish that from a malformed graph, which never self-heals. These paths
# exit `error`, so each must print its own ROUTINE_RESULT: without one
# routinesd falls back to the exit code and stores the string "exit 3".
ptmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-publish.XXXXXX")"
trap 'rm -rf "$ptmp"' EXIT
mkdir -p "$ptmp/bin" "$ptmp/home/.local/bin"

# The gate prepends $HOME/.local/bin to PATH, so a stub only wins under a
# scratch HOME.
cat >"$ptmp/bin/loom" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) exit 0 ;;
  publish)
    echo "loom: node did not respond within 30000ms (service_timeout)" >&2
    exit 1
    ;;
  *) exit 0 ;;
esac
SH
chmod 755 "$ptmp/bin/loom"

cat >"$ptmp/one-red.json" <<JSON
[
  {
    "id": "lx-20260830T030901.571-75984-1",
    "definition_name": "lastdb-canary-release",
    "status": "failed",
    "state": "FAILED",
    "updated_at": "$(now_iso 1)"
  }
]
JSON

set +e
pub_out="$(
  HOME="$ptmp/home" \
  PATH="$ptmp/bin:/usr/bin:/bin" \
  LOOM_DEFS="$ROOT/lib/canary-red" \
  LOOM_SCRIPTS="$ROOT/lib/canary-red" \
  LAST_STACK_CANARY_RED_STAMP="$ptmp/stamp.json" \
  CANARY_RED_LOOM_LIST_FILE="$ptmp/one-red.json" \
    "$BIN" --quiet --no-heal 2>"$ptmp/pub.err"
)"
pub_rc=$?
set -e

[ "$pub_rc" -eq 3 ] || fail "publish failure must exit 3, got $pub_rc: $pub_out $(cat "$ptmp/pub.err")"
printf '%s\n' "$pub_out" | grep -q 'ROUTINE_RESULT' \
  || fail "publish failure printed no ROUTINE_RESULT (routinesd then records the bare string 'exit 3'): $pub_out"
printf '%s\n' "$pub_out" | grep -q 'outcome=error detail=publish-failed' \
  || fail "publish failure must name itself: $pub_out"
printf '%s\n' "$pub_out" | grep -q 'service_timeout' \
  || fail "publish failure must carry the reason that tells a busy node from a bad graph: $pub_out"

# The other unavailable exits carry the same contract.
grep -q 'outcome=error detail=loom-missing' "$BIN" \
  || fail "loom-missing exit prints no ROUTINE_RESULT"
grep -q 'outcome=error detail=loom-ping-failed' "$BIN" \
  || fail "loom-ping-failed exit prints no ROUTINE_RESULT"
grep -q 'outcome=error detail=defs-missing' "$BIN" \
  || fail "defs-missing exit prints no ROUTINE_RESULT"

echo "ok"
