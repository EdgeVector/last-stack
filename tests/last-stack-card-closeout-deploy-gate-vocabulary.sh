#!/usr/bin/env bash
# The deploy-pipeline proof gate in last-stack-card-closeout has been broken
# TWICE by a scanner status nobody classified, and each time the repair was one
# more `=` test:
#
#   2026-08-08  `missing` on a repo with no producer jammed a merged, deployed
#               fold card in `doing` for 10h.
#   2026-10-01  `retired` (PR #172) took the refusal arm, and ALL FOUR repos the
#               scanner covers reported `retired`, so the gate was unsatisfiable
#               for every one of them.
#               papercut-card-closeout-deploy-gate-refuses-the-retired-status-the-scanner-now-emits-20261001
#
# So this test does not check the two instances. It checks the CLASS, in both
# directions:
#   1. every status the scanner DECLARES has an explicit arm in the consumer
#   2. every status the scanner ASSIGNS is declared
# plus the behaviour that makes the classification load-bearing, including the
# refusals that a naive "key on blocked" rewrite would silently turn into passes.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
closeout="$ROOT/bin/last-stack-card-closeout"
scan="$ROOT/bin/last-stack-pipeline-deploy-scan"
chmod +x "$closeout" "$scan"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/cc-deploy-vocab.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# 1. consumer >= declaration: every declared status has an explicit case arm
# ---------------------------------------------------------------------------
declared="$("$scan" --statuses)"
[ -n "$declared" ] || fail "scanner --statuses printed nothing"

# The classification block: from `case "$gate_state" in` to its `esac`.
classify="$(awk '
  /case "\$gate_state" in/ { inblock = 1 }
  inblock { print }
  inblock && /^[[:space:]]*esac[[:space:]]*$/ { exit }
' "$closeout")"
[ -n "$classify" ] || fail "could not find the gate_state classification case in $closeout"

# Patterns, one per arm, excluding the `*)` catch-all: `a|b) gate_class=x ;;`
arms="$(printf '%s\n' "$classify" \
  | sed -n 's/^[[:space:]]*\([a-z|-]*\))[[:space:]]*gate_class=.*/\1/p' \
  | tr '|' '\n' | sed '/^$/d' | sort -u)"
[ -n "$arms" ] || fail "parsed zero classification arms out of the case block"

missing=""
while IFS= read -r st; do
  [ -n "$st" ] || continue
  printf '%s\n' "$arms" | grep -qxF "$st" || missing="$missing $st"
done <<EOF
$declared
EOF
[ -z "$missing" ] || fail "scanner statuses with no explicit arm in last-stack-card-closeout:$missing
  Classify each one as pass / no-live-producer / refuse. Do not add another \`=\` test,
  and do not key the gate on \`blocked\` alone — pending-in-grace and unknown are
  blocked=false and must still refuse."

# The catch-all must exist too: an unclassified status has to refuse loudly
# rather than fall through to the pass arm.
printf '%s\n' "$classify" | grep -qE '^\s*\*\)\s*gate_class=unclassified' \
  || fail "the classification case has no \`*) gate_class=unclassified\` catch-all"

# ---------------------------------------------------------------------------
# 2. declaration >= assignments: a status the scanner can emit must be declared
# ---------------------------------------------------------------------------
# Literal `pipe_status="<word>"` assignments, plus the synthesized --repo rows
# and the missing-log row, which are written as `<repo>|<status>|…` literals.
assigned="$(
  {
    sed -n 's/.*pipe_status="\([a-z][a-z-]*\)".*/\1/p' "$scan"
    sed -n 's/.*results+=("\$repo|\([a-z][a-z-]*\)|.*/\1/p' "$scan"
    sed -n 's/.*filtered=("\$repo_filter|\([a-z][a-z-]*\)|.*/\1/p' "$scan"
  } | sort -u
)"
[ -n "$assigned" ] || fail "parsed zero status assignments out of $scan"

undeclared=""
while IFS= read -r st; do
  [ -n "$st" ] || continue
  printf '%s\n' "$declared" | grep -qxF "$st" || undeclared="$undeclared $st"
done <<EOF
$assigned
EOF
[ -z "$undeclared" ] || fail "statuses assigned in last-stack-pipeline-deploy-scan but absent from DEPLOY_SCAN_STATUSES:$undeclared
  Add them to the declaration so consumers are checked against the real vocabulary."

# ---------------------------------------------------------------------------
# behavioural fixture
# ---------------------------------------------------------------------------
deploy_root="$tmp/deploy-root"
mkdir -p "$deploy_root/deploy-vocabrepo"
log="$deploy_root/deploy-vocabrepo/deploy.log"

board="$tmp/board"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
state="${FAKE_BOARD_STATE:?}"
body="${FAKE_BOARD_BODY:?}"
moves="${FAKE_BOARD_MOVES:?}"
case "${1:-}" in
  show)
    printf '{"slug":"%s","repo":"EdgeVector/vocabrepo","column":"%s","body":%s}\n' \
      "$2" "$(cat "$state")" "$(python3 -c 'import json,sys; print(json.dumps(open(sys.argv[1]).read()))' "$body")"
    ;;
  move)
    printf '%s %s %s\n' "$2" "$3" "${4:-}" >>"$moves"
    printf '%s\n' "$3" >"$state"
    ;;
  add|mark) exit 0 ;;
  *) echo "unexpected fake board command: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$board"

cbody="$tmp/body"
cat >"$cbody" <<'EOF'
Repo: EdgeVector/vocabrepo
Base: main
Kind: pr
Requires-Deploy: deploy-pipeline

## DONE WHEN
Merged plus a terminal deploy-pipeline verdict.
EOF

# $1 label, $2 expect (pass|refuse), $3 expected stderr substring,
# rest: extra env assignments for the closeout call
run_case() {
  local label="$1" expect="$2" needle="$3"; shift 3
  local state="$tmp/state-$label" moves="$tmp/moves-$label" out="$tmp/out-$label"
  printf 'doing\n' >"$state"
  : >"$moves"
  local rc=0
  env "$@" \
    LASTGIT_DEPLOY_ROOT="$deploy_root" \
    FAKE_BOARD_STATE="$state" \
    FAKE_BOARD_BODY="$cbody" \
    FAKE_BOARD_MOVES="$moves" \
    "$closeout" "vocab-$label" --board-cli "$board" >"$out" 2>&1 || rc=$?
  grep -qF "$needle" "$out" || {
    cat "$out" >&2
    fail "$label: expected stderr to contain '$needle'"
  }
  if [ "$expect" = "pass" ]; then
    [ "$rc" -eq 0 ] || { cat "$out" >&2; fail "$label: expected closeout to succeed, rc=$rc"; }
    grep -qE "^vocab-$label done" "$moves" || fail "$label: card was not moved to done"
  else
    [ "$rc" -ne 0 ] || { cat "$out" >&2; fail "$label: expected closeout to refuse, rc=0"; }
    [ ! -s "$moves" ] || { cat "$moves" >&2; fail "$label: refused gate still moved the card"; }
  fi
}

# --- retired / blocked=false CLOSES the card. This is the 2026-10-01 defect:
#     all four covered repos reported `retired` and every one was refused.
printf 'success good-sha deploy-pipeline\n' >"$log"
run_case retired pass 'deploy gate retired' \
  LAST_STACK_DEPLOY_SCAN_LAUNCHCTL_BIN=/usr/bin/false

# From here on the watcher is "loaded", so the scanner reports the log's own
# verdict rather than retiring it.
loaded=(LAST_STACK_DEPLOY_SCAN_LAUNCHCTL_BIN=/usr/bin/true)

# --- success still closes (the arm that always worked; keeps the refactor honest)
printf 'success good-sha deploy-pipeline\n' >"$log"
run_case success pass 'ok slug=vocab-success column=done' "${loaded[@]}"
grep -qE '^vocab-success done' "$tmp/moves-success" \
  || fail "success: the card did not reach done"

# --- pending WITHIN GRACE must still refuse, although blocked=false. A rewrite
#     keyed on `blocked` would pass this and close a card whose deploy is still
#     in flight (papercut-pipeline-deploy-scan-misses-in-progress-20260924).
printf 'pending inflight-sha deploy-pipeline from x:refs/heads/main:accepted\n' >"$log"
run_case pending_in_grace refuse 'deploy gate pending' "${loaded[@]}"
grep -qF 'status=pending' "$tmp/out-pending_in_grace" \
  || fail "pending_in_grace: the refusal did not name status=pending"

# --- unknown must refuse, although blocked=false: the scanner could not tell.
printf 'noise with no terminal line\n' >"$log"
run_case unknown refuse 'status=unknown' "${loaded[@]}"

# --- failure refuses (blocked=true)
printf 'failure bad-sha deploy-pipeline\n' >"$log"
run_case failure refuse 'status=failure' "${loaded[@]}"

# --- a status this consumer has never been taught refuses LOUDLY and names it,
#     instead of taking a pass arm. Driven through a stub scanner, because the
#     real one can only emit what it declares.
# A stub scanner, so the consumer can be fed a row the real scanner cannot
# produce. STUB_STATUS / STUB_BLOCKED pick the row; --statuses stays minimal on
# purpose, since the unclassified message reports what the scanner declares.
stub="$tmp/stub-scan"
cat >"$stub" <<'EOF'
#!/usr/bin/env bash
set -eu
case "${1:-}" in
  --statuses) printf 'success\nfailure\n'; exit 0 ;;
esac
printf '[{"repo":"vocabrepo","status":"%s","sha":"s","blocked":%s,"reason":"stub row","log":"x","log_mtime":0}]' \
  "${STUB_STATUS:?}" "${STUB_BLOCKED:?}"
EOF
chmod +x "$stub"

# The sentinel is deliberately a name no scanner would ever adopt. An earlier
# draft used a plausible one (`quiesced`) and an --expect green probe caught the
# consequence: classifying that status later -- the correct way to extend this --
# would have broken this very case, so the guard would have refused a legitimate
# change.
run_case unclassified refuse 'deploy-gate-unclassified-status=never-a-real-status' \
  LAST_STACK_DEPLOY_SCAN_BIN="$stub" STUB_STATUS=never-a-real-status STUB_BLOCKED=false

# --- blocked=true must refuse even on a status this gate otherwise PASSES.
# Neither of the next two rows is reachable from today's scanner (it only sets
# blocked on failure and on pending-past-grace, and it forces blocked=false when
# it retires a repo), so these cases exist to pin the defence-in-depth clauses
# that no fixture built from the real scanner can reach. Without them, deleting
# either `blocked` test is a silent change: a future scanner that reports
# `success blocked=true` would close the card on the strength of the word
# `success` alone.
run_case success_but_blocked refuse 'status=success' \
  LAST_STACK_DEPLOY_SCAN_BIN="$stub" STUB_STATUS=success STUB_BLOCKED=true

run_case retired_but_blocked refuse 'status=retired' \
  LAST_STACK_DEPLOY_SCAN_BIN="$stub" STUB_STATUS=retired STUB_BLOCKED=true
if grep -qF 'class=no-live-producer' "$tmp/out-retired_but_blocked"; then
  cat "$tmp/out-retired_but_blocked" >&2
  fail "retired_but_blocked: took the no-live-producer pass arm despite blocked=true"
fi

echo "ok: last-stack-card-closeout-deploy-gate-vocabulary"
