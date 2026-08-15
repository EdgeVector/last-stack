#!/usr/bin/env bash
# Unit-ish proof: board-closeout-sweep heals pr_url from body, parks deploy-gated
# cards, and does not roll them back to todo.
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
    "slug": "deploy-pipeline-red-schema-infra-20260722",
    "title": "P0 schema-infra deploy",
    "column": "doing",
    "position": "9999999999999",
    "assignee": "",
    "tags": ["pipeline", "p0"],
    "pr_url": "",
    "branch": "kanban/deploy-pipeline-red-schema-infra-20260722-build-once",
    "repo": "EdgeVector/schema-infra",
    "updated_at": "2020-01-01T00:00:00.000Z",
    "body": "Repo: EdgeVector/schema-infra\nBase: main\nKind: pr\nBranch: kanban/deploy-pipeline-red-schema-infra-20260722-build-once\nPR: lastgit://schema-infra/cr/cr-mrw0frwz-ea84\nRequires-Deploy: deploy-pipeline\n\n## LIVE PROOF\nReturning the card — do not mark done until deploy-pipeline is terminal success.\n"
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
# No last-stack-card-closeout in PATH → close path unused for open CR

export PATH="$binwrap:$PATH"
export BOARD_MOVES="$moves"
export BOARD_HEALS="$heals"
export BOARD_TAGS="$tags"

out="$("$sweep" --board-cli "$board" --grace-min 1 --max-actions 20 2>&1 || true)"
echo "$out"

# Deploy-gated card must NOT move to todo
if grep -q 'deploy-pipeline-red-schema-infra-20260722 todo' "$moves" 2>/dev/null; then
  echo "FAIL: deploy-gated card was rolled back to todo:" >&2
  cat "$moves" >&2
  exit 1
fi

# pr_url heal must have been attempted for the body PR
if ! grep -q 'pr-url lastgit://schema-infra/cr/cr-mrw0frwz-ea84' "$heals"; then
  # board cli gets: add slug --pr-url url  (order may vary)
  if ! grep -q 'lastgit://schema-infra/cr/cr-mrw0frwz-ea84' "$heals"; then
    echo "FAIL: expected pr_url heal from body header:" >&2
    cat "$heals" >&2
    echo "out=$out" >&2
    exit 1
  fi
fi

# Empty zombie should roll back
if ! grep -q 'empty-zombie-old todo' "$moves"; then
  echo "FAIL: expected empty zombie rolled to todo:" >&2
  cat "$moves" >&2
  echo "out=$out" >&2
  exit 1
fi

echo "$out" | grep -q 'pr-url-healed:deploy-pipeline-red-schema-infra-20260722' || {
  echo "FAIL: expected pr-url-healed flag in heartbeat: $out" >&2
  exit 1
}

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

echo "ok last-stack-board-closeout-sweep-logic"
