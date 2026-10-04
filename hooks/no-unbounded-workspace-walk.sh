#!/usr/bin/env bash
# PreToolUse hook. Blocks Bash commands that walk a WORKSPACE ROOT with no
# depth bound: ~/code, ~/code/edgevector, ~/.fkanban, ~/.fkanban/worktrees,
# ~/.cache/edgevector-git.
#
# WHY (measured 2026-08-02; the brain record this used to cite is not in
# LastDB, so the evidence is kept here rather than pointed at):
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
# The scanner word is read off a QUOTE- AND COMMENT-BLANKED copy of the line,
# so prose that merely contains `find` or `tree` is not a walk. The root and the
# depth flag are read off the ORIGINAL: a real hazard quotes the path, not the
# scanner. See the block at the blanking pass for the measurement.
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
root_hint_re='code/edgevector|\.fkanban|\.cache/edgevector-git|\.last-stack|\.routines|\.host-track|local/state/last-stack|Path\.home\(\)|expanduser\('
if printf '%s' "$cmd" | grep -qE "$walk_re" && printf '%s' "$cmd" | grep -qE "$root_hint_re"; then
  emit_deny "BLOCKED: a recursive Python walk over a workspace root.

rglob / os.walk / glob('**') from ~/code/edgevector, ~/.fkanban or the home
directory crosses ~20 checkouts and their cargo target/ trees. It takes minutes
here, the task times out, and the timeout reads as a product failure
(measured 2026-08-02 on this host).

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

# A quote- and comment-blanked copy of the same text. It is matched by the
# SCANNER regex only; the ROOT and DEPTH regexes keep reading the original.
#
# WHY (measured 2026-10-04, brain
# papercut-unbounded-walk-hook-matches-its-scanner-words-in-prose-so-an-evidence-string-is-denied-20261004):
#   `find` and `tree` are ordinary English words in exactly the register this
#   host's evidence prose uses -- "could not find the manifest", "the INSTALLED
#   tree" -- and that prose routinely names ~/.last-stack, ~/.host-track and
#   ~/.local/state/last-stack, because that is where the install proofs live.
#   The guard was therefore most likely to misfire on the one command class
#   that must carry the most prose about those roots: a `brain papercut close`
#   whose --evidence string names a root. Four of four such commands were
#   denied; no scanner ran and nothing was walked.
#
# The asymmetry is load-bearing and is the thing to get wrong. A real hazard
# quotes the PATH far more often than the scanner (`find "$HOME/.last-stack"
# -name x`), so blanking before the ROOT match would turn the guard's main true
# positive into a false negative -- the costly direction, because a false
# positive costs one rewrite and a false negative costs an unattended run
# stalling on a macOS TCC dialog with nobody there to click it.
#
# `&`, `|` and `;` are never blanked, so the segment split below lands on the
# same offsets in both copies and the two streams stay line-for-line aligned.
blanked="$(printf '%s' "$stripped" | awk '
  function emit(c) { out = out c }
  BEGIN { q = 0 }
  {
    out = ""; incomment = 0; n = length($0)
    for (i = 1; i <= n; i++) {
      c = substr($0, i, 1)
      if (c == "&" || c == "|" || c == ";") { emit(c); continue }
      if (incomment) { emit(" "); continue }
      if (q == 0) {
        if (c == "\\") { emit(c); i++; if (i <= n) emit(substr($0, i, 1)); continue }
        if (c == "\047") { emit(" "); q = 1; continue }
        if (c == "\"") { emit(" "); q = 2; continue }
        if (c == "#" && (i == 1 || substr($0, i - 1, 1) ~ /[ \t]/)) { incomment = 1; emit(" "); continue }
        emit(c); continue
      }
      if (q == 1) {
        if (c == "\047") { q = 0 }
        emit(" "); continue
      }
      if (c == "\\") { emit(" "); i++; if (i <= n) emit(" "); continue }
      if (c == "\"") { q = 0 }
      emit(" ")
    }
    print out
  }
')"

# A wrapper that takes a command as a STRING argument runs what it is handed, so
# inside one the quotes are not prose. Keep today's whole-line scanner reading
# for those segments: `bash -c "find ~/code -name x"` must stay denied. The
# `# walk-ok:` hatch covers prose that quotes such an example.
exec_wrapper_re='(^|[[:space:]])(eval|(ba|z|k|da)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]+-[A-Za-z]*c)([[:space:]]|$)'

# Normalize so "$HOME", '$HOME', $HOME and ~ all compare as one literal path.
# Both copies get the identical pipeline so neither gains or loses a line.
normalize() {
  printf '%s' "$1" | tr -d '"'"'" \
    | sed -e "s#[$]{HOME}#$home#g" -e "s#[$]HOME#$home#g" -e "s#~/#$home/#g" \
          -e "s#\([[:space:]]\)~\([[:space:]]\)#\1$home\2#g" \
          -e "s#\([[:space:]]\)~\$#\1$home#"
}
probe="$(normalize "$stripped")"
probe_blank="$(normalize "$blanked")"

# A recursive `grep` is in here because it is what an agent actually reaches
# for when the question is "who mentions X", and `grep` has no depth flag at
# all: the bounded form is `rg --max-depth N` or a bounded `find ... -exec`.
# `rg` is deliberately NOT matched — it is the fast tool this host's standing
# rules already prescribe for state roots.
scanner_re='(^|[[:space:]])(sudo[[:space:]]+)?(time[[:space:]]+)?((find|fd|tree)[[:space:]]|(/usr/bin/)?e?grep[[:space:]]+(--recursive|-[a-zA-Z]*[rR][a-zA-Z]*)[[:space:]])'
# The install and state roots belong here for the same reason as the dev roots,
# and for one more: `~/.last-stack` resolves through `current` into
# `~/.local/state/last-stack/artifacts/versions/<digest>/`, and that directory
# is unpruned — 106 GiB across 15 apps when it was last measured
# (papercut-host-track-apps-versions-unbounded-retention). `~/.last-stack` is a
# compat root of mostly symlinks, so BOTH spellings have to match: the one
# agents type and the realpath it resolves to.
roots_re="(^|[[:space:]])${home}/(code|code/edgevector|\.fkanban|\.fkanban/worktrees|\.cache/edgevector-git|\.last-stack|\.routines|\.host-track|\.local/state/last-stack)/?([[:space:]]|$)"
depth_re='-maxdepth|--max-depth|(^|[[:space:]])-(d|L)[[:space:]]*[0-9]'

# One segment per simple command, so a bounded find on one side of a pipe does
# not excuse an unbounded one on the other.
segment() { printf '%s\n' "$1" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/|/\n/g' -e 's/;/\n/g'; }
segs_o="$(segment "$probe")"
segs_b="$(segment "$probe_blank")"

# If the two copies ever disagree on the segment count the pairing below is
# meaningless, so fall back to reading the scanner off the original: that is
# today's behaviour, which over-denies rather than under-denies.
if [ "$(printf '%s\n' "$segs_b" | wc -l)" != "$(printf '%s\n' "$segs_o" | wc -l)" ]; then
  segs_b="$segs_o"
fi

hit=""
while IFS= read -r bseg && IFS= read -r oseg; do
  sseg="$bseg"
  if printf '%s' "$oseg" | grep -qE "$exec_wrapper_re"; then
    sseg="$oseg"
  fi
  printf '%s' "$sseg" | grep -qE "$scanner_re" || continue
  printf '%s' "$oseg" | grep -qE "$roots_re" || continue
  printf '%s' "$oseg" | grep -qE -- "$depth_re" && continue
  hit="$oseg"
  break
done < <(paste -d '\n' <(printf '%s\n' "$segs_b") <(printf '%s\n' "$segs_o"))
if [ -n "$hit" ]; then
  emit_deny "BLOCKED: unbounded walk of a workspace root:
  $hit

~/code/edgevector and ~/.fkanban/worktrees hold ~20 checkouts, each with a
cargo target/ tree, and ~/.last-stack / ~/.host-track / ~/.local/state/last-stack
resolve into unpruned artifact version trees (106 GiB across 15 apps when last
measured). A depth-free walk takes minutes here, the task times out, and the
timeout reads as a product failure
(measured 2026-08-02; roots widened per brain
papercut-unbounded-walk-hook-roots-omit-install-and-state-roots-20260926).

Bound it:
  find <root> -maxdepth 3 -name <file>
  fd --max-depth 3 <file> <root>
  rg --max-depth 3 --max-filesize 1M <pattern> <root>   (grep has NO depth flag)
or resolve the file without a walk:
  last-stack-locate-file --name <file> --env <VAR> --candidate <known path> \\
    --root <one repo or worktree> --maxdepth 3

If the full walk is deliberate, say why:
  <your command>  # walk-ok: <reason>"
fi

exit 0
