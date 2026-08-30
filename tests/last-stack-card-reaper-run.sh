#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

# This suite drives the REAL runner, which writes routinesd's outcome sink at
# $ROUTINES_RUN_DIR/outcome.txt. routinesd exports that variable into every
# routine harness, so when the CI gate runs from inside a routine the fixtures
# below would land in that routine's sink and routinesd would report it on this
# test's verdict. Observed 5 times across 3 routines. Never inherit it: each
# case names the run dir it wants.
unset ROUTINES_RUN_DIR CARD_REAPER_RUN_DIR

tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

board="$tmp/board.json"
cat >"$board" <<'JSON'
[
  {
    "slug": "fresh-todo",
    "title": "Fresh todo",
    "column": "todo",
    "created_at": "2026-07-20T12:00:00Z"
  },
  {
    "slug": "stale-todo",
    "title": "Stale todo",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  },
  {
    "slug": "stale-child",
    "title": "Stale child protected by capstone",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  },
  {
    "slug": "live-capstone",
    "title": "Live capstone",
    "column": "backlog",
    "created_at": "2026-07-15T12:00:00Z",
    "deps": ["stale-child"]
  },
  {
    "slug": "human-blocked-old",
    "title": "Human blocked old",
    "column": "backlog",
    "created_at": "2026-07-01T12:00:00Z",
    "block_status": "needs_human"
  },
  {
    "slug": "done-card",
    "title": "Done",
    "column": "done",
    "created_at": "2026-07-01T12:00:00Z"
  }
]
JSON

out="$("$ROOT/bin/last-stack-card-reaper-run" \
  --dry-run \
  --skip-preflight \
  --board-json "$board" \
  --memory "$tmp/memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$out" | grep -q '^would_kill stale-todo: todo stale >72h with no progress; age=121.5h$'
printf '%s\n' "$out" | grep -q '^card-reaper 2026-07-20T13:31:08Z ok live=5 killed=<backlog=0,todo=1,doing=0> rolled_back=0 parked=0 salvaged=0 exempt_needs_human=1 flagged=live-dependent-protected:stale-child,needs-human-aging:human-blocked-old,dry-run$'
! printf '%s\n' "$out" | grep -q '^would_kill stale-child:'
test ! -e "$tmp/memory.md"

transient_board="$tmp/transient-board.json"
cat >"$transient_board" <<'JSON'
[
  {
    "slug": "transient-add",
    "title": "Transient add failure",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  }
]
JSON

fake_bin="$tmp/bin"
mkdir -p "$fake_bin" "$tmp/no-last-stack"
cat >"$fake_bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    cat <<'JSON'
{"slug":"transient-add","body":"## END STATE\nDone."}
JSON
    ;;
  add)
    echo "service_timeout: node did not respond within 30000ms" >&2
    exit 1
    ;;
  rm|move)
    echo "unexpected destructive mutation after add failure: $*" >&2
    exit 2
    ;;
  *)
    echo "unexpected kanban command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$fake_bin/kanban"

transient_out="$(PATH="$fake_bin:$PATH" LAST_STACK_ROOT="$tmp/no-last-stack" "$ROOT/bin/last-stack-card-reaper-run" \
  --skip-preflight \
  --board-json "$transient_board" \
  --memory "$tmp/transient-memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$transient_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z noop live=1 killed=<backlog=0,todo=0,doing=0> rolled_back=0 parked=0 salvaged=0 exempt_needs_human=0 flagged=board-add-deferred:transient-add$'
! printf '%s\n' "$transient_out" | grep -q 'exception:kanban_add_failed'
test ! -e "$tmp/transient-memory.md"

reference_board="$tmp/reference-board.json"
cat >"$reference_board" <<'JSON'
[
  {
    "slug": "missing-dependency",
    "title": "Missing dependency projection",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  },
  {
    "slug": "protected-dependency",
    "title": "Protected dependency",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  },
  {
    "slug": "live-dependent",
    "title": "Live dependent",
    "column": "todo",
    "created_at": "2026-07-20T13:00:00Z",
    "deps": ["protected-dependency"]
  }
]
JSON

reference_bin="$tmp/reference-bin"
mkdir -p "$reference_bin"
cat >"$reference_bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  show:missing-dependency)
    echo 'kanban: No card with slug "missing-dependency"' >&2
    exit 1
    ;;
  show:*)
    echo "unexpected show for protected card: $*" >&2
    exit 2
    ;;
  *)
    echo "unexpected kanban command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$reference_bin/kanban"

reference_out="$(PATH="$reference_bin:$PATH" LAST_STACK_ROOT="$tmp/no-last-stack" "$ROOT/bin/last-stack-card-reaper-run" \
  --skip-preflight \
  --board-json "$reference_board" \
  --memory "$tmp/reference-memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$reference_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z noop live=3 killed=<backlog=0,todo=0,doing=0> rolled_back=0 parked=0 salvaged=0 exempt_needs_human=0 flagged=stale-dependency-ref:missing-dependency,live-dependent-protected:protected-dependency$'
! printf '%s\n' "$reference_out" | grep -q 'exception:kanban_show_failed'
! printf '%s\n' "$reference_out" | grep -q '^would_kill protected-dependency:'
! printf '%s\n' "$reference_out" | grep -q '^killed protected-dependency:'

unexpected_bin="$tmp/unexpected-bin"
mkdir -p "$unexpected_bin"
cat >"$unexpected_bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
echo "permission denied by unexpected board fault" >&2
exit 1
EOF
chmod +x "$unexpected_bin/kanban"

unexpected_out="$(PATH="$unexpected_bin:$PATH" LAST_STACK_ROOT="$tmp/no-last-stack" "$ROOT/bin/last-stack-card-reaper-run" \
  --skip-preflight \
  --board-json "$transient_board" \
  --memory "$tmp/unexpected-memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$unexpected_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z error '
printf '%s\n' "$unexpected_out" | grep -q 'flagged=exception:kanban_show_failed_for_transient-add:'

promotion_board="$tmp/promotion-board.json"
cat >"$promotion_board" <<'JSON'
[
  {
    "slug": "papercut-invalid-promotion",
    "title": "Papercut promotion",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  }
]
JSON

promotion_bin="$tmp/promotion-bin"
mkdir -p "$promotion_bin"
cat >"$promotion_bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    printf '%s\n' '{"slug":"papercut-invalid-promotion","body":"## END STATE\\nDone."}'
    ;;
  add)
    cat >/dev/null
    echo 'kanban: Card North Star: north-star-typed-papercuts is not active' >&2
    exit 1
    ;;
  rm|move)
    echo "unexpected mutation after validation rejection: $*" >&2
    exit 2
    ;;
  *)
    echo "unexpected kanban command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$promotion_bin/kanban"

promotion_out="$(PATH="$promotion_bin:$PATH" LAST_STACK_ROOT="$tmp/no-last-stack" "$ROOT/bin/last-stack-card-reaper-run" \
  --skip-preflight \
  --board-json "$promotion_board" \
  --memory "$tmp/promotion-memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$promotion_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z noop live=1 killed=<backlog=0,todo=0,doing=0> rolled_back=0 parked=0 salvaged=0 exempt_needs_human=0 flagged=papercut-promotion-validation:papercut-invalid-promotion$'
! printf '%s\n' "$promotion_out" | grep -q 'exception:kanban_add_failed'
test ! -e "$tmp/promotion-memory.md"

doing_board="$tmp/doing-board.json"
cat >"$doing_board" <<'JSON'
[
  {
    "slug": "first-dead-doing",
    "title": "First dead doing",
    "column": "doing",
    "created_at": "2026-07-20T11:31:08Z"
  },
  {
    "slug": "churn-after-rollback",
    "title": "Churn after rollback",
    "column": "doing",
    "assignee": "grok",
    "created_at": "2026-07-20T08:31:08Z"
  },
  {
    "slug": "doing-squatter",
    "title": "Doing squatter",
    "column": "doing",
    "created_at": "2026-07-19T07:31:08Z"
  }
]
JSON
printf '%s\n' "2026-07-20T12:00:00Z rolled_back churn-after-rollback rule=doing dead claim >60m; age=3.5h" >"$tmp/doing-memory.md"

doing_out="$("$ROOT/bin/last-stack-card-reaper-run" \
  --dry-run \
  --skip-preflight \
  --board-json "$doing_board" \
  --memory "$tmp/doing-memory.md" \
  --now 2026-07-20T13:31:08Z)"

printf '%s\n' "$doing_out" | grep -q '^would_roll_back first-dead-doing: doing dead claim >60m; age=2.0h$'
printf '%s\n' "$doing_out" | grep -q '^would_park_backlog churn-after-rollback: doing churn after prior rollback; age=5.0h$'
printf '%s\n' "$doing_out" | grep -q '^would_kill doing-squatter: doing squatter >24h; age=30.0h$'
! printf '%s\n' "$doing_out" | grep -q '^would_kill churn-after-rollback:'
printf '%s\n' "$doing_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z ok live=3 killed=<backlog=0,todo=0,doing=1> rolled_back=1 parked=1 salvaged=0 exempt_needs_human=0 flagged=dry-run$'
printf '%s\n' "$doing_out" | grep -q '^ROUTINE_RESULT outcome=ok'

# Closeout noop + reaper pass must still emit card-reaper heartbeat +
# ROUTINE_RESULT. A completed pass must not become outcome=error
# flagged=runner-no-heartbeat (scheduled run 2026-08-20T14-30-57-829Z).
noop_stack="$tmp/noop-stack"
# Shaped like a real routinesd run dir: .../runs/<routine-id>/<timestamp>.
# The runner claims the sink only when the parent is named for it.
run_owned="$tmp/routines/runs/last-stack-card-reaper/2026-07-20T13-31-08-000Z"
mkdir -p "$noop_stack/bin" "$run_owned"
cat >"$noop_stack/bin/last-stack-board-closeout-sweep" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' '{"kind":"board-closeout","status":"noop","iso":"2026-07-20T13:31:08Z","closed":0,"rolled_back":0,"demoted":0,"skipped":0,"flagged":[]}'
printf '%s\n' 'board-closeout 2026-07-20T13:31:08Z noop closed=0 rolled_back=0 demoted=0 skipped=0 flagged=none'
exit 0
EOF
chmod +x "$noop_stack/bin/last-stack-board-closeout-sweep"

reap_bin="$tmp/reap-bin"
mkdir -p "$reap_bin"
cat >"$reap_bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    cat <<'JSON'
{"slug":"stale-todo","body":"## END STATE\nDone."}
JSON
    ;;
  add)
    cat >/dev/null
    exit 0
    ;;
  rm|move)
    exit 0
    ;;
  *)
    echo "unexpected kanban command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$reap_bin/kanban"

stale_board="$tmp/stale-pass-board.json"
cat >"$stale_board" <<'JSON'
[
  {
    "slug": "stale-todo",
    "title": "Stale todo",
    "column": "todo",
    "created_at": "2026-07-15T12:00:00Z",
    "body": "## END STATE\nDone."
  }
]
JSON

chain_out="$(
  PATH="$reap_bin:$PATH" \
  LAST_STACK_ROOT="$noop_stack" \
  ROUTINES_RUN_DIR="$run_owned" \
  CARD_REAPER_MEMORY="$tmp/pass-memory.md" \
  bash -c '
    set -uo pipefail
    ( "$1/bin/last-stack-board-closeout-sweep" || true )
    "$2" --skip-preflight --board-json "$3" --memory "$4" --now 2026-07-20T13:31:08Z
  ' _ "$noop_stack" "$ROOT/bin/last-stack-card-reaper-run" "$stale_board" "$tmp/pass-memory.md"
)"

printf '%s\n' "$chain_out" | grep -q '^board-closeout 2026-07-20T13:31:08Z noop '
printf '%s\n' "$chain_out" | grep -q '^killed stale-todo:'
printf '%s\n' "$chain_out" | grep -q '^card-reaper 2026-07-20T13:31:08Z ok live=1 killed=<backlog=0,todo=1,doing=0> rolled_back=0 parked=0 salvaged=0 exempt_needs_human=0 flagged=none$'
printf '%s\n' "$chain_out" | grep -q '^ROUTINE_RESULT outcome=ok'
if printf '%s\n' "$chain_out" | grep -q 'runner-no-heartbeat'; then
  echo "FAIL: closeout noop + reaper pass classified runner-no-heartbeat:" >&2
  printf '%s\n' "$chain_out" >&2
  exit 1
fi
if printf '%s\n' "$chain_out" | grep -q 'outcome=error'; then
  echo "FAIL: closeout noop + reaper pass produced outcome=error:" >&2
  printf '%s\n' "$chain_out" >&2
  exit 1
fi
test -s "$run_owned/outcome.txt"
grep -q '^ok ' "$run_owned/outcome.txt"
test -s "$run_owned/scratch/result.json"

# Regression: a run dir belonging to ANOTHER routine must be left untouched.
# This is the defect itself — the runner used to accept any inherited
# ROUTINES_RUN_DIR as proof of ownership, so running this very suite inside a
# pickup worker overwrote that worker's outcome with a fixture verdict.
foreign="$tmp/routines/runs/last-stack-fkanban-pickup-w3/2026-08-30T13-40-09-658Z"
mkdir -p "$foreign"
foreign_out="$(ROUTINES_RUN_DIR="$foreign" "$ROOT/bin/last-stack-card-reaper-run" \
  --dry-run \
  --skip-preflight \
  --board-json "$board" \
  --memory "$tmp/foreign-memory.md" \
  --now 2026-07-20T13:31:08Z 2>"$tmp/foreign.err")"

# The run itself still works and still reports on stdout ...
printf '%s\n' "$foreign_out" | grep -q '^ROUTINE_RESULT outcome=ok'
# ... it just does not touch a sink it does not own, nor litter scratch/ there.
if [ -e "$foreign/outcome.txt" ]; then
  echo "FAIL: runner wrote outcome.txt into a foreign routine's run dir:" >&2
  cat "$foreign/outcome.txt" >&2
  exit 1
fi
test ! -e "$foreign/scratch"
# And it says so, rather than falling back silently.
grep -q 'belongs to another routine' "$tmp/foreign.err"

# An explicit CARD_REAPER_RUN_DIR is still an unconditional claim, so direct
# callers and tests keep a way to name the sink they want.
explicit="$tmp/explicit-run"
mkdir -p "$explicit"
CARD_REAPER_RUN_DIR="$explicit" "$ROOT/bin/last-stack-card-reaper-run" \
  --dry-run \
  --skip-preflight \
  --board-json "$board" \
  --memory "$tmp/explicit-memory.md" \
  --now 2026-07-20T13:31:08Z >/dev/null
test -s "$explicit/outcome.txt"

echo "ok last-stack-card-reaper-run"
