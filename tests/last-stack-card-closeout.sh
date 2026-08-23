#!/usr/bin/env bash
# Smoke-test the closeout helper's CLI shape (no live board required for --help/usage).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-card-closeout"
chmod +x "$bin" "$ROOT/bin/last-stack-attribution-trailers" 2>/dev/null || true

# usage exit
if "$bin" 2>/dev/null; then
  echo "expected usage failure" >&2
  exit 1
fi

# Prefer dry structural checks: script is bash -n clean
bash -n "$bin"

if command -v gtimeout >/dev/null 2>&1 || command -v timeout >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  board="$tmp/slow-board"
  cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    sleep 5
    printf '{"slug":"%s","column":"doing","body":""}\n' "$2"
    ;;
  add|move)
    exit 0
    ;;
  *)
    echo "unexpected fake board command: $*" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$board"
  started="$(date +%s)"
  if LAST_STACK_CARD_CLOSEOUT_COMMAND_TIMEOUT_SEC=1 "$bin" slow-card --board-cli "$board" >/tmp/card-closeout-slow.$$ 2>&1; then
    cat /tmp/card-closeout-slow.$$ >&2
    rm -f /tmp/card-closeout-slow.$$
    echo "expected slow board read to fail" >&2
    exit 1
  fi
  elapsed=$(( $(date +%s) - started ))
  if [ "$elapsed" -gt 4 ]; then
    cat /tmp/card-closeout-slow.$$ >&2
    rm -f /tmp/card-closeout-slow.$$
    echo "slow board read was not bounded: elapsed=${elapsed}s" >&2
    exit 1
  fi
  grep -q 'FAILED card-read-failed slug=slow-card' /tmp/card-closeout-slow.$$
  rm -f /tmp/card-closeout-slow.$$
fi

# Restamp add failure must still move to done (merged-CR closeout), then
# fail closed when the requested pr_url is not on the card.
restamp_tmp="$(mktemp -d)"
trap 'rm -rf "${tmp:-}" "$restamp_tmp"' EXIT
restamp_board="$restamp_tmp/board"
restamp_moves="$restamp_tmp/moves"
restamp_adds="$restamp_tmp/adds"
: >"$restamp_moves"
: >"$restamp_adds"
cat >"$restamp_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
col_file="${REESTAMP_COL:?}"
[ -f "$col_file" ] || echo doing >"$col_file"
case "${1:-}" in
  show)
    col="$(cat "$col_file")"
    printf '{"slug":"%s","column":"%s","body":"Repo: EdgeVector/last-stack\\nKind: pr\\n","pr_url":"lastgit://last-stack/cr/cr-mskqwa3y-78c9`","north_star":"`north-star-org-cloud-principal-membership`","milestone":"ms-org-cloud-principal-membership"}\n' "${2:-}" "$col"
    ;;
  add)
    printf '%s\n' "$*" >>"${REESTAMP_ADDS:?}"
    echo "north_star does not match milestone" >&2
    exit 1
    ;;
  move)
    printf '%s %s\n' "${2:-}" "${3:-}" >>"${REESTAMP_MOVES:?}"
    printf '%s\n' "${3:-}" >"$col_file"
    exit 0
    ;;
  *)
    echo "unexpected restamp board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$restamp_board"
stub_bin="$restamp_tmp/stub-bin"
mkdir -p "$stub_bin"
cat >"$stub_bin/lastgit" <<'EOF'
#!/usr/bin/env bash
# lastgit cr view <slug> <id> --json
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  printf '{"state":"merged","merge_oid":"abc123"}\n'
  exit 0
fi
echo "unexpected lastgit $*" >&2
exit 2
EOF
chmod +x "$stub_bin/lastgit"
export PATH="$stub_bin:$PATH"
export REESTAMP_MOVES="$restamp_moves"
export REESTAMP_ADDS="$restamp_adds"
export REESTAMP_COL="$restamp_tmp/col"
echo doing >"$REESTAMP_COL"
set +e
restamp_out="$("$bin" restamp-card --board-cli "$restamp_board" --pr-url 'lastgit://last-stack/cr/cr-mskqwa3y-78c9`' 2>&1)"
restamp_rc=$?
set -e
if [ "$restamp_rc" -eq 0 ]; then
  echo "FAIL: card-closeout must not report ok when restamp leaves empty/wrong pr_url:" >&2
  echo "$restamp_out" >&2
  exit 1
fi
echo "$restamp_out" | grep -q 'WARN board-add-failed' || {
  echo "FAIL: expected restamp WARN: $restamp_out" >&2
  exit 1
}
echo "$restamp_out" | grep -q 'FAILED linkage-missing' || {
  echo "FAIL: expected linkage-missing after restamp add failure: $restamp_out" >&2
  exit 1
}
grep -q 'restamp-card done' "$restamp_moves" || {
  echo "FAIL: expected move to done after restamp failure:" >&2
  cat "$restamp_moves" >&2
  exit 1
}
# --pr-url passed to add must be sanitized (no trailing backtick)
if grep -q 'cr-mskqwa3y-78c9`' "$restamp_adds"; then
  echo "FAIL: restamp add received dirty pr_url:" >&2
  cat "$restamp_adds" >&2
  exit 1
fi
grep -q 'lastgit://last-stack/cr/cr-mskqwa3y-78c9' "$restamp_adds" || {
  echo "FAIL: expected sanitized pr_url on restamp add:" >&2
  cat "$restamp_adds" >&2
  exit 1
}

# Closed unmerged review must not move Kind:pr to done.
unmerged_tmp="$(mktemp -d)"
unmerged_board="$unmerged_tmp/board"
unmerged_moves="$unmerged_tmp/moves"
: >"$unmerged_moves"
cat >"$unmerged_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
col_file="${UNMERGED_COL:?}"
[ -f "$col_file" ] || echo doing >"$col_file"
case "${1:-}" in
  show)
    printf '{"slug":"%s","column":"%s","body":"Repo: EdgeVector/fold\\nKind: pr\\n"}\n' "${2:-}" "$(cat "$col_file")"
    ;;
  add)
    exit 0
    ;;
  move)
    printf '%s %s\n' "${2:-}" "${3:-}" >>"${UNMERGED_MOVES:?}"
    printf '%s\n' "${3:-}" >"$col_file"
    exit 0
    ;;
  *)
    echo "unexpected unmerged board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$unmerged_board"
cat >"$stub_bin/lastgit" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  printf '{"state":"closed","merge_oid":""}\n'
  exit 0
fi
exit 2
EOF
export UNMERGED_MOVES="$unmerged_moves"
export UNMERGED_COL="$unmerged_tmp/col"
echo doing >"$UNMERGED_COL"
set +e
unmerged_out="$("$bin" unmerged-card --board-cli "$unmerged_board" --pr-url 'lastgit://fold/cr/cr-notmerged' 2>&1)"
unmerged_rc=$?
set -e
if [ "$unmerged_rc" -eq 0 ]; then
  echo "FAIL: closeout must refuse an unmerged CR:" >&2
  echo "$unmerged_out" >&2
  exit 1
fi
echo "$unmerged_out" | grep -q 'FAILED unmerged-review' || {
  echo "FAIL: expected unmerged-review failure: $unmerged_out" >&2
  exit 1
}
if [ -s "$unmerged_moves" ]; then
  echo "FAIL: unmerged closeout must not move the card:" >&2
  cat "$unmerged_moves" >&2
  exit 1
fi

# todo cannot carry --pr-url; helper claims doing, restamps, then restamps after done.
todo_tmp="$(mktemp -d)"
todo_board="$todo_tmp/board"
todo_moves="$todo_tmp/moves"
todo_col="$todo_tmp/col"
todo_url="$todo_tmp/pr_url"
: >"$todo_moves"
echo todo >"$todo_col"
: >"$todo_url"
cat >"$todo_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
col_file="${TODO_COL:?}"
url_file="${TODO_URL:?}"
case "${1:-}" in
  show)
    col="$(cat "$col_file")"
    url="$(cat "$url_file")"
    printf '{"slug":"%s","column":"%s","pr_url":"%s","branch":"","body":"Repo: EdgeVector/fold\\nKind: pr\\n"}\n' "${2:-}" "$col" "$url"
    ;;
  add)
    col="$(cat "$col_file")"
    if [ "$col" = "todo" ] || [ "$col" = "backlog" ]; then
      echo "cannot carry --pr-url in default/$col" >&2
      exit 1
    fi
    # persist last --pr-url value
    prev=""
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--pr-url" ]; then
        prev="${2:-}"
        shift 2
        continue
      fi
      shift
    done
    printf '%s\n' "$prev" >"$url_file"
    exit 0
    ;;
  move)
    printf '%s %s\n' "${2:-}" "${3:-}" >>"${TODO_MOVES:?}"
    printf '%s\n' "${3:-}" >"$col_file"
    exit 0
    ;;
  *)
    echo "unexpected todo board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$todo_board"
export TODO_MOVES="$todo_moves"
export TODO_COL="$todo_col"
export TODO_URL="$todo_url"
cat >"$stub_bin/lastgit" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "cr" ] && [ "${2:-}" = "view" ]; then
  printf '{"state":"merged","merge_oid":"def456"}\n'
  exit 0
fi
exit 2
EOF
set +e
todo_out="$("$bin" todo-link-card --board-cli "$todo_board" --pr-url 'lastgit://fold/cr/cr-linked' 2>&1)"
todo_rc=$?
set -e
if [ "$todo_rc" -ne 0 ]; then
  echo "FAIL: todo start should restamp after claiming doing:" >&2
  echo "$todo_out" >&2
  exit 1
fi
grep -q 'todo-link-card doing' "$todo_moves" || {
  echo "FAIL: expected claim doing from todo:" >&2
  cat "$todo_moves" >&2
  exit 1
}
grep -q 'todo-link-card done' "$todo_moves" || {
  echo "FAIL: expected move to done:" >&2
  cat "$todo_moves" >&2
  exit 1
}
[ "$(cat "$todo_url")" = "lastgit://fold/cr/cr-linked" ] || {
  echo "FAIL: expected persisted pr_url, got $(cat "$todo_url")" >&2
  exit 1
}

# If fkanban is available and board works, optional live smoke is skipped here
# (routines CI should not thrash Tom's board).
echo "ok last-stack-card-closeout"
