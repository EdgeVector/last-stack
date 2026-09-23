#!/usr/bin/env bash
# Fixture test for bin/last-stack-kanban-done-when-sweep with a stub board CLI.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SWEEP="$ROOT/bin/last-stack-kanban-done-when-sweep"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/done-when-sweep-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

fx="$tmp/fixtures"
mkdir -p "$fx"

# backlog: envelope; todo: legacy bare array; doing: list fails.
jq -n '{cards: [
  {slug: "val-satisfied", kind: "validation", column: "backlog"},
  {slug: "pr-card", kind: "pr", column: "backlog"},
  {slug: "tracker-pending", kind: "Tracker", column: "backlog"},
  {slug: "meta-none", kind: "meta", column: "backlog"},
  {slug: "cap-malformed", kind: "capstone", column: "backlog"},
  {slug: "val-missing", kind: "validation", column: "backlog"}
], total: 6, truncated: false}' > "$fx/list-backlog.json"
jq -n '[{slug: "val-todo", kind: "validation", column: "todo", block_status: ""}]' > "$fx/list-todo.json"

card() {
  jq -n --arg slug "$1" --arg body "$2" '{slug: $slug, body: $body}' > "$fx/show-$1.json"
}
card val-satisfied $'# Title\nKind: validation\nDONE-WHEN: date >= 2000-01-01   \nmore text\nDONE-WHEN: date >= 2999-01-01'
card tracker-pending $'Kind: tracker\nDONE-WHEN: date >= 2999-01-01'
card meta-none $'Kind: meta\nno predicate here; DONE-WHEN: inline does not count'
card cap-malformed $'DONE-WHEN: run rm -rf / please'
card val-todo $'DONE-WHEN:\tdate >= 2001-01-01'

cat > "$tmp/kanban" <<EOF
#!/usr/bin/env bash
fx="$fx"
EOF
cat >> "$tmp/kanban" <<'EOF'
case "$1" in
  list)
    col=""
    while [ "$#" -gt 0 ]; do
      case "$1" in --column) col="$2"; shift 2 ;; *) shift ;; esac
    done
    [ -f "$fx/list-$col.json" ] || { echo "node did not respond within 30000ms" >&2; exit 1; }
    cat "$fx/list-$col.json" ;;
  show)
    [ -f "$fx/show-$2.json" ] || { echo "No card with slug \"$2\"" >&2; exit 1; }
    cat "$fx/show-$2.json" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/kanban"

out="$tmp/out.tsv"
"$SWEEP" --board-cli "$tmp/kanban" > "$out" 2> "$tmp/err"

want="$tmp/want.tsv"
printf '%s\t%s\t%s\t%s\n' \
  satisfied val-satisfied validation 'date >= 2000-01-01' \
  pending tracker-pending tracker 'date >= 2999-01-01' \
  no-predicate meta-none meta - \
  malformed cap-malformed capstone 'run rm -rf / please' \
  read-error val-missing validation - \
  satisfied val-todo validation 'date >= 2001-01-01' > "$want"

if ! diff -u "$want" "$out"; then
  echo "FAIL [rows] sweep output differs" >&2
  exit 1
fi
grep -q 'done-when-sweep checked=6 satisfied=2 pending=1 malformed=1 ignored=0 no_predicate=1 read_error=1 column_read_fail=1' "$tmp/err" || {
  echo "FAIL [summary] got: $(cat "$tmp/err")" >&2; exit 1; }

# Every row has exactly four non-empty fields, so a TSV read never shifts.
while IFS=$'\t' read -r verdict slug kind pred; do
  if [ -z "$verdict" ] || [ -z "$slug" ] || [ -z "$kind" ] || [ -z "$pred" ]; then
    echo "FAIL [fields] empty field in row: $verdict|$slug|$kind|$pred" >&2; exit 1
  fi
done < "$out"

# --max caps the point reads.
"$SWEEP" --board-cli "$tmp/kanban" --max 2 > "$out" 2> "$tmp/err"
[ "$(wc -l < "$out" | tr -d ' ')" = 2 ] || { echo "FAIL [max] want 2 rows" >&2; exit 1; }

# Every column fails -> exit 1.
if "$SWEEP" --board-cli "$tmp/kanban" --columns doing,review > "$out" 2> "$tmp/err"; then
  echo "FAIL [all-fail] want exit 1" >&2; exit 1
fi

# Usage errors.
if "$SWEEP" --board-cli "$tmp/kanban" --limit 0 >/dev/null 2>&1; then
  echo "FAIL [usage] --limit 0 accepted" >&2; exit 1
fi

echo "ok last-stack-kanban-done-when-sweep"
