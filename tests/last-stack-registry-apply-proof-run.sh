#!/usr/bin/env bash
# The launchd/routine wrapper: lock, quiet refusal, real errors alert.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-registry-apply-proof-run"
work="$(mktemp -d "${TMPDIR:-/tmp}/apply-run.XXXXXX")"
trap 'rm -rf "$work"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
export HOME="$work/home"; mkdir -p "$HOME"
export LAST_STACK_REGISTRY_APPLY_STATE_DIR="$work/state"

fake() { printf '#!/usr/bin/env bash\necho "args: $*"\n%s\nexit %s\n' "$2" "$1" >"$work/apply"; chmod +x "$work/apply"; }
export LAST_STACK_REGISTRY_APPLY_PROOF_BIN="$work/apply"

fake 0 'echo "APPLY_PROOF status=pr run=7 build=b apps=9"'
"$RUNNER" >"$work/o" || fail "applied must exit 0"
grep -q -- '--latest' "$work/o" || fail "the wrapper must pass --latest"
grep -q 'rc=0 APPLY_PROOF status=pr run=7' "$work/state/apply.log" || fail "log line: $(cat "$work/state/apply.log")"
[ ! -e "$work/state/lock" ] || fail "the lock must be released"

fake 3 'echo "APPLY_PROOF status=refused reason=open-row-pr open=500"'
"$RUNNER" >/dev/null || fail "an open row PR is a quiet wait (exit 0)"
fake 3 'echo "APPLY_PROOF status=refused reason=verification"'
"$RUNNER" >/dev/null || fail "a refusal by a rule is logged, exit 0"
grep -q 'reason=verification' "$work/state/apply.log" || fail "refusal reason must be logged"

fake 1 'echo boom >&2'
if "$RUNNER" >/dev/null 2>&1; then fail "a real error must exit non-zero"; fi

# a live lock skips; a dead lock is cleared
mkdir -p "$work/state/lock"; echo $$ >"$work/state/lock/pid"
fake 0 'echo "APPLY_PROOF status=pr run=8"'
out="$("$RUNNER")"; grep -q 'skipped' <<<"$out" || fail "live lock must skip: $out"
echo 999999 >"$work/state/lock/pid"
"$RUNNER" >/dev/null || fail "a dead lock must be cleared"

echo "ok last-stack-registry-apply-proof-run"
