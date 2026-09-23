#!/usr/bin/env bash
# Proof: last-stack-kanban-mark-once appends a marker line only when its
# content changed, so validation workers stop stacking near-identical
# BLOCKED / DONE-WHEN-MALFORMED lines
# (papercut-kanban-validate-blocker-lines-append-duplicates-20260923,
#  papercut-kanban-validate-malformed-done-when-duplicate-note-suppression-20260922).
# Fake board; no LastDB.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$ROOT/bin/last-stack-kanban-mark-once"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
export FAKE_BODY="$tmp/body"
printf 'Kind: validation\nBLOCKED[forge-prs-open]: awaiting PRs 1,2 at 2026-09-23T01:02:03Z during last-stack-fkanban-validate-w3\n' >"$FAKE_BODY"

cat >"$tmp/kanban" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  show) jq -n --rawfile b "$FAKE_BODY" --arg s "$2" '{slug:$s, body:$b}' ;;
  mark) printf '%s\n' "$3" >>"$FAKE_BODY" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/kanban"
cat >"$tmp/busy" <<'EOF'
#!/usr/bin/env bash
echo "kanban: node did not respond within 30000ms" >&2
exit 1
EOF
chmod +x "$tmp/busy"

run() { "$helper" card-x --board-cli "$tmp/kanban" "$@"; }
lines() { grep -c "^$1" "$FAKE_BODY" || true; }

# Same blocker, new timestamp and worker id -> unchanged, no new line.
out="$(run --marker 'BLOCKED[forge-prs-open]:' --text 'awaiting PRs 1,2 at 2026-09-23T04:05:06Z during last-stack-fkanban-validate-w6')"
printf '%s\n' "$out" | grep -q 'unchanged'
test "$(lines 'BLOCKED\[forge-prs-open\]:')" -eq 1

# Changed blocker content -> one new line.
out="$(run --marker 'BLOCKED[forge-prs-open]:' --text 'awaiting PR 2 at 2026-09-23T05:00:00Z')"
printf '%s\n' "$out" | grep -q 'marked'
test "$(lines 'BLOCKED\[forge-prs-open\]:')" -eq 2

# A different key is a different blocker.
run --marker 'BLOCKED[no-harness]:' --text 'no registered proof harness for north-star-x' | grep -q marked

# The evaluator marker line: first time marks, second time is unchanged.
run --line 'DONE-WHEN-MALFORMED: pred=0123456789ab' | grep -q marked
run --line 'DONE-WHEN-MALFORMED: pred=0123456789ab' | grep -q unchanged
test "$(lines 'DONE-WHEN-MALFORMED:')" -eq 1
run --line 'DONE-WHEN-MALFORMED: pred=ba9876543210' | grep -q marked
test "$(lines 'DONE-WHEN-MALFORMED:')" -eq 2

# A busy node is exit 1 with a terminal line, never a silent write.
set +e
busy_out="$("$helper" card-x --board-cli "$tmp/busy" --line 'DONE-WHEN-MALFORMED: pred=0123456789ab')"
busy_rc=$?
set -e
test "$busy_rc" -eq 1
printf '%s\n' "$busy_out" | grep -q 'error board-read-failed'

# A free-text marker is a usage error.
set +e
"$helper" card-x --board-cli "$tmp/kanban" --marker 'needs a human' --text x >/dev/null 2>&1
test "$?" -eq 2
set -e

echo "ok last-stack-kanban-mark-once"
