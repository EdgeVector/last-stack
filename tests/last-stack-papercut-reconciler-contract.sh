#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
prompt="$ROOT/routines/papercut-reconciler.md"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

mode="${1:-all}"
case "$mode" in
  all|prompt) ;;
  *) echo "usage: $0 [all|prompt]" >&2; exit 2 ;;
esac

# The finite behavior tests cover batching, holds, admission, reports, and
# pause preservation. This fixture binds the installed prompt to that one
# reviewed entrypoint instead of retaining the retired AI prompt's prose.
assert_finite_dispatch() {
  local candidate="$1" dispatch
  dispatch="$(awk '
    /^```bash$/ { in_block = 1; next }
    /^```$/ { in_block = 0; next }
    in_block { print }
  ' "$candidate")"
  [ "$dispatch" = '"${LAST_STACK_ROOT:-$HOME/.last-stack}/bin/last-stack-papercut-reconcile-finite" --once --routine-result' ] \
    || { echo "FAIL: finite installed dispatch command differs" >&2; return 1; }
}

assert_finite_dispatch "$prompt"
retired_prompt="$tmp/retired-prompt.md"
sed 's/last-stack-papercut-reconcile-finite" --once --routine-result/last-stack-papercut-lifecycle-close" --limit 200/' \
  "$prompt" >"$retired_prompt"
cmp -s "$prompt" "$retired_prompt" \
  && { echo "FAIL: retired dispatch fixture changed no byte" >&2; exit 1; }
if assert_finite_dispatch "$retired_prompt" >"$tmp/retired.out" 2>"$tmp/retired.err"; then
  echo "FAIL: finite prompt accepts retired lifecycle dispatch" >&2
  exit 1
fi
grep -q '^FAIL: finite installed dispatch command differs$' "$tmp/retired.err"
if [ "$mode" = prompt ]; then
  printf 'ok finite papercut prompt dispatch contract\n'
  exit 0
fi

queue_helper="$ROOT/bin/last-stack-papercut-queue"
[ -x "$queue_helper" ] || { echo "missing executable queue helper" >&2; exit 1; }
ledger_helper="$ROOT/bin/last-stack-papercut-ledger-append"
[ -x "$ledger_helper" ] || { echo "missing executable ledger-append helper" >&2; exit 1; }
jq -e '
  .apps[] | select(.app == "last-stack") | .links[] |
  select(.source == "bin/last-stack-papercut-ledger-append" and
         .target == "$HOME/.local/bin/last-stack-papercut-ledger-append")
' "$ROOT/config/host-track/apps.json" >/dev/null
jq -e '
  .apps[] | select(.app == "last-stack") | .links[] |
  select(.source == "bin/last-stack-papercut-queue" and
         .target == "$HOME/.local/bin/last-stack-papercut-queue")
' "$ROOT/config/host-track/apps.json" >/dev/null

helper="$ROOT/bin/last-stack-papercut-lifecycle-close"
[ -x "$helper" ] || { echo "missing executable lifecycle helper" >&2; exit 1; }

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"
records="$tmp/records.json"
cat >"$records" <<'JSON'
[
  {
    "slug": "papercut-demo-helper-drift",
    "title": "Demo helper drift",
    "body": "Status: OPEN\nEvidence: https://github.com/EdgeVector/last-stack/pull/501\n"
  }
]
JSON
cat >"$fake_bin/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-prevention-registry --type reference")
    cat <<'EOF'
### papercut-demo-helper-drift
- Prevention: COVERED
- Card: `demo-card`
EOF
    ;;
  "get papercut-demo-helper-drift --type papercut --json")
    printf '%s\n' '{"slug":"papercut-demo-helper-drift","title":"Demo helper drift","status":"open","body":"Evidence: https://github.com/EdgeVector/last-stack/pull/501"}'
    ;;
  "papercut list --status open --index-only --json"|"papercut list --status open --json")
    printf '%s\n' '{"rows":[],"total":0,"method":"method: status-keyed papercut index (canary)"}'
    ;;
  papercut\ close\ papercut-demo-helper-drift*)
    printf 'CLOSE %s\n' "$*" >>"$TEST_CLOSE_LOG"
    ;;
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":""}\n'
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$TEST_LEDGER_LOG"
    ;;
  *)
    echo "unexpected brain args: $*" >&2
    exit 2
    ;;
esac
SH
cat >"$fake_bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "show demo-card --json" ] || { echo "unexpected kanban args: $*" >&2; exit 2; }
printf '{"column":"done"}\n'
SH
cat >"$fake_bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "pr view 501 -R EdgeVector/last-stack --json state,mergedAt,body,url" ] || { echo "unexpected gh args: $*" >&2; exit 2; }
printf '{"state":"MERGED","mergedAt":"2026-09-30T00:00:00Z","body":"Papercut: papercut-demo-helper-drift","url":"https://github.com/EdgeVector/last-stack/pull/501"}\n'
SH
chmod +x "$fake_bin/brain" "$fake_bin/kanban" "$fake_bin/gh"

export TEST_CLOSE_LOG="$tmp/close.log"
export TEST_LEDGER_LOG="$tmp/ledger.log"
: >"$TEST_CLOSE_LOG"
: >"$TEST_LEDGER_LOG"

out="$(PATH="/usr/bin:/bin" "$helper" --records-json "$records" --brain-bin "$fake_bin/brain" --gh-bin "$fake_bin/gh" --json)"
printf '%s\n' "$out" | jq -e '.checked == 1 and (.fixed | length) == 1 and (.errors | length) == 0' >/dev/null
grep -q '^CLOSE papercut close papercut-demo-helper-drift --status fixed ' "$TEST_CLOSE_LOG"
grep -q 'papercut-demo-helper-drift' "$TEST_LEDGER_LOG"

: >"$TEST_CLOSE_LOG"
registry_out="$(LAST_STACK_PAPERCUT_LIFECYCLE_KANBAN="$fake_bin/kanban" PATH="/usr/bin:/bin" "$helper" --brain-bin "$fake_bin/brain" --limit 5 --json)"
printf '%s\n' "$registry_out" | jq -e '.ok == true and .fixed == 1 and .scanned == 1' >/dev/null
grep -q '^CLOSE papercut close papercut-demo-helper-drift --status fixed ' "$TEST_CLOSE_LOG"

missing_out="$(
  PATH="/usr/bin:/bin" bash -c '
    lifecycle_helper=last-stack-papercut-lifecycle-close
    if command -v "$lifecycle_helper" >/dev/null 2>&1; then
      echo unexpected
    else
      echo "lifecycle_helper_missing helper=$lifecycle_helper"
    fi
  '
)"
test "$missing_out" = 'lifecycle_helper_missing helper=last-stack-papercut-lifecycle-close'

printf 'ok last-stack-papercut-reconciler-contract\n'
