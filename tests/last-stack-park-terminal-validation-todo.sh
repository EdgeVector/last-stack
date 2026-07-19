#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/fkanban-stub"
log="$tmp/moves.log"

cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "list" ]; then
  cat <<'JSON'
[
  {
    "slug": "alpha-ns-terminal-verification",
    "title": "Terminal verification: alpha",
    "column": "todo",
    "kind": "validation",
    "tags": ["terminal", "north-star", "validation"],
    "body": ""
  },
  {
    "slug": "beta-terminal-pr-harness",
    "title": "Terminal verification harness",
    "column": "todo",
    "kind": "pr",
    "tags": ["terminal", "north-star"],
    "body": "Kind: pr"
  },
  {
    "slug": "gamma-ordinary-validation",
    "title": "Validate deployment",
    "column": "todo",
    "kind": "validation",
    "tags": ["validation"],
    "body": "Kind: validation"
  },
  {
    "slug": "delta-terminal-meta",
    "title": "North Star terminal proof",
    "column": "todo",
    "kind": "meta",
    "tags": ["terminal", "north-star"],
    "body": "See [[sop-north-star-terminal-verification]]."
  }
]
JSON
  exit 0
fi
if [ "$1" = "move" ]; then
  printf '%s %s\n' "$2" "$3" >> "${STUB_LOG:?}"
  exit 0
fi
echo "unexpected args: $*" >&2
exit 1
STUB
chmod +x "$stub"

STUB_LOG="$log" "$ROOT/bin/last-stack-park-terminal-validation-todo" \
  --board-cli "$stub" --json > "$tmp/out.json"

grep -q '"parked":2' "$tmp/out.json"
grep -q '"alpha-ns-terminal-verification"' "$tmp/out.json"
grep -q '"delta-terminal-meta"' "$tmp/out.json"
grep -q '^alpha-ns-terminal-verification backlog$' "$log"
grep -q '^delta-terminal-meta backlog$' "$log"

if grep -q 'beta-terminal-pr-harness' "$log"; then
  echo "Kind: pr terminal harness must not be parked" >&2
  exit 1
fi
if grep -q 'gamma-ordinary-validation' "$log"; then
  echo "ordinary validation cards must not be parked" >&2
  exit 1
fi

bash -n "$ROOT/bin/last-stack-park-terminal-validation-todo"
echo ok
