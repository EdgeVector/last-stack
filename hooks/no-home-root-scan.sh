#!/usr/bin/env bash
# PreToolUse hook. Blocks Bash commands that walk the HOME ROOT or the macOS
# TCC-protected personal folders (Desktop / Documents / Downloads / Pictures /
# Movies / Music).
#
# WHY (measured 2026-09-05):
#   Every routine agent runs under routinesd, so macOS attributes file access to
#   the responsible process `routines`. A walk like
#       find "$HOME" -maxdepth 4 -type d -name artifacts
#   descends into ~/Desktop, ~/Documents, ~/Downloads and the Photos library, and
#   macOS raises one privacy prompt per protected folder. Two costs:
#     1. Tom gets a burst of "routines would like to access ..." dialogs.
#     2. The walk BLOCKS on the dialog — recent runs recorded the same find
#        "stalled with no further stdout" and "hung past 15 min".
#   The `routines` binary is ad-hoc signed at a content-hashed path, so its code
#   identity changes on every host-track install. A granted permission does not
#   survive the next version, and the prompts come back.
#
# No routine needs those folders. All real work lives in ~/code, ~/.routines,
# ~/.last-stack, ~/.fkanban, ~/.lastdb, ~/.cache, ~/.local.
#
# ESCAPE HATCH: a genuine need passes with a reason in the command:
#     find "$HOME" -maxdepth 2  # home-scan-ok: auditing top-level layout
set -u

input="$(cat)" || exit 0
command -v jq >/dev/null 2>&1 || exit 0

cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *"home-scan-ok:"*) exit 0 ;;
esac

# A heredoc BODY is data the command writes, not a path it reads. A report that
# merely NAMES a protected folder must not be denied — that false positive is how
# a guard earns its own retirement (see read-before-edit.sh, retired 2026-07-28).
# Drop every heredoc body before matching, keeping the command lines around it.
cmd="$(printf '%s' "$cmd" | awk '
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

home="${HOME:-}"
[ -n "$home" ] || exit 0

# Normalize so "$HOME", '$HOME', $HOME and ~ all compare as one literal path.
probe="$(printf '%s' "$cmd" | tr -d '"'"'" \
  | sed -e "s#[$]{HOME}#$home#g" -e "s#[$]HOME#$home#g" -e "s#~/#$home/#g" \
        -e "s#\([[:space:]]\)~\([[:space:]]\)#\1$home\2#g" \
        -e "s#\([[:space:]]\)~\$#\1$home#")"

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

scanner='(find|fd|du|ncdu|tree|rg|ag|grep|ls|wc|shasum)'

# 1. A scanner pointed at the home ROOT itself.
if printf '%s' "$probe" | grep -qE "(^|[;&|(]|&& |\| )[[:space:]]*(sudo[[:space:]]+)?(time[[:space:]]+)?${scanner}([[:space:]]+-[^[:space:]]+)*[[:space:]]+${home}([[:space:]]|/\*|$)"; then
  emit_deny "BLOCKED: do not walk the home root ($home).

macOS treats ~/Desktop, ~/Documents, ~/Downloads and the Photos library as
protected. A routine agent runs under routinesd, so the walk raises a privacy
prompt attributed to \`routines\`, AND BLOCKS until a human answers it — that is
the cause of the recorded 'find ... hung past 15 min' stalls.

Scope the walk to a real root instead:
  find $home/code -maxdepth 4 ...
  find $home/.routines $home/.last-stack $home/.fkanban -maxdepth 4 ...
  find $home/.local/state/last-stack -maxdepth 4 ...

If you truly need the whole home tree, prune the protected folders AND say why:
  find $home -maxdepth 4 \\( -path '$home/Desktop' -o -path '$home/Documents' \\
    -o -path '$home/Downloads' -o -path '$home/Pictures' -o -path '$home/Movies' \\
    -o -path '$home/Music' -o -path '$home/Library' \\) -prune -o -print \\
    2>/dev/null   # home-scan-ok: <reason>"
fi

# 2. Any direct reference to a protected personal folder.
hit="$(printf '%s' "$probe" | grep -oE "${home}/(Desktop|Documents|Downloads|Pictures|Movies|Music)" | head -1)"
if [ -n "$hit" ]; then
  emit_deny "BLOCKED: $hit is a macOS TCC-protected folder.

Touching it from a routine raises a 'routines would like to access ...' prompt
and blocks the command until a human clicks it. No routine work belongs there.

Use a workspace path ($home/code, $home/.routines, $home/.last-stack,
$home/.fkanban) or the scratchpad. If Tom explicitly asked for that folder:
  <your command>  # home-scan-ok: Tom asked for this file directly"
fi

exit 0
