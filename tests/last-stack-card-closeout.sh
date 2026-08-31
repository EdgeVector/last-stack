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
  mark)
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
  mark)
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

# A positive PROOF line is terminal evidence. The same merge and proof cannot
# close a card after a deliberate reopen. A new proof creates a new signal.
monotonic_tmp="$(mktemp -d)"
monotonic_board="$monotonic_tmp/board"
monotonic_moves="$monotonic_tmp/moves"
monotonic_marks="$monotonic_tmp/marks"
monotonic_col="$monotonic_tmp/col"
monotonic_url="$monotonic_tmp/pr_url"
monotonic_body="$monotonic_tmp/body"
: >"$monotonic_moves"
: >"$monotonic_marks"
echo doing >"$monotonic_col"
: >"$monotonic_url"
printf '%s\n' \
  'Repo: EdgeVector/last-stack' \
  'Kind: pr' \
  '## END STATE' \
  'The live closeout path passes.' \
  'PROOF: PASS live check at abc123' >"$monotonic_body"
cat >"$monotonic_board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
col_file="${MONOTONIC_COL:?}"
url_file="${MONOTONIC_URL:?}"
body_file="${MONOTONIC_BODY:?}"
case "${1:-}" in
  show)
    python3 - "${2:-}" "$(cat "$col_file")" "$(cat "$url_file")" "$body_file" <<'PY'
import json
import pathlib
import sys

slug, column, pr_url, body_path = sys.argv[1:]
print(json.dumps({
    "slug": slug,
    "column": column,
    "pr_url": pr_url,
    "branch": "",
    "body": pathlib.Path(body_path).read_text(),
}))
PY
    ;;
  add)
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "--pr-url" ]; then
        printf '%s\n' "${2:-}" >"$url_file"
        shift 2
        continue
      fi
      shift
    done
    ;;
  move)
    printf '%s %s\n' "${2:-}" "${3:-}" >>"${MONOTONIC_MOVES:?}"
    printf '%s\n' "${3:-}" >"$col_file"
    ;;
  mark)
    printf '%s\n' "${3:-}" >>"$body_file"
    printf '%s\n' "${3:-}" >>"${MONOTONIC_MARKS:?}"
    ;;
  *)
    echo "unexpected monotonic board: $*" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$monotonic_board"
export MONOTONIC_MOVES="$monotonic_moves"
export MONOTONIC_MARKS="$monotonic_marks"
export MONOTONIC_COL="$monotonic_col"
export MONOTONIC_URL="$monotonic_url"
export MONOTONIC_BODY="$monotonic_body"

first_out="$("$bin" monotonic-card --board-cli "$monotonic_board" --pr-url 'lastgit://last-stack/cr/cr-monotonic' 2>&1)" || {
  echo "FAIL: first close with PROOF must pass: $first_out" >&2
  exit 1
}
if echo "$first_out" | grep -q 'end-state-unverified'; then
  echo "FAIL: PROOF: PASS must satisfy the END STATE audit: $first_out" >&2
  exit 1
fi
grep -q '^CLOSEOUT-DECISION signal=.* state=closed$' "$monotonic_marks" || {
  echo "FAIL: first close must write a closeout decision:" >&2
  cat "$monotonic_marks" >&2
  exit 1
}
if grep -q '^CLOSED-ON-MERGE ' "$monotonic_marks"; then
  echo "FAIL: proven close must not carry an unverified marker:" >&2
  cat "$monotonic_marks" >&2
  exit 1
fi

echo doing >"$monotonic_col"
moves_before="$(wc -l <"$monotonic_moves" | tr -d ' ')"
set +e
reopen_out="$("$bin" monotonic-card --board-cli "$monotonic_board" 2>&1)"
reopen_rc=$?
set -e
if [ "$reopen_rc" -eq 0 ]; then
  echo "FAIL: the same signal must not close a reopened card: $reopen_out" >&2
  exit 1
fi
echo "$reopen_out" | grep -q 'FAILED reopened-same-signal' || {
  echo "FAIL: expected reopened-same-signal: $reopen_out" >&2
  exit 1
}
moves_after="$(wc -l <"$monotonic_moves" | tr -d ' ')"
[ "$moves_before" = "$moves_after" ] || {
  echo "FAIL: rejected reopen must not move the card" >&2
  exit 1
}

printf '%s\n' 'PROOF: VERIFIED new live check at def456' >>"$monotonic_body"
new_proof_out="$("$bin" monotonic-card --board-cli "$monotonic_board" 2>&1)" || {
  echo "FAIL: a new positive proof must create a new close signal: $new_proof_out" >&2
  exit 1
}
[ "$(grep -c '^CLOSEOUT-DECISION signal=.* state=closed$' "$monotonic_marks")" -eq 2 ] || {
  echo "FAIL: expected one decision per distinct terminal signal:" >&2
  cat "$monotonic_marks" >&2
  exit 1
}

# If fkanban is available and board works, optional live smoke is skipped here
# (routines CI should not thrash Tom's board).
echo "ok last-stack-card-closeout"
