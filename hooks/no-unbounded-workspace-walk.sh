#!/usr/bin/env bash
# PreToolUse hook. Blocks Bash commands that walk a WORKSPACE ROOT with no
# depth bound: ~/code, ~/code/edgevector, ~/.fkanban, ~/.fkanban/worktrees,
# ~/.cache/edgevector-git.
#
# WHY (brain papercut-agent-zero-llm-cli-bash-python-heredoc-rglob, 2026-08-02):
#   An agent that needs one config file reaches for
#       find ~/.fkanban/worktrees -name feature_catalog.toml
#   or, inside a python heredoc,
#       (Path.home() / "code/edgevector").rglob("feature_catalog.toml")
#   On this host those roots hold ~20 checkouts, each with a cargo `target/`
#   tree of hundreds of thousands of files. The walk takes minutes, the
#   background task times out, and the timeout reads as a product failure.
#   The recorded cost was extra rewrite rounds and stale FAIL notifications.
#
# Two shapes are denied:
#   1. `find` / `fd` / `tree` whose root is a workspace root and whose command
#      line carries no -maxdepth / --max-depth / -d N / -L N.
#   2. A Python recursive walk (`.rglob(`, `os.walk(`, `glob("**")`) anywhere
#      in the command, heredoc bodies included, together with a workspace root
#      or `Path.home()` / `expanduser(` in the same command.
#
# The deny hands back the bounded forms: bin/last-stack-locate-file (env var,
# fixed candidates, depth- and time-bounded roots) or find ... -maxdepth N.
#
# ESCAPE HATCH: a genuine need passes with a reason in the command:
#     find ~/.fkanban/worktrees -name Cargo.lock  # walk-ok: one-off audit
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *"walk-ok:"*) exit 0 ;;
esac

home="${HOME:-}"
[ -n "$home" ] || exit 0

emit_deny() {
  # Deny only, never "continue": false — the agent must be able to retry a
  # compliant form inside the same turn.
  local reason="$1"
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }' 2>/dev/null && exit 0
  printf '%s\n' "$reason" >&2
  exit 2
}

# Shape 2 first, on the RAW command: a heredoc body is exactly where an inline
# Python walk lives.
walk_re='\.rglob\(|os\.walk\(|\.glob\([^)]*\*\*|glob\.i?glob\([^)]*\*\*'
root_hint_re='code/edgevector|\.fkanban|\.cache/edgevector-git|Path\.home\(\)|expanduser\('
if printf '%s' "$cmd" | grep -qE "$walk_re" && printf '%s' "$cmd" | grep -qE "$root_hint_re"; then
  emit_deny "BLOCKED: a recursive Python walk over a workspace root.

rglob / os.walk / glob('**') from ~/code/edgevector, ~/.fkanban or the home
directory crosses ~20 checkouts and their cargo target/ trees. It takes minutes
here, the task times out, and the timeout reads as a product failure
(brain papercut-agent-zero-llm-cli-bash-python-heredoc-rglob).

Resolve the file with a bounded lookup instead:
  last-stack-locate-file --name <file> --env <VAR> \\
    --candidate <known path> --root <one repo or worktree> --maxdepth 3
or accept the path as an explicit --flag / environment variable.

If the walk is deliberate, bound it and say why:
  <your command>  # walk-ok: <reason>"
fi

# Shape 1 on the command with heredoc bodies removed: a body is data the
# command writes, not a path it walks.
stripped="$(printf '%s' "$cmd" | awk '
  {
    if (inbody) { if ($0 == term) { inbody = 0 } ; next }
    line = $0
    if (match(line, /<<-?[ \t]*[\047"]?[A-Za-z_][A-Za-z0-9_]*[\047"]?/)) {
      tag = substr(line, RSTART, RLENGTH)
      gsub(/^<<-?[ \t]*/, "", tag)
      gsub(/[\047"]/, "", tag)
      term = tag
      inbody = 1
    }
    print line
  }
')"

# Normalize so "$HOME", '$HOME', $HOME and ~ all compare as one literal path.
probe="$(printf '%s' "$stripped" | tr -d '"'"'" \
  | sed -e "s#[$]{HOME}#$home#g" -e "s#[$]HOME#$home#g" -e "s#~/#$home/#g" \
        -e "s#\([[:space:]]\)~\([[:space:]]\)#\1$home\2#g" \
        -e "s#\([[:space:]]\)~\$#\1$home#")"

scanner_re='(^|[[:space:]])(sudo[[:space:]]+)?(time[[:space:]]+)?(find|fd|tree)[[:space:]]'
roots_re="(^|[[:space:]])${home}/(code|code/edgevector|\.fkanban|\.fkanban/worktrees|\.cache/edgevector-git)/?([[:space:]]|$)"
depth_re='-maxdepth|--max-depth|(^|[[:space:]])-(d|L)[[:space:]]*[0-9]'

# One segment per simple command, so a bounded find on one side of a pipe does
# not excuse an unbounded one on the other.
hit="$(printf '%s\n' "$probe" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/|/\n/g' -e 's/;/\n/g' \
  | grep -E "$scanner_re" | grep -E "$roots_re" | grep -vE -- "$depth_re" | head -1 || true)"
if [ -n "$hit" ]; then
  emit_deny "BLOCKED: unbounded walk of a workspace root:
  $hit

~/code/edgevector and ~/.fkanban/worktrees hold ~20 checkouts, each with a
cargo target/ tree. A depth-free find takes minutes here, the task times out,
and the timeout reads as a product failure
(brain papercut-agent-zero-llm-cli-bash-python-heredoc-rglob).

Bound it:
  find <root> -maxdepth 3 -name <file>
  fd --max-depth 3 <file> <root>
or resolve the file without a walk:
  last-stack-locate-file --name <file> --env <VAR> --candidate <known path> \\
    --root <one repo or worktree> --maxdepth 3

If the full walk is deliberate, say why:
  <your command>  # walk-ok: <reason>"
fi

exit 0
