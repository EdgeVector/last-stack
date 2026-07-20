#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

stub="$tmp/fkanban-stub"
log="$tmp/moves.log"
pass_file="$tmp/pass-proof.txt"
todo_json="$tmp/todo.json"

printf 'PASS\n' > "$pass_file"

cat > "$todo_json" <<JSON
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
  },
  {
    "slug": "epsilon-pending-done-when",
    "title": "Pending proof",
    "column": "todo",
    "kind": "validation",
    "tags": ["validation"],
    "body": "Kind: validation\\nDONE-WHEN: file $tmp/missing-proof.txt matches /^PASS/"
  },
  {
    "slug": "zeta-satisfied-done-when",
    "title": "Satisfied proof",
    "column": "todo",
    "kind": "validation",
    "tags": ["validation"],
    "body": "Kind: validation\\nDONE-WHEN: file $pass_file matches /^PASS/"
  },
  {
    "slug": "eta-malformed-done-when",
    "title": "Malformed proof",
    "column": "todo",
    "kind": "validation",
    "tags": ["validation"],
    "body": "Kind: validation\\nDONE-WHEN: unsupported predicate"
  },
  {
    "slug": "cloud-sync-storage-lean-ns-terminal-verification",
    "title": "Terminal verification: cloud-sync storage lean proof",
    "column": "todo",
    "kind": "validation",
    "tags": ["terminal", "north-star", "validation"],
    "body": ""
  },
  {
    "slug": "forge-build-release-parity-ns-terminal-verification",
    "title": "Terminal verification: forge build/release parity proof",
    "column": "todo",
    "kind": "validation",
    "tags": ["terminal", "north-star", "validation"],
    "body": ""
  },
  {
    "slug": "one-link-invite-ns-terminal-verification",
    "title": "Terminal verification: one-link invite proof",
    "column": "todo",
    "kind": "validation",
    "tags": ["terminal", "north-star", "validation"],
    "body": ""
  },
  {
    "slug": "cloud-backup-restore-ns-terminal-verification",
    "title": "Terminal proof: cloud backup restore",
    "column": "todo",
    "kind": "validation",
    "tags": ["north-star-proof", "terminal", "agent-runnable"],
    "body": ""
  },
  {
    "slug": "lastgit-ns-terminal-verification",
    "title": "Terminal proof: LastGit native forge",
    "column": "todo",
    "kind": "validation",
    "tags": ["north-star-proof", "terminal", "agent-runnable"],
    "body": ""
  },
  {
    "slug": "deliver-slices-ns-terminal-verification",
    "title": "Terminal proof: Discovery deliver slices",
    "column": "todo",
    "kind": "validation",
    "tags": ["north-star-proof", "terminal", "agent-runnable"],
    "body": ""
  },
  {
    "slug": "exemem-cloud-account-ns-terminal-verification",
    "title": "Terminal proof: Exemem Cloud account upgrade",
    "column": "todo",
    "kind": "validation",
    "tags": ["north-star-proof", "terminal", "agent-runnable"],
    "body": ""
  },
  {
    "slug": "host-track-ns-terminal-verification",
    "title": "Terminal proof: Host Track install hygiene",
    "column": "todo",
    "kind": "validation",
    "tags": ["north-star-proof", "terminal", "agent-runnable"],
    "body": ""
  }
]
JSON

cat > "$stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = "list" ]; then
  cat "${STUB_TODO_JSON:?}"
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

STUB_LOG="$log" STUB_TODO_JSON="$todo_json" "$ROOT/bin/last-stack-park-terminal-validation-todo" \
  --board-cli "$stub" --json > "$tmp/out.json"

grep -q '"parked":11' "$tmp/out.json"
grep -q '"done":1' "$tmp/out.json"
grep -q '"alpha-ns-terminal-verification"' "$tmp/out.json"
grep -q '"delta-terminal-meta"' "$tmp/out.json"
grep -q '"epsilon-pending-done-when"' "$tmp/out.json"
grep -q '"zeta-satisfied-done-when"' "$tmp/out.json"
grep -q '"cloud-sync-storage-lean-ns-terminal-verification"' "$tmp/out.json"
grep -q '"forge-build-release-parity-ns-terminal-verification"' "$tmp/out.json"
grep -q '"one-link-invite-ns-terminal-verification"' "$tmp/out.json"
grep -q '"cloud-backup-restore-ns-terminal-verification"' "$tmp/out.json"
grep -q '"lastgit-ns-terminal-verification"' "$tmp/out.json"
grep -q '"deliver-slices-ns-terminal-verification"' "$tmp/out.json"
grep -q '"exemem-cloud-account-ns-terminal-verification"' "$tmp/out.json"
grep -q '"host-track-ns-terminal-verification"' "$tmp/out.json"
grep -q '^alpha-ns-terminal-verification backlog$' "$log"
grep -q '^delta-terminal-meta backlog$' "$log"
grep -q '^epsilon-pending-done-when backlog$' "$log"
grep -q '^zeta-satisfied-done-when done$' "$log"
grep -q '^cloud-sync-storage-lean-ns-terminal-verification backlog$' "$log"
grep -q '^forge-build-release-parity-ns-terminal-verification backlog$' "$log"
grep -q '^one-link-invite-ns-terminal-verification backlog$' "$log"
grep -q '^cloud-backup-restore-ns-terminal-verification backlog$' "$log"
grep -q '^lastgit-ns-terminal-verification backlog$' "$log"
grep -q '^deliver-slices-ns-terminal-verification backlog$' "$log"
grep -q '^exemem-cloud-account-ns-terminal-verification backlog$' "$log"
grep -q '^host-track-ns-terminal-verification backlog$' "$log"

if grep -q 'beta-terminal-pr-harness' "$log"; then
  echo "Kind: pr terminal harness must not be parked" >&2
  exit 1
fi
if grep -q 'gamma-ordinary-validation' "$log"; then
  echo "ordinary validation cards must not be parked" >&2
  exit 1
fi
if grep -q 'eta-malformed-done-when' "$log"; then
  echo "malformed DONE-WHEN cards must be left for watch/groom escalation" >&2
  exit 1
fi

if grep -q 'mapfile' "$ROOT/bin/last-stack-park-terminal-validation-todo"; then
  echo "helper must stay portable to macOS bash without mapfile" >&2
  exit 1
fi

bash -n "$ROOT/bin/last-stack-park-terminal-validation-todo"
echo ok
