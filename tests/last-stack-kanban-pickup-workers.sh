#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-kanban-pickup-workers"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

prompt="$tmp/kanban-pickup.md"
bootstrap="$tmp/prompts/last-stack-kanban-pickup-bootstrap.md"
printf '%s\n' '---' 'name: kanban-pickup' '---' >"$prompt"

"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap"

test -f "$bootstrap"
grep -q 'last-stack-routine-read" kanban-pickup' "$bootstrap"
grep -q 'Empty-todo credit gate' "$bootstrap"
grep -q 'list --column todo --json' "$bootstrap"
grep -q 'empty-todo no_card_claimed' "$bootstrap"
grep -q "$prompt" "$bootstrap"
grep -q 'routine-read-failed no_card_claimed' "$bootstrap"

for id in \
  last-stack-fkanban-pickup \
  last-stack-fkanban-pickup-w2 \
  last-stack-fkanban-pickup-w3 \
  last-stack-fkanban-pickup-w4 \
  last-stack-fkanban-pickup-w5 \
  last-stack-fkanban-pickup-w6
do
  test -f "$tmp/registry/$id.toml"
  grep -q "id = \"$id\"" "$tmp/registry/$id.toml"
  grep -q "prompt_path = \"$bootstrap\"" "$tmp/registry/$id.toml"
  grep -q 'freshness bootstrap' "$tmp/registry/$id.toml"
done

grep -q 'BYMINUTE=0,15,30,45;BYSECOND=0' "$tmp/registry/last-stack-fkanban-pickup.toml"
grep -q 'BYMINUTE=5,20,35,50;BYSECOND=0' "$tmp/registry/last-stack-fkanban-pickup-w2.toml"
grep -q 'BYMINUTE=10,25,40,55;BYSECOND=0' "$tmp/registry/last-stack-fkanban-pickup-w3.toml"
grep -q 'BYMINUTE=2,17,32,47;BYSECOND=30' "$tmp/registry/last-stack-fkanban-pickup-w4.toml"
grep -q 'BYMINUTE=7,22,37,52;BYSECOND=30' "$tmp/registry/last-stack-fkanban-pickup-w5.toml"
grep -q 'BYMINUTE=12,27,42,57;BYSECOND=30' "$tmp/registry/last-stack-fkanban-pickup-w6.toml"

before="$(cksum "$tmp/registry/last-stack-fkanban-pickup-w6.toml")"
"$BIN" --workers 6 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap" >/tmp/last-stack-pickup-workers-idempotent.$$
after="$(cksum "$tmp/registry/last-stack-fkanban-pickup-w6.toml")"
rm -f /tmp/last-stack-pickup-workers-idempotent.$$
test "$before" = "$after"

if "$BIN" --workers 7 --registry-dir "$tmp/registry" --prompt-path "$prompt" --bootstrap-path "$bootstrap" >/dev/null 2>&1; then
  echo "expected invalid worker count to fail" >&2
  exit 1
fi

dry="$("$BIN" --workers 4 --registry-dir "$tmp/dry-registry" --prompt-path "$prompt" --bootstrap-path "$tmp/dry-bootstrap.md" --dry-run)"
grep -q 'dry-bootstrap.md' <<<"$dry"
grep -q 'last-stack-routine-read" kanban-pickup' <<<"$dry"
grep -q 'last-stack-fkanban-pickup-w4.toml' <<<"$dry"
grep -q 'id = "last-stack-fkanban-pickup-w4"' <<<"$dry"
test ! -e "$tmp/dry-registry"

echo "ok"
