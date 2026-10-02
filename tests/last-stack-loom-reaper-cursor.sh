#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-loom-cursor.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

home="$tmp/home"
state="$tmp/state"
bin="$tmp/bin"
cursor="$state/last-stack/loom-reaper/source-audit-cursor.json"
gate="$state/last-stack/loom-reaper/source-audit.enabled"
mkdir -p "$home/.local/bin" "$bin"
cat >"$home/.local/bin/loom" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"${MOCK_LOOM_CALLS:?}"
jq -cn '$ARGS.positional' --args -- "$@" >>"${MOCK_LOOM_ARGS:?}"
if [ "${MOCK_LOOM_BAD_REPORT:-0}" = 1 ]; then
  printf '%s\n' '{"scanned":2334,"active":386}'
else
  next="${MOCK_LOOM_NEXT_CURSOR-page-two}"
  jq -cn --arg next "$next" \
    '{scanned:2334,active:386,source_audited:250,
      source_audit_next_cursor:$next,
      source_audit_cycle_complete:($next == "")}'
fi
exit "${MOCK_LOOM_RC:-0}"
SH
chmod +x "$home/.local/bin/loom"
export MOCK_LOOM_CALLS="$tmp/loom.calls"
export MOCK_LOOM_ARGS="$tmp/loom.args.jsonl"
: >"$MOCK_LOOM_CALLS"
: >"$MOCK_LOOM_ARGS"

# Intercept only the atomic cursor rename. The child kills the runner process
# before or after the rename, as an actual process crash would.
cat >"$bin/mv" <<'SH'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$2" = "${MOCK_KILL_CURSOR_TARGET:-none}" ]; then
  case "${MOCK_KILL_CURSOR_PHASE:-}" in
    before) kill -KILL "$PPID"; exit 137 ;;
    after) /bin/mv "$@"; kill -KILL "$PPID"; exit 0 ;;
  esac
fi
exec /bin/mv "$@"
SH
chmod +x "$bin/mv"

run() {
  HOME="$home" XDG_STATE_HOME="$state" PATH="$bin:$PATH" \
    "$ROOT/bin/last-stack-loom-reaper-run"
}

# An absent or malformed owner gate uses the legacy full census. The malformed
# file needs the exact newline too; a symlink cannot enable the mode.
absent="$(run)" || fail "absent gate pass failed"
printf '%s\n' "$absent" | jq -e \
  '.status == "ok" and .source_audit_gate == "absent" and
   (.source_audit_enabled | not)' >/dev/null || fail "absent gate enabled audit"
[ ! -e "$cursor" ] || fail "absent gate seeded a cursor"
mkdir -p "$(dirname "$gate")"
printf '1' >"$gate"
chmod 600 "$gate"
malformed="$(run 2>"$tmp/malformed.err")" || fail "malformed gate pass failed"
printf '%s\n' "$malformed" | jq -e \
  '.status == "ok" and .source_audit_gate == "invalid" and
   (.source_audit_enabled | not)' >/dev/null || fail "malformed gate enabled audit"
[ ! -e "$cursor" ] || fail "malformed gate seeded a cursor"
printf '1\n' >"$tmp/gate-target"
rm -f "$gate"
ln -s "$tmp/gate-target" "$gate"
symlink="$(run 2>"$tmp/symlink.err")" || fail "symlink gate pass failed"
printf '%s\n' "$symlink" | jq -e '.source_audit_gate == "invalid"' >/dev/null \
  || fail "symlink gate enabled audit"
rm -f "$gate"
printf '1\n' >"$gate"
chmod 644 "$gate"
wrong_mode="$(run 2>"$tmp/mode.err")" || fail "wrong-mode gate pass failed"
printf '%s\n' "$wrong_mode" | jq -e '.source_audit_gate == "invalid"' >/dev/null \
  || fail "wrong-mode gate enabled audit"
chmod 600 "$gate"
: >"$MOCK_LOOM_CALLS"
: >"$MOCK_LOOM_ARGS"

# The empty seed is durable before the first bounded pass. No primary key is
# skipped when the cursor file did not exist before this process started.
first="$(MOCK_LOOM_NEXT_CURSOR=page-two run)" || fail "first pass failed"
[ "$(jq -r '.next_cursor' "$cursor")" = page-two ] || fail "first cursor did not commit"
printf '%s\n' "$first" | jq -e \
  '.status == "ok" and .source_audit_enabled
   and .report.source_audit_next_cursor == "page-two"' >/dev/null \
  || fail "first report did not carry the cursor"
jq -e '.[0] == "reap" and
  .[-5:] == ["--source-audit-after","","--source-audit-limit","250","--json"]' \
  "$MOCK_LOOM_ARGS" >/dev/null || fail "first pass did not start at the first key: $(cat "$MOCK_LOOM_ARGS")"

# A separate process resumes at the exact opaque cursor. End of collection
# returns an empty cursor and starts a new cycle on the next pass.
second="$(MOCK_LOOM_NEXT_CURSOR='' run)" || fail "second pass failed"
[ "$(jq -r '.next_cursor' "$cursor")" = "" ] || fail "cycle did not reset"
printf '%s\n' "$second" | jq -e '.report.source_audit_cycle_complete' >/dev/null \
  || fail "cycle completion was not reported"
jq -s -e '.[1][-5:] ==
  ["--source-audit-after","page-two","--source-audit-limit","250","--json"]' \
  "$MOCK_LOOM_ARGS" >/dev/null || fail "second pass lost the opaque cursor"

# A failed pass and a success report without a cursor cannot advance state.
set +e
MOCK_LOOM_RC=7 MOCK_LOOM_NEXT_CURSOR=ignored run >"$tmp/fail.out" 2>"$tmp/fail.err"
failed_rc=$?
MOCK_LOOM_BAD_REPORT=1 run >"$tmp/bad.out" 2>"$tmp/bad.err"
bad_rc=$?
set -e
[ "$failed_rc" -eq 7 ] || fail "failed pass exit changed: $failed_rc"
[ "$bad_rc" -eq 78 ] || fail "missing cursor did not fail closed: $bad_rc"
[ "$(jq -r '.next_cursor' "$cursor")" = "" ] || fail "failed pass advanced the cursor"

# A malformed state never reaches Loom. The operator can restore the saved
# cursor or remove this state to restart from the first primary key.
calls_before="$(wc -l <"$MOCK_LOOM_CALLS" | tr -d ' ')"
printf '%s\n' '{malformed' >"$cursor"
set +e
run >"$tmp/corrupt.out" 2>"$tmp/corrupt.err"
corrupt_rc=$?
set -e
[ "$corrupt_rc" -eq 78 ] || fail "malformed state did not fail closed: $corrupt_rc"
[ "$(wc -l <"$MOCK_LOOM_CALLS" | tr -d ' ')" = "$calls_before" ] \
  || fail "Loom ran with malformed cursor state"

# State loss restarts the audit at the first key. It does not silently accept
# an absent cursor as proof that the next page was already inspected.
rm -f "$cursor"
MOCK_LOOM_NEXT_CURSOR=old run >/dev/null || fail "restart from missing state failed"
[ "$(jq -r '.next_cursor' "$cursor")" = old ] || fail "restart cursor did not commit"

# A crash before the cursor rename repeats the old page. A crash just after
# the rename preserves the new cursor, because Loom already returned success.
set +e
MOCK_KILL_CURSOR_TARGET="$cursor" MOCK_KILL_CURSOR_PHASE=before \
  MOCK_LOOM_NEXT_CURSOR=new run >"$tmp/crash-before.out" 2>"$tmp/crash-before.err"
before_rc=$?
set -e
[ "$before_rc" -ne 0 ] || fail "before-commit crash did not stop the runner"
[ "$(jq -r '.next_cursor' "$cursor")" = old ] || fail "before-commit crash advanced cursor"
set +e
MOCK_KILL_CURSOR_TARGET="$cursor" MOCK_KILL_CURSOR_PHASE=after \
  MOCK_LOOM_NEXT_CURSOR=new run >"$tmp/crash-after.out" 2>"$tmp/crash-after.err"
after_rc=$?
set -e
[ "$after_rc" -ne 0 ] || fail "after-commit crash did not stop the runner"
[ "$(jq -r '.next_cursor' "$cursor")" = new ] || fail "after-commit crash lost cursor"
MOCK_LOOM_NEXT_CURSOR='' run >/dev/null || fail "restart after committed crash failed"
jq -s -e '.[-1][-5:] ==
  ["--source-audit-after","new","--source-audit-limit","250","--json"]' \
  "$MOCK_LOOM_ARGS" >/dev/null || fail "restart did not use committed cursor"

# Removing the owner gate is the rollback. The next pass uses the old full
# census without changing the cursor state.
rm -f "$gate"
rollback="$(run)" || fail "rollback pass failed"
printf '%s\n' "$rollback" | jq -e \
  '.source_audit_gate == "absent" and (.source_audit_enabled | not)' >/dev/null \
  || fail "rollback did not restore the full census"
[ "$(jq -r '.next_cursor' "$cursor")" = "" ] || fail "rollback changed cursor state"

echo "ok: Loom reaper cursor seed, restart, failure, and crash cuts"
