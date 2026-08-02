#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
prompt="$ROOT/routines/papercut-reconciler.md"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

grep -q 'papercut-prevention-registry' "$prompt"
grep -q 'last-stack-papercut-lifecycle-close --limit 200' "$prompt"
grep -q 'Prevention: MISSING|COVERED|NOT_APPLICABLE' "$prompt"
grep -q 'compound regression test' "$prompt"
grep -q 'COMPOUND PREVENTION' "$prompt"
grep -q 'red-before/green-after proof' "$prompt"
grep -q 'Documentation alone is never prevention coverage' "$prompt"
grep -q 'last-stack-papercut-lifecycle-close' "$prompt"
grep -q 'lifecycle_helper_missing' "$prompt"
grep -q 'command -v "$lifecycle_helper"' "$prompt"

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
  "append papercut-demo-helper-drift --type reference")
    cat >>"$TEST_APPEND_LOG"
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
cat >"$fake_bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$*" = "cr view last-stack cr-demo --json" ] || { echo "unexpected lastgit args: $*" >&2; exit 2; }
printf '{"state":"merged","merge_oid":"abc123"}\n'
SH
chmod +x "$fake_bin/brain" "$fake_bin/lastgit"

export TEST_APPEND_LOG="$tmp/appends.log"
export TEST_LEDGER_LOG="$tmp/ledger.log"

out="$(PATH="/usr/bin:/bin" "$helper" --records-json "$records" --brain-bin "$fake_bin/brain" --lastgit-bin "$fake_bin/lastgit" --json)"
printf '%s\n' "$out" | jq -e '.checked == 1 and (.fixed | length) == 1 and (.errors | length) == 0' >/dev/null
grep -q 'Status: FIXED' "$TEST_APPEND_LOG"
grep -q 'papercut-demo-helper-drift' "$TEST_LEDGER_LOG"

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
