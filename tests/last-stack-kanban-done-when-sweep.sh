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
  {slug: "cap-malformed", kind: "capstone", column: "backlog"}
], total: 5, truncated: false}' > "$fx/list-backlog.json"
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
#!/usr/bin/env python3
import hashlib, json, sys
from pathlib import Path
fx = Path("$fx")
EOF
cat >> "$tmp/kanban" <<'EOF'
args = sys.argv[1:]
with (fx / 'calls.log').open('a') as stream:
    stream.write(' '.join(args) + '\n')
if args and args[0] == 'list':
    column = args[args.index('--column') + 1]
    path = fx / ('list-' + column + '.json')
    if not path.exists():
        print('node did not respond within 30000ms', file=sys.stderr); sys.exit(1)
    print(path.read_text()); sys.exit(0)
if len(args) != 4 or args[0:2] != ['guarded-snapshot', '--slugs-file'] or args[3] != '--json':
    print('private board accepts the native known-key batch only', file=sys.stderr); sys.exit(2)
keys = json.loads(Path(args[2]).read_text())
if not isinstance(keys, list) or not 1 <= len(keys) <= 256 or len(keys) != len(set(keys)):
    sys.exit(2)
items = []
for key in keys:
    path = fx / ('show-' + key + '.json')
    if not path.exists():
        items.append({'slug': key, 'missing': True}); continue
    source = json.loads(path.read_text())
    fields = dict.fromkeys(('slug','title','body','board','column','position','assignee','created_at','created_by','updated_at','db','repo','base','kind','block_status','block_reason','north_star','milestone','pr_url','branch'), '')
    fields.update(slug=key, body=source['body'], board='default', tags=[], deps=[], surfaces=[])
    raw = json.dumps({'version':1,'schema_hash':'a'*64,'fields':fields}, ensure_ascii=False) + '\n'
    items.append({'slug':key,'snapshot_json':raw,'snapshot_sha256':hashlib.sha256(raw.encode()).hexdigest()})
print(json.dumps({'version':1,'schema_hash':'a'*64,'items':items}))
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
  satisfied val-todo validation 'date >= 2001-01-01' > "$want"

if ! diff -u "$want" "$out"; then
  echo "FAIL [rows] sweep output differs" >&2
  exit 1
fi
grep -q 'done-when-sweep checked=5 satisfied=2 pending=1 malformed=1 ignored=0 no_predicate=1 read_error=0 column_read_fail=1' "$tmp/err" || {
  echo "FAIL [summary] got: $(cat "$tmp/err")" >&2; exit 1; }

# Every row has exactly four non-empty fields, so a TSV read never shifts.
while IFS=$'\t' read -r verdict slug kind pred; do
  if [ -z "$verdict" ] || [ -z "$slug" ] || [ -z "$kind" ] || [ -z "$pred" ]; then
    echo "FAIL [fields] empty field in row: $verdict|$slug|$kind|$pred" >&2; exit 1
  fi
done < "$out"

# Collected known keys use one complete native raw23 batch and no show fallback.
batch_n="$(grep -c '^guarded-snapshot --slugs-file ' "$fx/calls.log" || true)"
[ "$batch_n" = 1 ] || { echo "FAIL [batch] want 1 native raw23 batch, got $batch_n: $(cat "$fx/calls.log")" >&2; exit 1; }
if grep -q '^show ' "$fx/calls.log"; then
  echo "FAIL [batch] obsolete or per-slug show was used: $(cat "$fx/calls.log")" >&2
  exit 1
fi
# A missing canonical key refuses the entire flat-array response. Other
# bodies must not authorize a predicate result from a partial batch.
jq '.cards += [{slug:"val-missing",kind:"validation",column:"backlog"}] | .total=6' "$fx/list-backlog.json" > "$fx/with-missing.json"
cp "$fx/with-missing.json" "$fx/list-backlog.json"
"$SWEEP" --board-cli "$tmp/kanban" > "$out" 2> "$tmp/err"
printf '%s\t%s\t%s\t%s\n' \
  read-error val-satisfied validation - \
  read-error tracker-pending tracker - \
  read-error meta-none meta - \
  read-error cap-malformed capstone - \
  read-error val-missing validation - \
  read-error val-todo validation - > "$want"
diff -u "$want" "$out" || { echo "FAIL [missing] partial native read authorized a predicate" >&2; exit 1; }
grep -q 'done-when-sweep checked=6 satisfied=0 pending=0 malformed=0 ignored=0 no_predicate=0 read_error=6 column_read_fail=1' "$tmp/err" || {
  echo "FAIL [missing-summary] got: $(cat "$tmp/err")" >&2; exit 1; }
: > "$fx/calls.log"

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
