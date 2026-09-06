#!/usr/bin/env bash
# last-stack-why-stopped-loom: mock loom, check JSON contract + fallback exit 3.
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-why-stopped-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

bash -n "$BIN"
[ -x "$BIN" ] || chmod +x "$BIN"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- no loom → exit 3 ---
# The helper prepends $HOME/.local/bin; isolate HOME so the host loom is gone.
set +e
HOME="$tmp" PATH="/usr/bin:/bin" "$BIN" --json --quiet >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "expected exit 3 without loom, got $rc $(cat "$tmp/err")"
grep -q '"reason":"loom_not_on_path"' "$tmp/out" \
  || fail "exit 3 did not name its cause on stdout: $(cat "$tmp/out")"

# --- mock loom ---
mkdir -p "$tmp/bin" "$tmp/install/dist" "$tmp/install/scripts" "$tmp/install/definitions"
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  ping) echo ok; exit 0 ;;
  publish)
    echo "published $(basename "$2" .json)"
    exit 0
    ;;
  run)
    cat <<'VIEW'
lx-test-1
lx-test-1
status: succeeded
state: DONE
context.classes: "A"
context.detail: "install:stale"
context.actions: "host-track refresh last-stack"
context.heal: "heal skipped (print-only; set LOOM_WHY_HEAL=1 to run Class A only)"
VIEW
    exit 0
    ;;
  *) echo "unexpected $*" >&2; exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
ln -s "$tmp/bin/loom" "$tmp/install/dist/loom"
printf '%s\n' 'echo classify' >"$tmp/install/scripts/loom-why-classify.sh"
printf '%s\n' '{}' >"$tmp/install/definitions/why-stopped.json"
printf '%s\n' '{}' >"$tmp/install/definitions/why-stopped-probe.json"

# Isolate HOME so the helper's $HOME/.local/bin prepend cannot pick host loom.
export HOME="$tmp"
export PATH="$tmp/bin:/usr/bin:/bin"
export LOOM_DEFS="$tmp/install/definitions"
export LOOM_SCRIPTS="$tmp/install/scripts"
export LOOM_WHY_KEY="why-stopped-test-key"

set +e
out="$("$BIN" --json --quiet)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "loom path exit $rc"
printf '%s\n' "$out" | grep -q '"classes":"A"' || fail "json missing classes=A: $out"
printf '%s\n' "$out" | grep -q '"engine":"loom"' || fail "json missing engine=loom: $out"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $out"

# failed loom exec → exit 3
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    cat <<'VIEW'
lx-fail
status: failed
state: CLASSIFY
VIEW
    exit 0
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
"$BIN" --json --quiet >/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "failed exec should exit 3, got $rc"

# --status reads the stamp written on the failed exec
st="$("$BIN" --status)"
printf '%s\n' "$st" | grep -q '"status": "failed"' || fail "status stamp missing failed: $st"
printf '%s\n' "$st" | grep -q '"missing": false' || fail "status should see stamp: $st"

# A non-terminal execution that DID classify → exit 4, and the classification
# still reaches the caller. Exit 3 used to cover this and "loom is missing",
# so the fleet surface reported a live loom as unavailable.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    cat <<'VIEW'
lx-incomplete
status: running
state: REPORT
context.classes: "D+F"
context.detail: "pickup:stalled"
context.actions: "check the board"
VIEW
    echo "execution lx-incomplete is incomplete" >&2
    exit 4
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
out="$("$BIN" --json --quiet)"
rc=$?
set -e
[ "$rc" -eq 4 ] || fail "incomplete exec should exit 4, not $rc: $out"
printf '%s\n' "$out" | grep -q '"classes":"D+F"' || fail "exit 4 dropped its classification: $out"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "exit 4 missing ROUTINE_RESULT: $out"

st="$("$BIN" --status)"
printf '%s\n' "$st" | grep -q '"status": "running"' || fail "stamp lost the real status: $st"

# An incomplete run with nothing to classify is still a fallback case.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    cat <<'VIEW'
lx-blank
status: running
state: HEAL
VIEW
    exit 4
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
"$BIN" --json --quiet >/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "incomplete exec with no classes should exit 3, got $rc"

# No view at all is the real "loom gave us nothing" case.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run) exit 1 ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
set +e
"$BIN" --json --quiet >/dev/null
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "empty view should exit 3, got $rc"

# --- every exit-3 branch names a DIFFERENT cause ------------------------
# Eight branches exited 3 and explained themselves only through log(), which
# --quiet silences and every caller sends to /dev/null. The reason now rides
# on stdout, where the caller already reads the classification, and lands in
# the stamp so the dashboard row can show it too. Two publish branches used
# to be counted as one; they are distinct failures and must read differently.
mk_loom() { # $1 = mode
  cat >"$tmp/bin/loom" <<SH
#!/usr/bin/env bash
mode="$1"
case "\${1:-} \$mode" in
  "ping ping-fail")     exit 1 ;;
  "ping "*)             echo ok; exit 0 ;;
  "publish publish1-fail") exit 1 ;;
  "publish publish2-fail")
      case "\${2##*/}" in why-stopped-probe.json) exit 1 ;; esac
      exit 0 ;;
  "publish "*)          exit 0 ;;
  "run no-view")        exit 0 ;;
  "run run-failed")     echo "status: failed"; exit 9 ;;
esac
exit 0
SH
  chmod 755 "$tmp/bin/loom"
}

reason_of() { # $1 = mode → prints the reason token
  mk_loom "$1"
  set +e
  o="$("$BIN" --json --quiet 2>/dev/null)"
  set -e
  printf '%s\n' "$o" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1
}

r_ping="$(reason_of ping-fail)"
r_pub1="$(reason_of publish1-fail)"
r_pub2="$(reason_of publish2-fail)"
r_view="$(reason_of no-view)"
r_run="$(reason_of run-failed)"

[ "$r_ping" = "loom_ping_failed" ] || fail "ping branch cause: $r_ping"
[ "$r_pub1" = "loom_publish_why_stopped_failed" ] || fail "publish branch cause: $r_pub1"
[ "$r_pub2" = "loom_publish_why_stopped_probe_failed" ] || fail "probe publish branch cause: $r_pub2"
[ "$r_view" = "loom_run_produced_no_view_rc_0" ] || fail "empty-view branch cause: $r_view"
[ "$r_run" = "loom_run_failed_rc_9" ] || fail "run-failed branch cause: $r_run"

# The two publish branches are the pair the earlier count merged into one.
[ "$r_pub1" != "$r_pub2" ] || fail "the two publish branches still read alike: $r_pub1"

n_distinct="$(printf '%s\n' "$r_ping" "$r_pub1" "$r_pub2" "$r_view" "$r_run" | sort -u | wc -l | tr -d ' ')"
[ "$n_distinct" -eq 5 ] || fail "expected 5 distinct causes, got $n_distinct"

# The stamp carries it too, so --status can show a cause the run dir no longer has.
mk_loom ping-fail
set +e; "$BIN" --json --quiet >/dev/null 2>&1; set -e
st="$("$BIN" --status)"
printf '%s\n' "$st" | grep -q '"reason": "loom_ping_failed"' \
  || fail "stamp did not keep the cause: $st"

# --- the publish branch keeps loom's stderr, and keeps its token stable ---
# The reason token names the BRANCH and is greppable; loom's own error text is
# free-form and belongs on its own line. Before this, the wrapper ran
# `loom publish ... 2>&1 >/dev/null`-style discard, so an HTTP 400 naming a
# missing schema field reached no stream and no record.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish)
    echo 'Error: lastdb POST /api/query -> HTTP 400: "Invalid field: schema abc has no field(s): updated_at"' >&2
    exit 1
    ;;
esac
exit 0
SH
chmod 755 "$tmp/bin/loom"
set +e
pub_out="$("$BIN" --json 2>"$tmp/pub-stderr.txt")"
pub_rc=$?
set -e
[ "$pub_rc" -eq 3 ] || fail "publish failure must exit 3, got $pub_rc"
grep -q 'has no field(s): updated_at' "$tmp/pub-stderr.txt" \
  || fail "publish stderr dropped loom's cause: $(cat "$tmp/pub-stderr.txt")"
pub_reason="$(printf '%s\n' "$pub_out" | sed -n 's/.*"reason":"\([^"]*\)".*/\1/p' | head -1)"
[ "$pub_reason" = "loom_publish_why_stopped_failed" ] \
  || fail "the cause line must not leak into the reason token: $pub_reason"

# --- a bounded run reaps the complete loom process group -----------------
cat >"$tmp/bin/loom-descendant" <<'PY'
#!/usr/bin/env python3
import signal
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(1)
PY
chmod 755 "$tmp/bin/loom-descendant"
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping) echo ok; exit 0 ;;
  publish) exit 0 ;;
  run)
    "$TEST_BIN/loom-descendant" &
    descendant=$!
    printf '%s %s\n' "$$" "$descendant" >"${LOOM_PROCESS_IDS:?}"
    printf '%s\n' 'node read stalled after accepted write' >&2
    wait "$descendant"
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$tmp/bin/loom"
export TEST_BIN="$tmp/bin"
export LOOM_PROCESS_IDS="$tmp/loom-process-ids"
export ROUTINES_RUN_DIR="$tmp/run"
mkdir -p "$ROUTINES_RUN_DIR"
export LAST_STACK_WHY_STOPPED_LOOM_TIMEOUT_SEC=10
export LAST_STACK_WHY_STOPPED_LOOM_RUN_TIMEOUT_SEC=1
set +e
timeout_out="$("$BIN" --json --quiet)"
timeout_rc=$?
set -e
[ "$timeout_rc" -eq 124 ] || fail "bounded loom run should exit 124, got $timeout_rc: $timeout_out"
printf '%s\n' "$timeout_out" | grep -q '"loom": "timeout"' \
  || fail "bounded loom run did not identify timeout: $timeout_out"
printf '%s\n' "$timeout_out" | grep -q 'node read stalled after accepted write' \
  || fail "bounded loom run lost the last loom stderr line: $timeout_out"
read -r loom_pid descendant_pid <"$LOOM_PROCESS_IDS"
for child_pid in "$loom_pid" "$descendant_pid"; do
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -9 "$child_pid" 2>/dev/null || true
    fail "bounded loom run left pid $child_pid alive"
  fi
done
grep -q 'node read stalled after accepted write' "$ROUTINES_RUN_DIR/why-stopped-loom.err" \
  || fail "loom stderr was not kept in the routine run directory"

# An external deadline signals the wrapper. Its TERM trap must reap the same
# process group before the wrapper exits.
export LAST_STACK_WHY_STOPPED_LOOM_RUN_TIMEOUT_SEC=30
: >"$LOOM_PROCESS_IDS"
set +e
"$BIN" --json --quiet >"$tmp/external-out" 2>"$tmp/external-err" &
wrapper_pid=$!
set -e
python3 - "$LOOM_PROCESS_IDS" <<'PY'
import sys
import time
from pathlib import Path

path = Path(sys.argv[1])
deadline = time.monotonic() + 5
while time.monotonic() < deadline:
    if path.stat().st_size if path.exists() else 0:
        raise SystemExit(0)
    time.sleep(0.02)
raise SystemExit("loom process ids did not appear")
PY
kill -TERM "$wrapper_pid"
set +e
wait "$wrapper_pid"
signal_rc=$?
set -e
[ "$signal_rc" -eq 124 ] || fail "signalled wrapper should exit 124, got $signal_rc"
read -r loom_pid descendant_pid <"$LOOM_PROCESS_IDS"
for child_pid in "$loom_pid" "$descendant_pid"; do
  if kill -0 "$child_pid" 2>/dev/null; then
    kill -9 "$child_pid" 2>/dev/null || true
    fail "signalled wrapper left pid $child_pid alive"
  fi
done

echo ok
