#!/usr/bin/env bash
set -euo pipefail

# The workspace-walk guard exists because an agent that needs one config file
# reaches for `find ~/.fkanban/worktrees -name x` or a Python rglob over
# ~/code/edgevector. Those roots hold ~20 checkouts with cargo target/ trees;
# the walk runs for minutes, the task times out, and the timeout reads as a
# product failure (brain papercut-agent-zero-llm-cli-bash-python-heredoc-rglob).

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
HOOK="$ROOT/hooks/no-unbounded-workspace-walk.sh"
tmp="$(mktemp -d "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-hook-walk-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

[ -x "$HOOK" ] || { echo "hooks/no-unbounded-workspace-walk.sh must ship executable" >&2; exit 1; }

# The hook must be readable on any machine: no personal home path baked in.
if grep -q '/Users/[a-z]' "$HOOK"; then
  echo "hook must not hard-code a personal home path" >&2
  exit 1
fi

# setup must install and register it, else the guard exists only in the repo.
grep -q 'no-unbounded-workspace-walk.sh' "$ROOT/setup" || { echo "setup must install no-unbounded-workspace-walk.sh" >&2; exit 1; }
grep -A1 'upsert_pretool_hook' "$ROOT/setup" | grep -q 'no-unbounded-workspace-walk' || { echo "setup must register the hook in settings.json" >&2; exit 1; }

# Answer for one Bash command: DENY or ALLOW.
verdict() {
  local out
  out="$(printf '{"tool_name":"Bash","tool_input":{"command":%s}}' \
    "$(jq -Rn --arg c "$1" '$c')" | HOME="$tmp" bash "$HOOK")"
  if printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf 'DENY\n'
  else
    printf 'ALLOW\n'
  fi
}

expect() {
  local want="$1" cmd="$2" got
  got="$(verdict "$cmd")"
  if [ "$got" != "$want" ]; then
    echo "expected $want, got $got for: $cmd" >&2
    exit 1
  fi
}

# Depth-free walks of a workspace root, in every spelling an agent reaches for.
expect DENY 'find ~/.fkanban/worktrees -name feature_catalog.toml'
expect DENY 'find "$HOME/code/edgevector" -type f -name "*.toml"'
expect DENY "find $tmp/code/edgevector -name Cargo.toml | head"
expect DENY 'fd feature_catalog.toml ~/code/edgevector'
expect DENY 'find ~/.fkanban -type d -name target'
expect DENY 'find ~/.cache/edgevector-git -name packed-refs'
expect DENY 'tree ~/code'
expect DENY 'ls ~/x && find ~/.fkanban/worktrees -name x'

# A Python recursive walk over a workspace root, inline or in a heredoc body.
expect DENY "python3 - <<'PY'
from pathlib import Path
for p in (Path.home() / 'code/edgevector').rglob('feature_catalog.toml'):
    print(p)
PY"
expect DENY "python3 -c \"import os; [print(r) for r,_,_ in os.walk(os.path.expanduser('~/.fkanban/worktrees'))]\""
expect DENY "python3 - <<'PY'
import glob
print(glob.glob('$tmp/.fkanban/worktrees/**/feature_catalog.toml', recursive=True))
PY"

# Bounded and scoped forms stay allowed: the guard must not block real work.
expect ALLOW 'find ~/.fkanban/worktrees -maxdepth 3 -name feature_catalog.toml'
expect ALLOW 'find "$HOME/code/edgevector" -maxdepth 2 -type d'
expect ALLOW 'fd --max-depth 3 feature_catalog.toml ~/code/edgevector'
expect ALLOW 'fd -d 2 Cargo.toml ~/.fkanban/worktrees'
expect ALLOW 'tree -L 2 ~/code/edgevector'
expect ALLOW 'find ~/code/edgevector/last-stack -name README.md'
expect ALLOW 'find ~/.fkanban/worktrees/x -name ci.sh'
expect ALLOW 'ls ~/.fkanban/worktrees'
expect ALLOW 'grep -rn foo ~/code/edgevector/last-stack/bin'
expect ALLOW 'find /tmp/scratch -name "*.log"'
expect ALLOW "python3 - <<'PY'
from pathlib import Path
print(sorted(Path('/tmp/scratch').rglob('*.md')))
PY"
expect ALLOW 'python3 -c "from pathlib import Path; print(list(Path(\"routines\").glob(\"*.md\")))"'
expect ALLOW 'last-stack-locate-file --name feature_catalog.toml --root ~/.fkanban/worktrees --maxdepth 3'
expect ALLOW 'cat <<EOF > note.md
find ~/.fkanban/worktrees -name x  is the slow form
EOF'

# The escape hatch: a stated reason passes.
expect ALLOW 'find ~/.fkanban/worktrees -name Cargo.lock  # walk-ok: one-off audit of lockfile drift'

# A deny must not end the turn: no continue:false, exit 0.
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"find ~/.fkanban/worktrees -name x"}}' | HOME="$tmp" bash "$HOOK")"
printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
printf '%s' "$out" | jq -e '(.continue // true) == true' >/dev/null
printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'last-stack-locate-file'
printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecisionReason' | grep -q 'walk-ok:'

# Non-Bash or empty input passes through silently.
[ -z "$(printf '{"tool_name":"Bash","tool_input":{}}' | HOME="$tmp" bash "$HOOK")" ]
[ -z "$(printf '' | HOME="$tmp" bash "$HOOK")" ]

echo "PASS last-stack-hook-no-unbounded-workspace-walk"
