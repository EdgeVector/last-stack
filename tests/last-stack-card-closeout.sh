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

# Restamp add failure must not block move-to-done (merged-CR closeout).
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
export REESTAMP_MOVES="$restamp_moves"
export REESTAMP_ADDS="$restamp_adds"
export REESTAMP_COL="$restamp_tmp/col"
echo doing >"$REESTAMP_COL"
set +e
restamp_out="$("$bin" restamp-card --board-cli "$restamp_board" --pr-url 'lastgit://last-stack/cr/cr-mskqwa3y-78c9`' 2>&1)"
restamp_rc=$?
set -e
if [ "$restamp_rc" -ne 0 ]; then
  echo "FAIL: card-closeout should still exit 0 when restamp add fails:" >&2
  echo "$restamp_out" >&2
  exit 1
fi
echo "$restamp_out" | grep -q 'WARN board-add-failed' || {
  echo "FAIL: expected restamp WARN: $restamp_out" >&2
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

# If fkanban is available and board works, optional live smoke is skipped here
# (routines CI should not thrash Tom's board).
echo "ok last-stack-card-closeout"
