#!/usr/bin/env bash
# The two callers of the candidate gate's primary-rows step (step 0):
#   - the hourly reconcile gate starts `--primary-rows-only --detach` before
#     its own verdict, keeps its stdout contract, and skips it on a dry run or
#     when LAST_STACK_CANARY_PRIMARY_ROWS_HOURLY=0
#   - lastdb-safe-upgrade starts the same step after the live post-check is
#     GREEN and before it prints the live VERDICT: GREEN, detached, and never
#     on a probe-only or RED path
# A primary moved by any path other than the candidate gate froze every
# host-track install until the nightly pass, because nothing proved `next`
# rows for its build.
# papercut-host-track-refresh-held-hours-after-lastdb-cutover-no-registry-proof-trigger-20260926
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RECONCILE="$ROOT/bin/last-stack-canary-reconcile-gate"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
work="$(mktemp -d "${TMPDIR:-/tmp}/primary-rows-triggers.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

calls="$work/calls.log"
cat >"$work/candidate-gate" <<EOF
#!/usr/bin/env bash
echo "candidate-gate \$*" >>"$calls"
echo "PRIMARY_ROWS result=noop stage=primary-rows evidence=rows_present"
EOF
cat >"$work/soak-gate" <<EOF
#!/usr/bin/env bash
echo "soak-gate \$*" >>"$calls"
echo "CANARY_V2_GATE verdict=window-open"
echo "ROUTINE_RESULT outcome=ok detail=verdict=window-open"
EOF
chmod +x "$work/candidate-gate" "$work/soak-gate"

run_reconcile() {
  : >"$calls"
  env LAST_STACK_CANARY_PRIMARY_ROWS_GATE="$work/candidate-gate" \
    LAST_STACK_CANARY_SOAK_WATCH_GATE="$work/soak-gate" \
    "$@"
}

# ── hourly: the reconcile gate ─────────────────────────────────────────────
out="$(run_reconcile "$RECONCILE" 2>"$work/err")"
[ "$(sed -n '1p' "$calls")" = "candidate-gate --primary-rows-only --detach" ] \
  || fail "reconcile gate did not start the detached primary-rows step first: $(cat "$calls")"
[ "$(sed -n '2p' "$calls")" = "soak-gate " ] || fail "reconcile gate did not run the soak gate after it: $(cat "$calls")"
grep -q 'PRIMARY_ROWS' <<<"$out" && fail "the PRIMARY_ROWS line leaked into the verdict stdout: $out"
grep -q '^PRIMARY_ROWS result=noop' "$work/err" || fail "the PRIMARY_ROWS line is not on stderr: $(cat "$work/err")"
[ "$(grep -c '^ROUTINE_RESULT' <<<"$out")" = 1 ] || fail "reconcile stdout must carry exactly the soak gate's ROUTINE_RESULT: $out"

out="$(run_reconcile "$RECONCILE" --dry-run 2>/dev/null)"
grep -q 'candidate-gate' "$calls" && fail "--dry-run still started the primary-rows step"
grep -q '^soak-gate --dry-run' "$calls" || fail "--dry-run not passed to the soak gate"
run_reconcile env LAST_STACK_CANARY_V2_DRY_RUN=1 "$RECONCILE" >/dev/null 2>&1
grep -q 'candidate-gate' "$calls" && fail "LAST_STACK_CANARY_V2_DRY_RUN=1 still started the primary-rows step"
run_reconcile env LAST_STACK_CANARY_PRIMARY_ROWS_HOURLY=0 "$RECONCILE" >/dev/null 2>&1
grep -q 'candidate-gate' "$calls" && fail "LAST_STACK_CANARY_PRIMARY_ROWS_HOURLY=0 still started the step"

# A failing step never fails the verdict.
cat >"$work/candidate-gate" <<EOF
#!/usr/bin/env bash
echo "candidate-gate \$*" >>"$calls"
echo "PRIMARY_ROWS result=unknown evidence=probe_failed"
exit 1
EOF
out="$(run_reconcile "$RECONCILE" 2>/dev/null)" || fail "a failing primary-rows step failed the reconcile gate"
grep -q '^ROUTINE_RESULT outcome=ok' <<<"$out" || fail "verdict lost after a failing step: $out"

# ── lastdb-safe-upgrade: the live GREEN tail ───────────────────────────────
# The live path needs a real launchd primary, so the order is checked on the
# driver text, the same way the launchd-job test checks its GREEN bar.
call_line="$(awk '/--primary-rows-only --detach/{print NR; exit}' "$DRIVER")"
postcheck_line="$(awk '/STEP 4\/4: live post-check GREEN/{print NR; exit}' "$DRIVER")"
live_green_line="$(awk '/^echo "VERDICT: GREEN"$/{print NR}' "$DRIVER" | tail -1)"
[ -n "$call_line" ] || fail "safe-upgrade does not start the primary-rows step"
[ -n "$postcheck_line" ] && [ -n "$live_green_line" ] || fail "could not locate the live post-check / VERDICT lines"
[ "$postcheck_line" -lt "$call_line" ] || fail "primary-rows runs before the live post-check is GREEN"
[ "$call_line" -lt "$live_green_line" ] || fail "primary-rows runs after the live VERDICT: GREEN"
[ "$(grep -c -- '--primary-rows-only' "$DRIVER")" = 1 ] \
  || fail "safe-upgrade must start primary-rows exactly once (the live GREEN tail only)"
probe_only_line="$(awk '/VERDICT: GREEN_PROBE_ONLY/{print NR; exit}' "$DRIVER")"
[ -n "$probe_only_line" ] && [ "$probe_only_line" -lt "$call_line" ] \
  || fail "a probe-only run must never reach the primary-rows step"
grep -q 'LASTDB_SAFE_UPGRADE_PRIMARY_ROWS:-1' "$DRIVER" || fail "safe-upgrade primary-rows has no kill switch"
# The step never runs a cutover: the only flags passed are these two.
grep -- '--primary-rows-only' "$DRIVER" | grep -q -- '--primary-rows-only --detach' \
  || fail "safe-upgrade must detach the step so the verdict is not delayed"

echo "PASS last-stack-canary-primary-rows-triggers"
