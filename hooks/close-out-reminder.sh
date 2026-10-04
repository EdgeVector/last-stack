#!/usr/bin/env bash
# close-out-reminder.sh — Stop-hook backstop for the close-out loop.
#
# If the session's cwd is an edgevector git repo/worktree that still has
# uncommitted changes or unpushed commits, block the stop ONCE with the
# close-out checklist so a finished piece of work doesn't get left dangling
# (no PR, no brain checkpoint, no fkanban card).
#
# Loop-safe: honors `stop_hook_active` so it fires at most once per
# continuation — if you are INTENTIONALLY leaving work in progress, just let
# the turn end again and it passes through.
#
# Deliberately narrow: never nags on the shared `fold` main checkout (we never
# commit there), and only acts inside the edgevector workspace.
#
# Disable: remove this hook from ~/.claude/settings.json "Stop".

export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
PY=/usr/bin/python3

input="$(cat)"

# loop guard — already blocked once in this continuation
active="$(printf '%s' "$input" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("stop_hook_active",False))' 2>/dev/null)"
[ "$active" = "True" ] && exit 0

cwd="$(printf '%s' "$input" | "$PY" -c 'import sys,json;print(json.load(sys.stdin).get("cwd",""))' 2>/dev/null)"
[ -z "$cwd" ] && cwd="$PWD"

# only inside the edgevector workspace / its worktrees
case "$cwd" in
  "$HOME/code/edgevector"*|"$HOME/code/edgevector-worktrees"*|"$HOME/.fkanban/worktrees"*) : ;;
  *) exit 0 ;;
esac

git -C "$cwd" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

# never nag on the shared main checkout — we never commit there by design
toplevel="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null)"
[ "$toplevel" = "$HOME/code/edgevector/fold" ] && exit 0

dirty=""
[ -n "$(git -C "$cwd" status --porcelain 2>/dev/null)" ] && dirty="uncommitted changes"

upstream="$(git -C "$cwd" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"
if [ -n "$upstream" ]; then
  ahead="$(git -C "$cwd" rev-list --count '@{u}'..HEAD 2>/dev/null)"
  if [ "${ahead:-0}" -gt 0 ] 2>/dev/null; then
    # A branch can be ahead of its OWN tracking ref while the work already
    # shipped into canonical main via a different route (e.g. a squash-merged
    # CR built from the same commits). Don't nag on parked, already-shipped
    # branches — only flag if HEAD isn't already reachable from any known main.
    #
    # Two routes, and the second is the common one here. A SQUASH merge (what
    # `lastgit cr merge` does by default, and GitHub's squash button) creates a
    # brand-new commit on main with no parent link back to the branch, so
    # `merge-base --is-ancestor` returns false for every already-merged CR
    # branch — the exact case named above. What the squash commit does carry is
    # the branch tip's TREE, so compare trees as well as ancestry. Bounded to
    # the last 200 commits of each main so this stays one cheap rev-list.
    shipped=0
    head_tree="$(git -C "$cwd" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)"
    for main_ref in lastgit/main origin/main github/main; do
      git -C "$cwd" rev-parse --verify -q "$main_ref" >/dev/null 2>&1 || continue
      if git -C "$cwd" merge-base --is-ancestor HEAD "$main_ref" 2>/dev/null; then
        shipped=1
        break
      fi
      if [ -n "$head_tree" ] \
        && git -C "$cwd" rev-list -n 200 --format=%T "$main_ref" 2>/dev/null \
           | /usr/bin/grep -qxF "$head_tree"; then
        shipped=1
        break
      fi
    done
    [ "$shipped" -eq 0 ] && dirty="${dirty:+$dirty; }${ahead} unpushed commit(s)"
  fi
fi

[ -z "$dirty" ] && exit 0

reason="Close-out backstop: ${toplevel} has ${dirty}. Before ending, run the close-out loop (invoke the /close-out skill): commit in this worktree, push, open a PR and put it on auto-merge (gh pr merge --auto, no strategy flag), checkpoint the decision to brain, and file an fkanban follow-up card for anything that closes later. If you are INTENTIONALLY leaving work in progress, just stop again — this fires only once."

"$PY" -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.argv[1]}))' "$reason"
exit 0
