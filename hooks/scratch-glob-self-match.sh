#!/usr/bin/env bash
# PreToolUse hook. Denies a Bash command whose OUTPUT REDIRECT target shares
# the same directory + literal glob prefix/suffix as a GLOB ARGUMENT read in
# the same command -- the shape that let `cat` read its own output as it
# wrote it.
#
# WHY (brain papercut-shell-scratch-glob-self-matches-own-redirect-target-20260928):
#   { cat <<F ...; cat /tmp/closeout_*.md; } > /tmp/closeout_final_$$.md
#   The `{ ... } > file` group creates/truncates the redirect target BEFORE
#   the inner glob expands, so when the redirect target's name also matches
#   the glob, the command reads from a file that is simultaneously its own
#   stdout -- continuous self-referential growth. This grew one scratch file
#   from 0 to 65.9GB in ~6 minutes during a live dispatch, at 98% /tmp
#   capacity, before it was caught and killed. Left unchecked this pattern
#   can exhaust a volume and take down every process using it, including the
#   LastDB socket and every other agent's scratch space.
#
# Detects: a `>` / `>>` redirect target and a glob argument (contains `*` or
# `?`) in the same directory, where the target's basename starts with the
# glob's literal prefix (before its first wildcard) and ends with its
# literal suffix (after its last wildcard).
#
# ESCAPE HATCH: `# scratch-glob-ok: <reason>` anywhere on the line.
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *"scratch-glob-ok:"*) exit 0 ;;
esac

emit_deny() {
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

# Extract redirect targets: a `>` or `>>` NOT immediately preceded by a digit
# or `&` (so 2> / &> fd redirects are skipped), followed by optional
# whitespace, an optional opening quote, and the path token.
targets="$(printf '%s' "$cmd" \
  | grep -oE '([^0-9&[:alnum:]]|^)>{1,2}[[:space:]]*"?[^ "'"'"'|&;<>]+' \
  | sed -E 's/^.?>{1,2}[[:space:]]*"?//' \
  | sed -E 's/[;|&(){}[:space:]]+$//')"

# Extract glob arguments: whitespace-delimited tokens containing both a `/`
# and a glob metacharacter, quotes stripped.
globs="$(printf '%s\n' "$cmd" | sed -E 's/[[:space:];|&(){}<>]+/\n/g' | grep -E '/' | grep -E '[*?]' | tr -d "\"'")"

[ -n "$targets" ] && [ -n "$globs" ] || exit 0

while IFS= read -r target; do
  [ -n "$target" ] || continue
  case "$target" in */*) : ;; *) continue ;; esac
  t_dir="${target%/*}"
  t_base="${target##*/}"
  while IFS= read -r glob; do
    [ -n "$glob" ] || continue
    g_dir="${glob%/*}"
    [ "$g_dir" = "$t_dir" ] || continue
    g_base="${glob##*/}"
    prefix="${g_base%%[*?]*}"
    suffix="${g_base##*[*?]}"
    case "$t_base" in
      "$prefix"*"$suffix")
        emit_deny "BLOCKED: output redirect target may match a glob read in the same command:
  redirect target: $target
  glob argument:   $glob

The \`{ ... } > file\` group creates/truncates the redirect target BEFORE the
inner glob expands. If the target's name also matches that glob, the command
reads from a file that is simultaneously its own stdout -- continuous
self-referential growth (one scratch file grew to 65.9GB in ~6 minutes:
papercut-shell-scratch-glob-self-matches-own-redirect-target-20260928).

Use a namespaced scratch dir per run instead, so no read-glob can ever match
a write target:
  workdir=\$(mktemp -d \"\${TMPDIR:-/tmp}/scratch.XXXXXX\")
  # write new files under \$workdir; glob only the OLD directory/files

If this is deliberate and safe, say why:
  <your command>  # scratch-glob-ok: <reason>"
        ;;
    esac
  done <<<"$globs"
done <<<"$targets"

exit 0
