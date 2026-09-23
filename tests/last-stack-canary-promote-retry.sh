#!/usr/bin/env bash
# A failed promote-eligible action is retried on a later hourly tick, bounded,
# with a Situations notice. Before 2026-09-23 one failed publish left the
# candidate promote-eligible every hour with no second attempt
# (papercut-release-publish-uses-stale-lastgit-fold-mirror-20260923).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CLI="$ROOT/bin/last-stack-canary-pipeline"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-promote-retry.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
state="$tmp/state"
ledger="$state/ledger.jsonl"

# Fake notice CLI: records each call.
notice_log="$tmp/notice.log"
mkdir -p "$tmp/bin"
cat >"$tmp/bin/fake-situations" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>'$notice_log'
EOF
chmod +x "$tmp/bin/fake-situations"
export PATH="$tmp/bin:$PATH"
export LAST_STACK_CANARY_V2_NOTICE_BIN=fake-situations
export LAST_STACK_CANARY_V2_PROMOTE_MAX_ATTEMPTS=3
export LAST_STACK_CANARY_V2_PROMOTE_RETRY_SECONDS=3000

action_log="$tmp/action.log"
fail_cmd="printf '%s\\n' attempt >> '$action_log'; exit 1"
ok_cmd="printf '%s\\n' attempt-ok >> '$action_log'"

"$CLI" --state-dir "$state" record-boot --candidate vpub --pid 301 \
  --start-ts '2026-09-01T00:00:00Z' --build vpub --at '2026-09-01T00:00:00Z' >/dev/null
"$CLI" --state-dir "$state" record-observation --candidate vpub --check status \
  --subject build --result pass --at '2026-09-01T00:01:00Z' >/dev/null

tick() { # tick <at> <command>; prints the verdict JSON or nothing when the action failed
  "$CLI" --state-dir "$state" --json reconcile --candidate vpub --window-seconds 3600 \
    --at "$1" --execute-actions --action-command "$2" 2>/dev/null || true
}
attempts() { wc -l <"$action_log" | tr -d ' '; }

# Attempt 1 fails.
tick '2026-09-01T02:00:00Z' "$fail_cmd" >/dev/null
[ "$(attempts)" = 1 ]
jq -s -e '[.[] | select(.record_type == "action_dispatch_result" and .attempt == 1 and .status == "exit_1")] | length == 1' "$ledger" >/dev/null
test ! -e "$notice_log"

# Ten minutes later: inside the retry interval, no attempt.
out="$(tick '2026-09-01T02:10:00Z' "$fail_cmd")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "retry-wait" ]
[ "$(attempts)" = 1 ]

# Next hour: attempt 2 runs and a notice is posted.
tick '2026-09-01T03:00:00Z' "$fail_cmd" >/dev/null
[ "$(attempts)" = 2 ]
grep -q 'retry 2/3 for vpub' "$notice_log"
grep -q -- '--kind other' "$notice_log"

# Attempt 3 (the last) fails: a give-up notice is posted.
tick '2026-09-01T04:00:00Z' "$fail_cmd" >/dev/null
[ "$(attempts)" = 3 ]
grep -q 'gave up for vpub' "$notice_log"

# The budget is spent: no more attempts.
out="$(tick '2026-09-01T05:00:00Z' "$fail_cmd")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "retry-exhausted" ]
[ "$(attempts)" = 3 ]

# A second candidate: attempt 1 fails, attempt 2 succeeds, then no repeat.
"$CLI" --state-dir "$state" record-boot --candidate vok --pid 302 \
  --start-ts '2026-09-02T00:00:00Z' --build vok --at '2026-09-02T00:00:00Z' >/dev/null
"$CLI" --state-dir "$state" record-observation --candidate vok --check status \
  --subject build --result pass --at '2026-09-02T00:01:00Z' >/dev/null
tick2() {
  "$CLI" --state-dir "$state" --json reconcile --candidate vok --window-seconds 3600 \
    --at "$1" --execute-actions --action-command "$2" 2>/dev/null || true
}
: >"$action_log"
tick2 '2026-09-02T02:00:00Z' "$fail_cmd" >/dev/null
out="$(tick2 '2026-09-02T03:00:00Z' "$ok_cmd")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "ok" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_attempt')" = "2" ]
out="$(tick2 '2026-09-02T04:00:00Z' "$ok_cmd")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "already-dispatched" ]
[ "$(attempts)" = 2 ]

# A legacy failed dispatch (no attempt field, written before this change) is
# retried as attempt 2 — the live 2026-09-23 case.
"$CLI" --state-dir "$state" record-boot --candidate vlegacy --pid 303 \
  --start-ts '2026-09-03T00:00:00Z' --build vlegacy --at '2026-09-03T00:00:00Z' >/dev/null
"$CLI" --state-dir "$state" record-observation --candidate vlegacy --check status \
  --subject build --result pass --at '2026-09-03T00:01:00Z' >/dev/null
token='{"action":"promote-eligible","candidate":"vlegacy","evidence":"quiet_window_complete","subject":""}'
jq -cn --arg t "$token" '{action:"promote-eligible",action_token:$t,candidate:"vlegacy",evidence:"quiet_window_complete",record_type:"action_dispatch",status:"started",subject:"",ts:"2026-09-03T01:30:00Z"}' >>"$ledger"
jq -cn --arg t "$token" '{action_token:$t,candidate:"vlegacy",record_type:"action_dispatch_result",status:"exit_1",ts:"2026-09-03T01:30:05Z"}' >>"$ledger"
: >"$action_log"
out="$("$CLI" --state-dir "$state" --json reconcile --candidate vlegacy --window-seconds 3600 \
  --at '2026-09-03T03:00:00Z' --execute-actions --action-command "$ok_cmd")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "ok" ]
[ "$(printf '%s\n' "$out" | jq -r '.action_attempt')" = "2" ]

# Non-promote actions stay one attempt per token.
"$CLI" --state-dir "$state" record-boot --candidate vheal --pid 304 \
  --start-ts '2026-09-04T00:00:00Z' --build vheal --cause guard-memory --at '2026-09-04T00:00:00Z' >/dev/null
: >"$action_log"
"$CLI" --state-dir "$state" --json reconcile --candidate vheal --window-seconds 86400 \
  --at '2026-09-04T00:30:00Z' --execute-actions --action-command "$fail_cmd" >/dev/null 2>&1 || true
out="$("$CLI" --state-dir "$state" --json reconcile --candidate vheal --window-seconds 86400 \
  --at '2026-09-04T03:30:00Z' --execute-actions --action-command "$fail_cmd")"
[ "$(printf '%s\n' "$out" | jq -r '.action_dispatch')" = "already-dispatched" ]
[ "$(attempts)" = 1 ]

echo "PASS last-stack-canary-promote-retry"
