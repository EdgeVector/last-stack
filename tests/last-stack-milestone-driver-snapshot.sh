#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/last-stack-milestone-driver-snapshot"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

mkdir -p "$TMP/bin" "$TMP/failed-run/milestone-driver" "$TMP/good-run"
cat >"$TMP/bin/preflight-fail" <<'SH'
#!/usr/bin/env bash
exit 75
SH
cat >"$TMP/bin/preflight-pass" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$TMP/bin/kanban-fixture" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MILESTONE_DRIVER_TEST_KANBAN_LOG"
case "$*" in
  'list --column backlog --json'|'list --column todo --json'|'list --column doing --json')
    printf '%s\n' '{"cards":[],"total":0,"truncated":false}'
    ;;
  'milestone portfolio --json')
    printf '%s\n' '{"entries":[],"total":0,"truncated":false}'
    ;;
  'milestone gap-report --json')
    printf '%s\n' '{"counts":{"idle_promoteable":0,"idle_empty":0,"in_flight":0,"proof_pending":0},"work_queue":[],"action_counts":{}}'
    ;;
  *) exit 9 ;;
esac
SH
cat >"$TMP/bin/mutation-fixture" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$MILESTONE_DRIVER_TEST_MUTATION_LOG"
SH
chmod +x "$TMP/bin/preflight-fail" "$TMP/bin/preflight-pass" \
  "$TMP/bin/kanban-fixture" "$TMP/bin/mutation-fixture"

# A former-run report must disappear before a stopped preflight.
printf '%s\n' '{"_milestone_driver_run":{"run_id":"former-run"}}' \
  >"$TMP/failed-run/milestone-driver/gap-report.json"
failed_log="$TMP/failed-kanban.log"
set +e
MILESTONE_DRIVER_TEST_KANBAN_LOG="$failed_log" \
  "$HELPER" capture \
  --run-dir "$TMP/failed-run" \
  --run-id stopped-run \
  --preflight-bin "$TMP/bin/preflight-fail" \
  --kanban-bin "$TMP/bin/kanban-fixture" \
  >"$TMP/failed.out" 2>"$TMP/failed.err"
failed_rc=$?
set -e
[ "$failed_rc" -eq 75 ] || fail "stopped preflight returned $failed_rc, not 75"
[ ! -e "$TMP/failed-run/milestone-driver/gap-report.json" ] \
  || fail "stale gap report survived a stopped preflight"
[ ! -s "$failed_log" ] || fail "stopped preflight reached the board fixture"
grep -q 'no_board_commands=1' "$TMP/failed.err" \
  || fail "stopped preflight did not report the board fence"

# A successful pass creates and consumes only its current-run report.
good_log="$TMP/good-kanban.log"
MILESTONE_DRIVER_TEST_KANBAN_LOG="$good_log" \
  "$HELPER" capture \
  --run-dir "$TMP/good-run" \
  --run-id current-run \
  --preflight-bin "$TMP/bin/preflight-pass" \
  --kanban-bin "$TMP/bin/kanban-fixture" \
  >"$TMP/good.out"
artifact="$(jq -r .artifact "$TMP/good.out")"
[ "$artifact" = "$TMP/good-run/milestone-driver/gap-report.json" ] \
  || fail "capture used a non-run-scoped artifact: $artifact"

"$HELPER" consume --run-dir "$TMP/good-run" --run-id current-run \
  --artifact "$artifact" >"$TMP/consumed.json"
jq -e '
  ._milestone_driver_run.run_id == "current-run"
  and ._milestone_driver_run.preflight_succeeded == true
  and (._milestone_driver_run.created_epoch >= ._milestone_driver_run.preflight_succeeded_epoch)
  and .work_queue == []
' "$TMP/consumed.json" >/dev/null || fail "current-run metadata is invalid"

if "$HELPER" verify --run-dir "$TMP/good-run" --run-id former-run \
  --artifact "$artifact" >/dev/null 2>&1; then
  fail "former run id consumed the current report"
fi

mutation_log="$TMP/mutations.log"
MILESTONE_DRIVER_TEST_MUTATION_LOG="$mutation_log" \
  "$HELPER" guard --run-dir "$TMP/good-run" --run-id current-run \
  --artifact "$artifact" -- "$TMP/bin/mutation-fixture" move card-a todo
[ "$(cat "$mutation_log")" = 'move card-a todo' ] \
  || fail "current snapshot did not permit its guarded mutation"
if MILESTONE_DRIVER_TEST_MUTATION_LOG="$mutation_log" \
  "$HELPER" guard --run-dir "$TMP/good-run" --run-id former-run \
  --artifact "$artifact" -- "$TMP/bin/mutation-fixture" move card-b todo \
  >/dev/null 2>&1; then
  fail "former run id executed a guarded mutation"
fi
[ "$(wc -l <"$mutation_log" | tr -d ' ')" -eq 1 ] \
  || fail "a stale snapshot reached the mutation command"

jq '._milestone_driver_run.created_epoch = (._milestone_driver_run.preflight_succeeded_epoch - 1)' \
  "$artifact" >"$TMP/too-old.json"
mv "$TMP/too-old.json" "$artifact"
if "$HELPER" verify --run-dir "$TMP/good-run" --run-id current-run \
  --artifact "$artifact" >/dev/null 2>&1; then
  fail "a report older than preflight passed validation"
fi

[ "$(wc -l <"$good_log" | tr -d ' ')" -eq 5 ] \
  || fail "successful capture did not make the five expected keyed reads"

printf '%s\n' 'ok: milestone-driver snapshot rejects stale artifacts'
