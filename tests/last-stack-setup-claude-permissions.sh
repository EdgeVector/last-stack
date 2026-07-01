#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"

cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "mcp__fbrain__fbrain_get"
    ]
  }
}
JSON

"$ROOT/setup" --host claude >"$tmp/setup.out"
"$ROOT/setup" --host claude >"$tmp/setup-again.out"

settings="$HOME/.claude/settings.json"

jq -e '
  .permissions.allow as $allow
  | ($allow | index("Bash(*)")) != null
  and ($allow | map(select(. == "mcp__fbrain__fbrain_get")) | length) == 1
  and ($allow | index("mcp__fbrain__fbrain_search")) != null
  and ($allow | index("mcp__fbrain__fbrain_list")) != null
  and ($allow | index("mcp__fbrain__fbrain_ask")) != null
  and ($allow | index("mcp__fbrain__fbrain_put")) != null
' "$settings" >/dev/null

jq -e '
  [.hooks.PreToolUse[]?.matcher] as $matchers
  | ($matchers | index("Edit")) != null
  and ($matchers | index("Write")) != null
  and ($matchers | index("Bash")) != null
' "$settings" >/dev/null

echo "ok"
