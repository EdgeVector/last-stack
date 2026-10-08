#!/usr/bin/env bash
# Fixture tests for the safe-upgrade hard-delete bar.
# A fake `kanban` and a fake `curl` stand in for the candidate copy. This test
# does not start lastdbd and does not read or write the primary home. The
# status shape is the one lastdbd serves on /api/status
# (.status.resident.persist_lane_failures, .deferred_persist_failed).
#
# Run one case: bash tests/last-stack-lastdb-safe-upgrade-hard-delete-bar.sh <n>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPTS="$ROOT/skills/lastdb-safe-upgrade/scripts"
CHECKS="$SCRIPTS/hard-delete-bar-checks.sh"
DRIVER="$SCRIPTS/safe-upgrade-lastdb.sh"
ONLY="${1:-}"

[ -f "$CHECKS" ] || { echo "FAIL: missing $CHECKS" >&2; exit 1; }
bash -n "$CHECKS"
bash -n "$DRIVER"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/probe-copy-guards.sh
. "$SCRIPTS/probe-copy-guards.sh"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/deadline.sh
. "$SCRIPTS/deadline.sh"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/hard-delete-bar-checks.sh
. "$CHECKS"

fail() { echo "FAIL: $*" >&2; exit 1; }
want() { [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }
log() { printf '[test] %s\n' "$*"; }
warn() { printf '[test] WARN: %s\n' "$*" >&2; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/hard-delete-bar.XXXXXX")"
SLEEPER=""
cleanup() {
  [ -z "$SLEEPER" ] || kill "$SLEEPER" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# The primary home is a fixture dir. The copy is a sibling, never inside it.
PRIMARY_HOME="$TMP/primary"
mkdir -p "$PRIMARY_HOME/data"
# shellcheck disable=SC2034 # read by hard-delete-bar-checks.sh
HARD_DELETE_BAR_SECS=2
# shellcheck disable=SC2034
HARD_DELETE_BAR_POLL_SECS=0
# shellcheck disable=SC2034
HARD_DELETE_BAR_MIN_SECS=0

# Fake CLIs. The fake kanban keeps cards as files under $FAKE_STATE and
# records the socket it was given, so the test can prove the copy route.
FAKE_BIN="$TMP/bin"
mkdir -p "$FAKE_BIN"
cat >"$FAKE_BIN/kanban" <<'EOF_KANBAN'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FOLDDB_SOCKET_PATH:-unset}" >>"$FAKE_STATE/sockets"
verb="$1"; slug="${2:-}"
case "$verb" in
  add)
    [ "${FAKE_ADD_FAIL:-0}" = "1" ] && { echo "kanban: add refused" >&2; exit 3; }
    : >"$FAKE_STATE/card-$slug"; exit 0 ;;
  show)
    if [ -f "$FAKE_STATE/card-$slug" ]; then echo "$slug"; exit 0; fi
    echo "kanban: No card with slug \"$slug\"." >&2; exit 1 ;;
  rm)
    [ "${FAKE_RM_TIMEOUT:-0}" = "1" ] && { echo "private probe error text" >&2; exit 124; }
    [ "${FAKE_RM_FAIL:-0}" = "1" ] && { echo "kanban: persist lane rejected" >&2; exit 4; }
    [ "${FAKE_RM_KEEP:-0}" = "1" ] && exit 0
    rm -f "$FAKE_STATE/card-$slug"; exit 0 ;;
esac
exit 2
EOF_KANBAN
# The fake curl serves status-N.json in turn and repeats the last one.
cat >"$FAKE_BIN/curl" <<'EOF_CURL'
#!/usr/bin/env bash
set -u
n="$(cat "$FAKE_STATE/curl-n" 2>/dev/null || echo 0)"
n=$((n + 1))
printf '%s\n' "$n" >"$FAKE_STATE/curl-n"
f="$FAKE_STATE/status-$n.json"
[ -f "$f" ] || f="$(ls "$FAKE_STATE"/status-*.json | sort | tail -1)"
cat "$f"
EOF_CURL
chmod +x "$FAKE_BIN/kanban" "$FAKE_BIN/curl"
export PATH="$FAKE_BIN:$PATH"

sleep 300 &
SLEEPER=$!

# status <file> <persist_lane_failures|-> <deferred_persist_failed|->
status() {
  jq -n --arg p "$2" --arg d "$3" '
    def opt($k; $v): if $v == "-" then {} else {($k): ($v | tonumber)} end;
    {ok: true, status: {resident: (
      {persist_lane_depth: 0}
      + opt("persist_lane_failures"; $p)
      + opt("deferred_persist_failed"; $d))}}' >"$1"
}

# run_case <name>, then one "plf:dpf" pair per status sample served.
# Sets OUT (eval line) and RC (eval rc).
run_case() {
  local name="$1" i=0 pair copy
  shift
  export FAKE_STATE="$TMP/$name/state"
  mkdir -p "$FAKE_STATE"
  for pair in "$@"; do
    i=$((i + 1))
    status "$FAKE_STATE/status-$i.json" "${pair%%:*}" "${pair#*:}"
  done
  copy="$TMP/$name/mp-c-1"
  mkdir -p "$copy/data"
  probe_hard_delete_bar "$copy" "$copy/data/folddb.sock" "$SLEEPER" "$TMP/$name.json" >"$TMP/$name.probe.log" 2>&1 \
    || fail "case $name: probe_hard_delete_bar must return 0 and leave the verdict to the proof"
  set +e
  OUT="$(hard_delete_bar_eval "$TMP/$name.json" 2>&1)"
  RC=$?
  set -e
}

expect() {
  local name="$1" verdict="$2" pat="$3"
  if [ "$verdict" = green ]; then
    [ "$RC" -eq 0 ] || fail "case $name: must be GREEN; out=$OUT"
  else
    [ "$RC" -ne 0 ] || fail "case $name: must be RED; out=$OUT"
  fi
  printf '%s\n' "$OUT" | grep -q -- "$pat" || fail "case $name: output lacks '$pat'; out=$OUT"
}

# 1. GREEN: write, hard delete, and two clean samples. Every kanban call went
#    to the copy socket, never to the primary socket.
if want 1; then
  run_case 1 0:0 0:0
  expect 1 green 'hard-delete bar GREEN: slug=lastdb-safe-upgrade-hard-delete-probe-'
  grep -q "$TMP/1/mp-c-1/data/folddb.sock" "$TMP/1/state/sockets" || fail "case 1: kanban did not get the copy socket"
  if grep -v -x "$TMP/1/mp-c-1/data/folddb.sock" "$TMP/1/state/sockets" | grep -q .; then
    fail "case 1: a kanban call used a socket other than the copy socket"
  fi
  [ ! -e "$TMP/1/state/card-lastdb-safe-upgrade-hard-delete-probe-$$" ] || fail "case 1: the scratch card is still on the copy"
  grep -q 'hard-delete bar: stage=show-after rc=1 elapsed_s=[0-9]*' "$TMP/1.probe.log" \
    || fail "case 1: the post-delete read result marker is absent"
fi
# 2. RED: persist_lane_failures rises after the hard delete (the 2026-10-04 defect).
if want 2; then
  run_case 2 0:0 3:0
  expect 2 red 'hard-delete bar RED: status.resident.persist_lane_failures=3 after the hard delete'
fi
# 3. RED: deferred_persist_failed rises after the hard delete.
if want 3; then
  run_case 3 0:0 0:2
  expect 3 red 'hard-delete bar RED: status.resident.deferred_persist_failed=2 after the hard delete'
fi
# 4. RED: a sample lacks the persist-lane gauges.
if want 4; then
  run_case 4 0:0 -:-
  expect 4 red 'absent fields fail the bar'
fi
# 5. RED: the scratch write failed, so no delete ran.
if want 5; then
  FAKE_ADD_FAIL=1 run_case 5 0:0 0:0
  expect 5 red 'the scratch card write on the copy failed (kanban add rc=3)'
fi
# 6. RED: kanban rm failed on the copy.
if want 6; then
  FAKE_RM_FAIL=1 run_case 6 0:0 0:0
  expect 6 red 'kanban rm lastdb-safe-upgrade-hard-delete-probe-[0-9]* failed on the copy (rc=4)'
fi
# 7. RED: kanban rm answered 0 but the card is still readable.
if want 7; then
  FAKE_RM_KEEP=1 run_case 7 0:0 0:0
  expect 7 red 'is still readable on the copy after kanban rm'
fi
# 8. RED: an absent proof file.
if want 8; then
  set +e
  OUT="$(hard_delete_bar_eval "$TMP/does-not-exist.json" 2>&1)"
  RC=$?
  set -e
  expect 8 red 'hard-delete bar RED: proof is absent (not skipped)'
fi
# 9. No write: a copy path inside the primary home is refused before kanban runs.
if want 9; then
  export FAKE_STATE="$TMP/9/state"
  mkdir -p "$FAKE_STATE" "$PRIMARY_HOME/mp-c-9/data"
  if probe_hard_delete_bar "$PRIMARY_HOME/mp-c-9" "$PRIMARY_HOME/mp-c-9/data/folddb.sock" "$SLEEPER" "$TMP/9.json" >/dev/null 2>&1; then
    fail "case 9: a copy inside the primary home must be refused"
  fi
  [ ! -s "$FAKE_STATE/sockets" ] || fail "case 9: kanban ran against a path inside the primary home"
fi
# 10. No write: a socket outside the copy is refused before kanban runs.
if want 10; then
  export FAKE_STATE="$TMP/10/state"
  mkdir -p "$FAKE_STATE" "$TMP/10/mp-c-1/data"
  if probe_hard_delete_bar "$TMP/10/mp-c-1" "$PRIMARY_HOME/data/folddb.sock" "$SLEEPER" "$TMP/10.json" >/dev/null 2>&1; then
    fail "case 10: a socket outside the copy must be refused"
  fi
  [ ! -s "$FAKE_STATE/sockets" ] || fail "case 10: kanban ran against a socket outside the copy"
fi
# 11. A deadline keeps exact stage evidence in the retained driver log. CLI
#     error text stays in the temporary per-step file, not in that log.
if want 11; then
  FAKE_RM_TIMEOUT=1 run_case 11 0:0 0:0
  expect 11 red 'kanban rm lastdb-safe-upgrade-hard-delete-probe-[0-9]* failed on the copy (rc=124)'
  grep -q 'hard-delete bar: stage=rm start_unix_s=.* deadline_s=180' "$TMP/11.probe.log" \
    || fail "case 11: the rm start marker is absent"
  grep -q 'hard-delete bar: stage=rm rc=124 elapsed_s=[0-9]* stdout_bytes=0 stderr_bytes=[1-9][0-9]*' "$TMP/11.probe.log" \
    || fail "case 11: the rm result marker is absent"
  grep -q 'hard-delete bar: stage=rm deadline_result=124 deadline_s=180' "$TMP/11.probe.log" \
    || fail "case 11: the deadline marker is absent"
  if grep -q 'private probe error text' "$TMP/11.probe.log"; then
    fail "case 11: raw CLI error text leaked into the retained log"
  fi
fi

# 12. Only rm gets the longer deadline. The other calls stay at 90 seconds.
if want 12; then
  (
    # shellcheck disable=SC2329 # probe_hard_delete_bar calls this override.
    run_op_with_deadline() {
      local seconds="$1"
      shift
      printf '%s\n' "$seconds" >>"$TMP/12.deadlines"
      "$@"
    }
    run_case 12 0:0 0:0
    expect 12 green 'hard-delete bar GREEN:'
    actual="$(paste -sd, "$TMP/12.deadlines")"
    [ "$actual" = '90,90,180,90' ] || fail "case 12: deadlines for add, show-before, rm, show-after must be 90,90,180,90; actual=$actual"
  )
fi

# --- driver wiring -----------------------------------------------------------
if [ -z "$ONLY" ]; then
  grep -q '\. "$_SCRIPT_DIR/hard-delete-bar-checks.sh"' "$DRIVER" || fail "driver must source the hard-delete bar"
  grep -q 'probe_hard_delete_bar "$c_copy" "$c_sock" "$c_pid" "$hd_out"' "$DRIVER" || fail "driver must run the hard-delete step on the candidate copy"
  grep -q 'probe_like_to_like_metrics "$CANDIDATE_BIN" "$BASELINE_BIN" "$CAND_METRICS" "$BASE_METRICS" "$HD_PROOF"' "$DRIVER" \
    || fail "driver must pass the hard-delete proof path to the candidate probe"
  grep -q 'hard_delete_bar_eval "$HD_PROOF"' "$DRIVER" || fail "driver must score the hard-delete proof"
  # The verdict must come before the live install (STEP 3/4).
  eval_line="$(grep -n 'hard_delete_bar_eval "$HD_PROOF"' "$DRIVER" | head -1 | cut -d: -f1)"
  live_line="$(grep -n 'STEP 3/4: live install' "$DRIVER" | head -1 | cut -d: -f1)"
  [ "$eval_line" -lt "$live_line" ] || fail "driver must score the hard-delete bar before the live install"
fi

echo "ok: hard-delete bar fixture"
