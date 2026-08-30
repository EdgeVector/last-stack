#!/usr/bin/env bash
# A bounded lifecycle-close pass must always terminate and always report.
#
# `--limit` alone does not bound the pass: 200 slugs with a 20s read timeout and
# two retries is a 200-minute worst case, and the JSON prints only at the end.
# On a loaded node that pass outlived its caller and produced zero bytes
# (papercut-lifecycle-close-hangs-on-brain-get-subprocess). Case 1 reproduces
# that exactly: it hangs past 90s on the pre-fix helper and stops at the budget
# with the fix.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HELPER="$ROOT/bin/last-stack-papercut-lifecycle-close"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

bin_dir="$tmp/bin"
mkdir -p "$bin_dir"

# kanban only has to exist. The registry read returns non-zero, so the registry
# branch is skipped and the review branch is what gets measured.
cat >"$bin_dir/kanban" <<'SH'
#!/usr/bin/env bash
exit 1
SH
chmod +x "$bin_dir/kanban"

make_brain() { # $1 = seconds each `get <slug>` sleeps
  cat >"$bin_dir/brain" <<SH
#!/usr/bin/env bash
set -uo pipefail
if [ "\${1:-}" = get ] && [ "\${2:-}" = papercut-prevention-registry ]; then
  exit 1
fi
if [ "\${1:-}" = papercut ] && [ "\${2:-}" = list ]; then
  printf '['
  for i in \$(seq 1 200); do
    [ "\$i" -eq 1 ] || printf ','
    printf '{"slug":"papercut-slow-%s","status":"open"}' "\$i"
  done
  printf ']\n'
  exit 0
fi
if [ "\${1:-}" = get ]; then
  sleep $1
  printf '{"slug":"%s","status":"open","body":"Status: OPEN"}\n' "\${2:-}"
  exit 0
fi
exit 2
SH
  chmod +x "$bin_dir/brain"
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- case 1: a slow node must not turn a bounded --limit into an unbounded run.
make_brain 2

start=$(date +%s)
set +e
PATH="$bin_dir:$PATH" timeout 90 "$HELPER" --limit 200 --budget-seconds 6 --read-timeout 5 --json >"$tmp/slow.json" 2>"$tmp/slow.err"
rc=$?
set -e
elapsed=$(( $(date +%s) - start ))

[ "$rc" -ne 124 ] || fail "slow node: pass did not terminate inside 90s"
[ "$elapsed" -lt 45 ] || fail "slow node: pass took ${elapsed}s against a 6s budget"
[ -s "$tmp/slow.json" ] || fail "slow node: pass produced no JSON result"
python3 - "$tmp/slow.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("budget_exhausted") is True, f"budget_exhausted not set: {d.get('budget_exhausted')!r}"
assert int(d.get("unread") or 0) > 0, f"unread not reported: {d.get('unread')!r}"
assert d.get("budget_seconds") == 6, f"budget_seconds not echoed: {d.get('budget_seconds')!r}"
PY
echo "ok: slow node stopped at the budget and still reported (${elapsed}s)"

# --- case 2: a pass that finishes inside its budget reports an unexhausted one.
# Without this, "always sets budget_exhausted=true" would satisfy case 1.
make_brain 0

set +e
PATH="$bin_dir:$PATH" timeout 90 "$HELPER" --limit 5 --budget-seconds 60 --read-timeout 5 --json >"$tmp/fast.json" 2>"$tmp/fast.err"
rc=$?
set -e
[ "$rc" -ne 124 ] || fail "fast node: pass did not terminate inside 90s"
python3 - "$tmp/fast.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("budget_exhausted") is False, f"budget wrongly reported exhausted: {d!r}"
assert int(d.get("unread") or 0) == 0, f"unread should be 0: {d.get('unread')!r}"
assert int(d.get("checked") or 0) == 5, f"checked should be 5: {d.get('checked')!r}"
PY
echo "ok: a pass inside its budget reports budget_exhausted=false"

# --- case 3: --budget-seconds 0 keeps the old unbounded behaviour available.
set +e
PATH="$bin_dir:$PATH" timeout 90 "$HELPER" --limit 5 --budget-seconds 0 --read-timeout 5 --json >"$tmp/none.json" 2>"$tmp/none.err"
rc=$?
set -e
[ "$rc" -ne 124 ] || fail "no budget: pass did not terminate inside 90s"
python3 - "$tmp/none.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d.get("budget_seconds") == 0, f"budget_seconds not echoed: {d.get('budget_seconds')!r}"
assert d.get("budget_exhausted") is False, f"disabled budget must never exhaust: {d!r}"
PY
echo "ok: --budget-seconds 0 disables the budget"

echo "PASS last-stack-papercut-lifecycle-close-budget"
