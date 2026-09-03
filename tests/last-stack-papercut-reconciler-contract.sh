#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
prompt="$ROOT/routines/papercut-reconciler.md"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

grep -q 'papercut-prevention-registry' "$prompt"
grep -q 'last-stack-papercut-lifecycle-close --limit 200' "$prompt"
grep -q 'brain papercut close --status fixed' "$prompt"
grep -q 'Prevention: MISSING|COVERED|NOT_APPLICABLE' "$prompt"
grep -q 'compound regression test' "$prompt"
grep -q 'COMPOUND PREVENTION' "$prompt"
grep -q 'red-before/green-after proof' "$prompt"
grep -q 'Documentation alone is never prevention coverage' "$prompt"
grep -q 'last-stack-papercut-lifecycle-close' "$prompt"
grep -q 'lifecycle_helper_missing' "$prompt"
grep -q 'command -v "$lifecycle_helper"' "$prompt"
grep -q 'last-stack-papercut-queue snapshot' "$prompt"
grep -q 'last-stack-papercut-queue verify' "$prompt"
grep -q 'brain papercut file' "$prompt"
grep -q 'brain get <slug> --type papercut' "$prompt"
grep -q 'forbidden for discovery' "$prompt"
grep -q 'conserved=true' "$prompt"
grep -q 'Do not change the typed papercut repair status merely because it was carded' "$prompt"

queue_helper="$ROOT/bin/last-stack-papercut-queue"
[ -x "$queue_helper" ] || { echo "missing executable queue helper" >&2; exit 1; }
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
    "body": "Status: OPEN\nEvidence: lastgit://last-stack/cr/cr-demo\n"
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
    printf '%s\n' '{"slug":"papercut-demo-helper-drift","title":"Demo helper drift","status":"open","body":"Evidence: lastgit://last-stack/cr/cr-demo"}'
    ;;
  "papercut list --status open --index-only --json"|"papercut list --status open --json")
    printf '%s\n' '{"rows":[],"total":0,"method":"method: status-keyed papercut index (canary)"}'
    ;;
  papercut\ close\ papercut-demo-helper-drift*)
    printf 'CLOSE %s\n' "$*" >>"$TEST_CLOSE_LOG"
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
cat >"$fake_bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "cr view last-stack cr-demo --json" ] || { echo "unexpected lastgit args: $*" >&2; exit 2; }
printf '{"state":"merged","merge_oid":"abc123"}\n'
SH
chmod +x "$fake_bin/brain" "$fake_bin/kanban" "$fake_bin/lastgit"

export TEST_CLOSE_LOG="$tmp/close.log"
export TEST_LEDGER_LOG="$tmp/ledger.log"
: >"$TEST_CLOSE_LOG"
: >"$TEST_LEDGER_LOG"

out="$(PATH="/usr/bin:/bin" "$helper" --records-json "$records" --brain-bin "$fake_bin/brain" --lastgit-bin "$fake_bin/lastgit" --json)"
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
