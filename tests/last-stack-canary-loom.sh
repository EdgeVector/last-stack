#!/usr/bin/env bash
set -euo pipefail
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-canary-loom"
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
bash -n "$BIN"
bash -n "$ROOT/lib/canary-loom/loom-canary-step.sh"
[ -f "$ROOT/lib/canary-loom/lastdb-canary-release.json" ] || fail "graph missing"
grep -q 'last-stack-canary-loom' "$ROOT/routines/lastdb-canary-soak-watch.md" \
  || fail "soak-watch missing loom tick"
grep -q 'last-stack-canary-loom' "$ROOT/routines/lastdb-canary-dogfood.md" \
  || fail "dogfood missing loom start"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-canary-loom.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
export LAST_STACK_CANARY_LOOM_STAMP="$tmp/stamp.json"
out="$("$BIN" --dry-run --json --quiet)"
printf '%s\n' "$out" | grep -q 'ROUTINE_RESULT' || fail "missing ROUTINE_RESULT: $out"
out2="$("$BIN" --dry-run --start --oid abc123 --json --quiet)"
printf '%s\n' "$out2" | grep -q 'canary-abc123' || fail "start dry-run missing key: $out2"

mock_home="$tmp/home"
mkdir -p "$mock_home/.local/bin"
cat > "$mock_home/.local/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  ping|publish|validate) exit 0 ;;
  run)
    case "${FAKE_LOOM_MODE:-success}" in
      success)
        printf '%s\n' lx-test-canary 'status: running' 'state: BUILD_WAIT'
        ;;
      failed)
        printf '%s\n' lx-test-failed 'status: failed' 'state: FAILED' 'node BUILD_START#1 failed: permission denied'
        ;;
      error)
        printf '%s\n' 'loom transport denied: "state root"' >&2
        exit 9
        ;;
    esac
    ;;
  *) exit 2 ;;
esac
SH
chmod 755 "$mock_home/.local/bin/loom"

export LAST_STACK_CANARY_LOOM_STDOUT_LOG="$tmp/loom.stdout.log"
export LAST_STACK_CANARY_LOOM_STDERR_LOG="$tmp/loom.stderr.log"
out3="$(HOME="$mock_home" FAKE_LOOM_MODE=success "$BIN" --key canary-test --json --quiet)"
printf '%s\n' "$out3" | head -1 | jq -e '.outcome == "ok" and .execution == "lx-test-canary" and .status == "running"' >/dev/null \
  || fail "success result missing execution: $out3"
grep -q 'state: BUILD_WAIT' "$LAST_STACK_CANARY_LOOM_STDOUT_LOG" \
  || fail "loom stdout was not preserved"

set +e
out4="$(HOME="$mock_home" FAKE_LOOM_MODE=failed "$BIN" --key canary-failed --json --quiet)"
rc4=$?
set -e
[ "$rc4" -eq 3 ] || fail "failed loom status returned $rc4, expected 3"
printf '%s\n' "$out4" | head -1 | jq -e '.outcome == "error" and .execution == "lx-test-failed" and .status == "failed"' >/dev/null \
  || fail "failed result missing execution: $out4"

set +e
out5="$(HOME="$mock_home" FAKE_LOOM_MODE=error "$BIN" --key canary-error --json --quiet)"
rc5=$?
set -e
[ "$rc5" -eq 3 ] || fail "loom command error returned $rc5, expected 3"
printf '%s\n' "$out5" | head -1 | jq -e '.outcome == "error" and .execution == "" and .status == "unknown" and (.detail | contains("loom_rc=9"))' >/dev/null \
  || fail "command error was not structured: $out5"
grep -q 'loom transport denied' "$LAST_STACK_CANARY_LOOM_STDERR_LOG" \
  || fail "loom stderr was not preserved"
grep -q 'loom transport denied' "$LAST_STACK_CANARY_LOOM_STAMP" \
  || fail "loom stderr was not summarized in the stamp"

LOOM_INPUT='{"main_oid":"abc","max_attempts":3}' "$ROOT/lib/canary-loom/loom-canary-step.sh" PROBE | grep -q 'verdict":"green"' \
  || fail "stand-in probe not green"
echo ok

[ -f "$ROOT/lib/canary-loom/lastdb-safe-upgrade.json" ] || fail "graph A missing"
