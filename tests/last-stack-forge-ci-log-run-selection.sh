#!/usr/bin/env bash
# The CI-log helper must not answer a question about a commit with a green run
# while a red sibling run exists for the same commit, and must not read a
# pull-request number as a run number.
#
# Measured 2026-09-06 over EdgeVector/fold's complete task history (22366 rows,
# 4589 distinct heads): on 288 heads the old `.[0]` resolver picked a run with
# NO failing task while a red sibling existed, and 279 heads have failing jobs
# in more than one run — so "prefer a failing run" would have hidden a red
# sibling on almost as many heads as it fixed. Both papercuts collected
# recurrences for three weeks from four different routines, each reading a
# "Job succeeded" tail as CI evidence for a commit that was failing.
#
# Papercuts:
#   papercut-forge-ci-log-sha-selects-first-run-and-hides-failing-sibling
#   papercut-last-stack-forge-ci-log-pr-number-as-run-number
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CMD="$ROOT/bin/last-stack-forge-ci-log"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# ── Fixture ───────────────────────────────────────────────────────────────────
# One head with two runs, the 288-head shape: run 100 all green (and listed
# FIRST, so the old resolver picks it), run 101 carrying the only failure.
SHA=deadbeefcafe1234567890abcdef1234567890ab
PRHEAD=999888777666555444333222111000aaabbbccc

mkdir -p "$tmp/stub" "$tmp/logs"
PATH="$tmp/stub:$PATH"; export PATH
export FORGE_TOKEN=fixture-token
export FORGE_ACTIONS_LOG_ROOT="$tmp/logs"
export FORGE_CI_LOG_TAIL=0

# Job logs on disk, sharded task-id % 256 exactly as Forgejo writes them.
put_log() { # task-id, text
  local shard; shard="$(printf '%02x' "$(( $1 % 256 ))")"
  mkdir -p "$tmp/logs/EdgeVector/fold/$shard"
  printf '%s\n' "$2" > "$tmp/logs/EdgeVector/fold/$shard/$1.log"
}
put_log 1000 'GREEN-GATE-LOG-BODY'
put_log 1001 'RED-SIBLING-LOG-BODY'
put_log 1002 'STALE-OLD-RUN-LOG-BODY'

cat > "$tmp/tasks.json" <<JSON
{"total_count":3,"workflow_runs":[
 {"id":1000,"run_number":100,"status":"success","name":"ci-required","head_sha":"$SHA"},
 {"id":1001,"run_number":101,"status":"failure","name":"heavy clippy","head_sha":"$SHA"},
 {"id":1002,"run_number":42,"status":"success","name":"ancient","head_sha":"0000000000000000000000000000000000000000"}
]}
JSON

# `curl` stands in for the forge. Dispatches on the URL, which is the last arg.
cat > "$tmp/stub/curl" <<'STUB'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in http*) url="$a" ;; esac; done
case "$url" in
  */actions/tasks*) cat "$FIXTURE_TASKS"; exit 0 ;;
  */pulls/42)  exit 22 ;;                 # 42 is not a pull request -> curl -f 404
  */pulls/*)   printf '{"head":{"sha":"%s"}}\n' "$FIXTURE_PRHEAD"; exit 0 ;;
esac
exit 22
STUB
chmod +x "$tmp/stub/curl"
export FIXTURE_TASKS="$tmp/tasks.json" FIXTURE_PRHEAD="$PRHEAD"

run() { # -> writes $tmp/out, $tmp/err, echoes rc
  local rc=0
  "$CMD" "$@" > "$tmp/out" 2> "$tmp/err" || rc=$?
  echo "$rc"
}

# ── 1. --sha must name EVERY run for the head ─────────────────────────────────
rc="$(run EdgeVector/fold --sha "$SHA")"
[ "$rc" = 0 ] || fail "--sha exited $rc, expected 0. stderr: $(cat "$tmp/err")"
# Anchored on the resolved-runs line itself. A bare grep for the numbers passes
# on the jobs table below it, so it would stay green with a one-run resolver —
# which is exactly what the first mutation probe of this test demonstrated.
resolved="$(grep '^resolved sha' "$tmp/err" || true)"
[ -n "$resolved" ] || fail "--sha printed no resolved-runs line"
case "$resolved" in
  *100*) ;; *) fail "resolved-runs line did not name run 100: $resolved" ;;
esac
case "$resolved" in
  *101*) ;; *) fail "resolved-runs line did not name the sibling run 101: $resolved" ;;
esac

# ── 2. the red sibling's log must be dumped ───────────────────────────────────
# This is the whole defect: eight recorded recurrences all ended with a reader
# taking a "Job succeeded" tail as evidence for a commit that was failing.
grep -q 'RED-SIBLING-LOG-BODY' "$tmp/out" \
  || fail "--sha did not dump the failing sibling run's log"

# ── 3. and the green run must NOT be dumped when a red job exists ─────────────
# A dump of everything would also technically contain the red log, so assert the
# selection, not just the presence.
grep -q 'GREEN-GATE-LOG-BODY' "$tmp/out" \
  && fail "--sha dumped a SUCCEEDED job while a failing job existed for the head"

# ── 4. a PR number must not be read as a run number ───────────────────────────
# `... EdgeVector/fold 1912` and `... EdgeVector/lastgit 554` each dumped a
# months-old succeeded run. Both numbers WERE live runs, so the check has to be
# "is it also a live PR whose head ran elsewhere", not "does this run exist".
rc="$(run EdgeVector/fold 100)"
[ "$rc" = 2 ] || fail "a PR number was accepted as a run number (rc=$rc)"
grep -q -- "--sha $PRHEAD" "$tmp/err" \
  || fail "the refusal did not name the --sha command for the PR's own head"
grep -q 'STALE-OLD-RUN-LOG-BODY\|GREEN-GATE-LOG-BODY' "$tmp/out" \
  && fail "the refusal still printed a job log"

# ── 5. --run forces the number through ────────────────────────────────────────
rc="$(run EdgeVector/fold --run 100)"
[ "$rc" = 0 ] || fail "--run did not bypass the PR check (rc=$rc): $(cat "$tmp/err")"
grep -q 'GREEN-GATE-LOG-BODY' "$tmp/out" || fail "--run 100 did not print run 100's log"

# ── 6. a number that is NOT a pull request still works ────────────────────────
rc="$(run EdgeVector/fold 42)"
[ "$rc" = 0 ] || fail "a plain run number was refused (rc=$rc): $(cat "$tmp/err")"
grep -q 'STALE-OLD-RUN-LOG-BODY' "$tmp/out" || fail "run 42 did not print its log"

# ── 7. no message may blame list truncation ───────────────────────────────────
# Measured 2026-09-06: the tasks endpoint IGNORES ?limit and returns the repo's
# complete history (fold: total_count == returned == 22366). The old hints
# ("in the last 100 tasks", "list truncated? raise limit") sent readers to raise
# a limit that was never applied, on a defect that was pure selection.
rc="$(run EdgeVector/fold --sha 0123456789abcdef0123456789abcdef01234567)"
[ "$rc" = 4 ] || fail "an unknown sha exited $rc, expected 4"
grep -qi 'truncat\|raise limit\|last 100' "$tmp/err" \
  && fail "an error message still blames list truncation, which was measured false"

# Comments are stripped first: a comment cannot be printed, and the rule itself
# has to be written down somewhere in this file.
grep -v '^[[:space:]]*#' "$CMD" | grep -qi 'truncat\|raise limit\|last 100' \
  && fail "the helper still carries a truncation hint the corpus disproved"

echo "OK: last-stack-forge-ci-log run selection"
