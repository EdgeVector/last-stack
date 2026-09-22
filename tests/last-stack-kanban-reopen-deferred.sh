#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

repo="$tmp/cache/last-stack.git"
mkdir -p "$tmp/cache" "$tmp/bin"
git init -q "$repo"
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm base
recorded="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm live
installed="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" -c user.name=test -c user.email=test@example.invalid commit --allow-empty -qm unrelated
unrelated="$(git -C "$repo" rev-parse HEAD)"

cat >"$tmp/bin/host-track" <<SH
#!/usr/bin/env bash
printf '{"host_head":"$installed"}\n'
SH
chmod +x "$tmp/bin/host-track"

cat >"$tmp/bin/kanban" <<SH
#!/usr/bin/env bash
set -euo pipefail
if [ "\$1" = list ]; then
  live_status=deferred
  live_tags='["awaiting-deploy"]'
  if [ -f "$tmp/live-cleared" ]; then
    live_status=none
    live_tags='[]'
  fi
  cat <<JSON
[
  {
    "slug": "deferred-live",
    "repo": "EdgeVector/last-stack",
    "kind": "pr",
    "block_status": "\$live_status",
    "tags": \$live_tags,
    "body": "merge=$recorded"
  },
  {
    "slug": "deferred-not-live",
    "repo": "EdgeVector/last-stack",
    "kind": "pr",
    "block_status": "deferred",
    "tags": ["awaiting-deploy"],
    "body": "merge=$unrelated"
  }
]
JSON
  exit 0
fi
if [ "\$1" = set ] && [ "\$2" = deferred-live ]; then
  touch "$tmp/live-cleared"
fi
printf '%s\n' "\$*" >>"$tmp/board.log"
SH
chmod +x "$tmp/bin/kanban"

dry="$("$ROOT/bin/last-stack-kanban-reopen-deferred" --board-cli "$tmp/bin/kanban" --host-track "$tmp/bin/host-track" --repo-cache-root "$tmp/cache" --dry-run --json)"
printf '%s\n' "$dry" | grep -q '"scanned": 2' || fail "dry run did not scan both deferred cards"
printf '%s\n' "$dry" | grep -q '"slug": "deferred-live"' || fail "dry run did not identify the live card"
[ ! -f "$tmp/board.log" ] || fail "dry run wrote to the board"

actual="$("$ROOT/bin/last-stack-kanban-reopen-deferred" --board-cli "$tmp/bin/kanban" --host-track "$tmp/bin/host-track" --repo-cache-root "$tmp/cache" --json)"
printf '%s\n' "$actual" | grep -q '"reopened":' || fail "live run did not report reopened cards"
grep -q '^set deferred-live --block-status none --json$' "$tmp/board.log" || fail "live card did not clear its deferred status"
grep -q '^move deferred-live todo$' "$tmp/board.log" || fail "live card did not move to todo"
if grep -q 'deferred-not-live' "$tmp/board.log"; then
  fail "not-live card changed"
fi

before_second="$(wc -l <"$tmp/board.log")"
second="$("$ROOT/bin/last-stack-kanban-reopen-deferred" --board-cli "$tmp/bin/kanban" --host-track "$tmp/bin/host-track" --repo-cache-root "$tmp/cache" --json)"
printf '%s\n' "$second" | grep -q '"reopened": \[\]' || fail "second run was not idempotent"
after_second="$(wc -l <"$tmp/board.log")"
[ "$before_second" = "$after_second" ] || fail "second run wrote to the board"

printf 'ok: deferred cards reopen only after their recorded commit is live\n'
