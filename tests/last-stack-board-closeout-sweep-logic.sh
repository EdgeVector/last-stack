#!/usr/bin/env bash
# Unit-ish proof: board-closeout-sweep heals pr_url from body, demotes
# deploy-parked doing cards to backlog, and does not roll in-flight CRs to todo.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
sweep="$ROOT/bin/last-stack-board-closeout-sweep"
chmod +x "$sweep"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

board="$tmp/board"
moves="$tmp/moves"
heals="$tmp/heals"
tags="$tmp/tags"
: >"$moves"
: >"$heals"
: >"$tags"

cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  list)
    # emit one deploy-gated doing card with body PR but empty structured pr_url
    cat <<'JSON'
[
  {
    "slug": "open-pr-in-flight",
    "title": "ordinary in-flight CI",
    "column": "doing",
    "position": "9999999999999",
    "assignee": "worker",
    "tags": ["p1"],
    "pr_url": "http://localhost:3300/EdgeVector/fold/pulls/99999",
    "branch": "kanban/open-pr-in-flight",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nPR: http://localhost:3300/EdgeVector/fold/pulls/99999\n"
  },
  {
    "slug": "awaiting-deploy-no-pr",
    "title": "deploy park with no PR",
    "column": "doing",
    "position": "2",
    "assignee": "last-stack-kanban-pickup-w2",
    "tags": ["awaiting-deploy"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  },
  {
    "slug": "needs-safe-upgrade-no-pr",
    "title": "safe-upgrade park with no PR",
    "column": "doing",
    "position": "3",
    "assignee": "",
    "tags": ["needs-safe-upgrade"],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\n"
  },
  {
    "slug": "helper-cutover-end-state-no-pr",
    "title": "helper cutover wait with no PR",
    "column": "doing",
    "position": "4",
    "assignee": "",
    "tags": [],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/last-stack",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n\n## END STATE\nThe installed helper is on host-track current after helper cutover.\n"
  },
  {
    "slug": "empty-zombie-old",
    "title": "empty zombie",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "",
    "branch": "",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "nothing here"
  }
]
JSON
    ;;
  add)
    # heal path: add <slug> --pr-url <url>
    printf '%s\n' "$*" >>"${BOARD_HEALS:?}"
    ;;
  tag)
    printf '%s\n' "$*" >>"${BOARD_TAGS:?}"
    ;;
  set|mark)
    : ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$board"

# Intercept lastgit / closeout so merged classification fails open as open-or-unknown
# and we never hit real network. PATH wrapper:
binwrap="$tmp/bin"
mkdir -p "$binwrap"
cat >"$binwrap/lastgit" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  if [ "${3:-}" = "brain" ] && [ "${4:-}" = "cr-ms8mz1xt-981a" ]; then
    cat <<'JSON'
{"cr":{"state":"merged","id":"cr-ms8mz1xt-981a","merge_oid":"abc123"}}
JSON
    exit 0
  fi
  if [[ "${4:-}" == *'`'* ]]; then
    echo "unsanitized cr id: ${4:-}" >&2
    exit 1
  fi
  # Pretend other CRs are still open so we exercise heal + skip path.
  cat <<'JSON'
{"cr":{"state":"open","id":"cr-mrw0frwz-ea84"}}
JSON
  exit 0
fi
exit 1
EOF
chmod +x "$binwrap/lastgit"

# Forge API is resolved from lastStack/bin (not PATH). Stub an open PR so the
# in-flight CI card cannot be confused with a live merged CR.
first_stack="$tmp/first-stack"
mkdir -p "$first_stack/bin"
cp "$sweep" "$first_stack/bin/last-stack-board-closeout-sweep"
chmod +x "$first_stack/bin/last-stack-board-closeout-sweep"
cat >"$first_stack/bin/last-stack-forge-api" <<'EOF'
#!/usr/bin/env bash
cat <<'JSON'
{"state":"open","merged":false,"number":99999}
JSON
exit 0
EOF
chmod +x "$first_stack/bin/last-stack-forge-api"

export PATH="$binwrap:$PATH"
export BOARD_MOVES="$moves"
export BOARD_HEALS="$heals"
export BOARD_TAGS="$tags"

out="$("$first_stack/bin/last-stack-board-closeout-sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$out"

# Ordinary in-flight CI must stay in doing.
if grep -q 'open-pr-in-flight ' "$moves" 2>/dev/null; then
  echo "FAIL: in-flight CR card was moved:" >&2
  cat "$moves" >&2
  exit 1
fi

# No-PR deploy-parked cards must leave doing via backlog, not todo.
if ! grep -q 'awaiting-deploy-no-pr backlog' "$moves"; then
  echo "FAIL: expected awaiting-deploy-no-pr demoted to backlog:" >&2
  cat "$moves" >&2
  echo "out=$out" >&2
  exit 1
fi
if grep -q 'awaiting-deploy-no-pr todo' "$moves"; then
  echo "FAIL: deploy-parked card was rolled back to todo:" >&2
  cat "$moves" >&2
  exit 1
fi
if ! grep -q 'needs-safe-upgrade-no-pr backlog' "$moves"; then
  echo "FAIL: expected needs-safe-upgrade-no-pr demoted to backlog:" >&2
  cat "$moves" >&2
  echo "out=$out" >&2
  exit 1
fi
if ! grep -q 'helper-cutover-end-state-no-pr backlog' "$moves"; then
  echo "FAIL: expected helper-cutover END STATE card demoted to backlog:" >&2
  cat "$moves" >&2
  echo "out=$out" >&2
  exit 1
fi
if grep -q 'helper-cutover-end-state-no-pr todo' "$moves"; then
  echo "FAIL: helper-cutover END STATE card was rolled back to todo:" >&2
  cat "$moves" >&2
  exit 1
fi
echo "$out" | grep -q 'deploy-parked-demoted:awaiting-deploy-no-pr' || {
  echo "FAIL: expected deploy-parked-demoted flag: $out" >&2
  exit 1
}
echo "$out" | grep -q 'deploy-parked-demoted:helper-cutover-end-state-no-pr' || {
  echo "FAIL: expected helper-cutover demote flag: $out" >&2
  exit 1
}

# Empty zombie should roll back
if ! grep -q 'empty-zombie-old todo' "$moves"; then
  echo "FAIL: expected empty zombie rolled to todo:" >&2
  cat "$moves" >&2
  echo "out=$out" >&2
  exit 1
fi

echo "$out" | grep -q 'pr-open-or-unknown' || echo "$out" | grep -q 'open-pr-in-flight' || true
# Heal is optional here; the in-flight card already has a structured pr_url.

malformed_board="$tmp/malformed-board"
cat >"$malformed_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    cat <<'JSON'
[
  {
    "slug": "malformed-structured-pr-url",
    "title": "merged CR with copied markdown punctuation",
    "column": "doing",
    "position": "9999999999999",
    "assignee": "",
    "tags": [],
    "pr_url": "lastgit://brain/cr/cr-ms8mz1xt-981a`",
    "branch": "kanban/malformed-structured-pr-url",
    "repo": "EdgeVector/brain",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/brain\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  *)
    echo "unexpected malformed-board command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$malformed_board"

malformed_out="$("$sweep" --dry-run --board-cli "$malformed_board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$malformed_out"
echo "$malformed_out" | grep -q 'closed_slugs=malformed-structured-pr-url' || {
  echo "FAIL: expected malformed structured pr_url to resolve as merged after sanitizing:" >&2
  echo "$malformed_out" >&2
  exit 1
}
if echo "$malformed_out" | grep -q 'lastgit-fetch-failed:brain/cr-ms8mz1xt-981a`'; then
  echo "FAIL: trailing markdown punctuation leaked into LastGit lookup:" >&2
  echo "$malformed_out" >&2
  exit 1
fi

# Live (not dry-run) heal of a dirty-nonempty structured pr_url.
dirty_heals="$tmp/dirty-heals"
: >"$dirty_heals"
dirty_board="$tmp/dirty-board"
cat >"$dirty_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    cat <<'JSON'
[
  {
    "slug": "dirty-nonempty-pr-url",
    "title": "open CR with trailing markdown backtick in pr_url",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "lastgit://last-stack/cr/cr-mskqwa3y-78c9`",
    "branch": "kanban/dirty-nonempty-pr-url",
    "repo": "EdgeVector/last-stack",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/last-stack\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  add)
    printf '%s\n' "$*" >>"${BOARD_HEALS:?}"
    ;;
  move)
    ;;
  *)
    echo "unexpected dirty-board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$dirty_board"
export BOARD_HEALS="$dirty_heals"
dirty_out="$("$sweep" --board-cli "$dirty_board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$dirty_out"
if ! grep -q 'lastgit://last-stack/cr/cr-mskqwa3y-78c9' "$dirty_heals"; then
  echo "FAIL: expected dirty-nonempty pr_url heal to the sanitized lastgit URL:" >&2
  cat "$dirty_heals" >&2
  echo "out=$dirty_out" >&2
  exit 1
fi
if grep -q 'cr-mskqwa3y-78c9`' "$dirty_heals"; then
  echo "FAIL: heal restamped the dirty backtick URL:" >&2
  cat "$dirty_heals" >&2
  exit 1
fi
echo "$dirty_out" | grep -q 'pr-url-healed:dirty-nonempty-pr-url' || {
  echo "FAIL: expected pr-url-healed for dirty-nonempty field: $dirty_out" >&2
  exit 1
}

transient_stack="$tmp/transient-stack"
mkdir -p "$transient_stack/bin"
cp "$sweep" "$transient_stack/bin/last-stack-board-closeout-sweep"
cat >"$transient_stack/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
echo "service_timeout: board point read failed" >&2
exit 1
EOF
chmod +x "$transient_stack/bin/last-stack-card-closeout" "$transient_stack/bin/last-stack-board-closeout-sweep"

transient_closeout_board="$tmp/transient-closeout-board"
cat >"$transient_closeout_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    cat <<'JSON'
[
  {
    "slug": "merged-transient-closeout",
    "title": "merged but transient closeout failure",
    "column": "doing",
    "position": "1",
    "assignee": "",
    "tags": [],
    "pr_url": "lastgit://brain/cr/cr-ms8mz1xt-981a",
    "branch": "kanban/merged-transient-closeout",
    "repo": "EdgeVector/brain",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/brain\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  *)
    echo "unexpected transient-closeout-board command: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$transient_closeout_board"

transient_closeout_out="$("$transient_stack/bin/last-stack-board-closeout-sweep" \
  --board-cli "$transient_closeout_board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$transient_closeout_out"
echo "$transient_closeout_out" | grep -q 'closeout-deferred:merged-transient-closeout' || {
  echo "FAIL: expected transient closeout to be deferred:" >&2
  echo "$transient_closeout_out" >&2
  exit 1
}
if echo "$transient_closeout_out" | grep -q 'close-failed:merged-transient-closeout'; then
  echo "FAIL: transient closeout should not be flagged close-failed:" >&2
  echo "$transient_closeout_out" >&2
  exit 1
fi

# ── closed (not merged) forge PR → roll back to todo ───────────────────────
closed_moves="$tmp/closed-moves"
closed_heals="$tmp/closed-heals"
: >"$closed_moves"
: >"$closed_heals"

closed_board="$tmp/closed-board"
cat >"$closed_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  list)
    cat <<'JSON'
[
  {
    "slug": "reaped-closed-pr-ghost",
    "title": "doing with forge PR closed by reaper",
    "column": "doing",
    "position": "9999999999999",
    "assignee": "worker",
    "tags": [],
    "pr_url": "http://localhost:3300/EdgeVector/fold/pulls/1478",
    "branch": "kanban/reaped-closed-pr-ghost",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nPR: #1478\n"
  },
  {
    "slug": "still-open-pr",
    "title": "doing with open forge PR",
    "column": "doing",
    "position": "9999999999998",
    "assignee": "worker",
    "tags": [],
    "pr_url": "http://localhost:3300/EdgeVector/fold/pulls/9999",
    "branch": "kanban/still-open-pr",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\n"
  }
]
JSON
    ;;
  add)
    printf '%s\n' "$*" >>"${BOARD_HEALS:?}"
    ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected closed-board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$closed_board"

# Forge API mock: #1478 closed not merged; #9999 open
cat >"$binwrap/last-stack-forge-api" <<'EOF'
#!/usr/bin/env bash
path="${1:-}"
if [[ "$path" == *"/pulls/1478" ]]; then
  cat <<'JSON'
{"number":1478,"state":"closed","merged":false,"title":"reaped"}
JSON
  exit 0
fi
if [[ "$path" == *"/pulls/9999" ]]; then
  cat <<'JSON'
{"number":9999,"state":"open","merged":false,"title":"live"}
JSON
  exit 0
fi
echo "unexpected forge path: $path" >&2
exit 1
EOF
chmod +x "$binwrap/last-stack-forge-api"

# Put mock forge-api on PATH *and* make sweep resolve it via a fake last_stack:
# the sweep looks for $last_stack/bin/last-stack-forge-api relative to its own
# install. Copy a thin redirect next to the sweep under a isolated stack root.
closed_stack="$tmp/closed-stack"
mkdir -p "$closed_stack/bin"
cp "$sweep" "$closed_stack/bin/last-stack-board-closeout-sweep"
cp "$binwrap/last-stack-forge-api" "$closed_stack/bin/last-stack-forge-api"
chmod +x "$closed_stack/bin/last-stack-board-closeout-sweep" "$closed_stack/bin/last-stack-forge-api"

export BOARD_MOVES="$closed_moves"
export BOARD_HEALS="$closed_heals"
closed_out="$("$closed_stack/bin/last-stack-board-closeout-sweep" \
  --board-cli "$closed_board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$closed_out"

if ! grep -q 'reaped-closed-pr-ghost todo' "$closed_moves"; then
  echo "FAIL: closed-not-merged PR must roll back to todo:" >&2
  cat "$closed_moves" >&2
  echo "out=$closed_out" >&2
  exit 1
fi
if ! echo "$closed_out" | grep -q 'closed-pr:reaped-closed-pr-ghost'; then
  echo "FAIL: expected closed-pr flag for reaped card: $closed_out" >&2
  exit 1
fi
if ! echo "$closed_out" | grep -qE 'rolled_back=1|rolled_slugs=reaped-closed-pr-ghost'; then
  echo "FAIL: expected rolled_back for closed PR: $closed_out" >&2
  exit 1
fi
# Open PR must stay skipped, not rolled back (heartbeat only prints skip *count*)
if grep -q 'still-open-pr todo' "$closed_moves" 2>/dev/null; then
  echo "FAIL: open PR must not roll back to todo:" >&2
  cat "$closed_moves" >&2
  exit 1
fi
if ! echo "$closed_out" | grep -q 'skipped=1'; then
  echo "FAIL: expected skipped=1 for still-open PR (closed one was rolled): $closed_out" >&2
  exit 1
fi
# Structured pr_url should be cleared so pickup reopens cleanly
if ! grep -q 'reaped-closed-pr-ghost' "$closed_heals"; then
  echo "FAIL: expected pr_url clear for closed PR:" >&2
  cat "$closed_heals" >&2
  exit 1
fi

# ── STALE-PR REAP body annotation when forge lookup flakes ─────────────────
reap_moves="$tmp/reap-moves"
reap_heals="$tmp/reap-heals"
: >"$reap_moves"
: >"$reap_heals"

reap_board="$tmp/reap-board"
cat >"$reap_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  list)
    cat <<'JSON'
[
  {
    "slug": "body-reap-annotation",
    "title": "forge flaky but body says STALE-PR REAP",
    "column": "doing",
    "position": "1",
    "assignee": "worker",
    "tags": [],
    "pr_url": "http://localhost:3300/EdgeVector/fold/pulls/1478",
    "branch": "kanban/body-reap-annotation",
    "repo": "EdgeVector/fold",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/fold\nBase: main\nKind: pr\nPR: #1478\n\nSTALE-PR REAP: forge closed after 1h SLA (Mini gate red).\n"
  }
]
JSON
    ;;
  add)
    printf '%s\n' "$*" >>"${BOARD_HEALS:?}"
    ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected reap-board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$reap_board"

# Flaky forge: always fail
cat >"$closed_stack/bin/last-stack-forge-api" <<'EOF'
#!/usr/bin/env bash
echo "forge down" >&2
exit 1
EOF
chmod +x "$closed_stack/bin/last-stack-forge-api"

export BOARD_MOVES="$reap_moves"
export BOARD_HEALS="$reap_heals"
reap_out="$("$closed_stack/bin/last-stack-board-closeout-sweep" \
  --board-cli "$reap_board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$reap_out"

if ! grep -q 'body-reap-annotation todo' "$reap_moves"; then
  echo "FAIL: STALE-PR REAP body must roll back even when forge flakes:" >&2
  cat "$reap_moves" >&2
  echo "out=$reap_out" >&2
  exit 1
fi
if ! echo "$reap_out" | grep -q 'closed-pr:body-reap-annotation'; then
  echo "FAIL: expected closed-pr flag from body REAP: $reap_out" >&2
  exit 1
fi

# Merged CR + deploy-parked + closeout refused → backlog, not left in doing.
merged_park_stack="$tmp/merged-park-stack"
mkdir -p "$merged_park_stack/bin"
cp "$sweep" "$merged_park_stack/bin/last-stack-board-closeout-sweep"
cat >"$merged_park_stack/bin/last-stack-card-closeout" <<'EOF'
#!/usr/bin/env bash
echo "last-stack-card-closeout: deploy gate pending slug=merged-deploy-park repo=fold requires=deploy-pipeline status=missing" >&2
exit 1
EOF
chmod +x "$merged_park_stack/bin/last-stack-card-closeout" \
  "$merged_park_stack/bin/last-stack-board-closeout-sweep"

merged_park_moves="$tmp/merged-park-moves"
: >"$merged_park_moves"
merged_park_board="$tmp/merged-park-board"
cat >"$merged_park_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  list)
    cat <<'JSON'
[
  {
    "slug": "merged-deploy-park",
    "title": "merged CR still waiting on deploy",
    "column": "doing",
    "position": "1",
    "assignee": "worker",
    "tags": ["awaiting-deploy"],
    "pr_url": "lastgit://brain/cr/cr-ms8mz1xt-981a",
    "branch": "kanban/merged-deploy-park",
    "repo": "EdgeVector/brain",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/brain\nBase: main\nKind: pr\nRequires-Deploy: deploy-pipeline\n"
  }
]
JSON
    ;;
  add|tag|set|mark)
    : ;;
  move)
    printf '%s %s %s\n' "${2:-}" "${3:-}" "${4:-}" >>"${BOARD_MOVES:?}"
    ;;
  *)
    echo "unexpected merged-park-board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$merged_park_board"
export BOARD_MOVES="$merged_park_moves"
merged_park_out="$(env PATH="$binwrap:$PATH" \
  "$merged_park_stack/bin/last-stack-board-closeout-sweep" \
  --board-cli "$merged_park_board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$merged_park_out"
if ! grep -q 'merged-deploy-park backlog' "$merged_park_moves"; then
  echo "FAIL: merged deploy-parked close-failed card must demote to backlog:" >&2
  cat "$merged_park_moves" >&2
  echo "out=$merged_park_out" >&2
  exit 1
fi
if grep -q 'merged-deploy-park todo' "$merged_park_moves"; then
  echo "FAIL: merged deploy-parked card was rolled back to todo:" >&2
  cat "$merged_park_moves" >&2
  exit 1
fi
echo "$merged_park_out" | grep -q 'deploy-parked-demoted:merged-deploy-park' || {
  echo "FAIL: expected deploy-parked-demoted for merged close-failed park: $merged_park_out" >&2
  exit 1
}

echo "ok last-stack-board-closeout-sweep-logic"
