#!/usr/bin/env bash
# Every managed hook must end up armed on the EVENT it belongs to, with the
# matcher shape that event actually uses.
#
# tests/last-stack-setup-installs-every-repo-hook.sh already proves a hook is
# copied (case 1) and named in some registration call (case 2). Neither case
# reads the EVENT or the MATCHER, so both pass when a hook is armed in the
# wrong place. That became reachable on 2026-10-04, when five hooks were
# brought in from the unmanaged ~/.claude/hooks root across four events and
# upsert_hook's matcher-less form got its first production callers. Brain:
# papercut-the-claude-prose-root-is-in-no-repo-so-no-gate-can-read-its-12-dangling-citations-20261004
#
# The failure this catches is silent in both directions:
#   - a matcher passed on a matcher-less event (Stop, SessionStart) writes a
#     group the harness never matches, so the hook ships installed and dead;
#   - a matcher DROPPED on PreToolUse arms the hook on every tool call.
#
# The table below is the single readable statement of the intended wiring.
# Adding a hook means adding a row — the same deliberate enumeration that
# install_claude_hooks' registration calls are.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "ok (jq absent; registration is skipped without it)"; exit 0; }

# script<TAB>event<TAB>matcher ("" means the group must carry NO matcher key)
EXPECTED=$(cat <<'TABLE'
unsafe-inline-json.sh	PreToolUse	Bash
no-home-root-scan.sh	PreToolUse	Bash
no-unbounded-workspace-walk.sh	PreToolUse	Bash
routine-shell-lint.sh	PreToolUse	Bash
no-list-as-census.sh	PreToolUse	Bash
no-list-as-census.sh	PreToolUse	mcp__brain__brain_list
needs-human-check.sh	PreToolUse	Bash
scratch-glob-self-match.sh	PreToolUse	Bash
worktree-target-isolate.sh	SessionStart	
close-out-reminder.sh	Stop	
worktree-cleanup.sh	Stop	
TABLE
)

src="$tmp/src"
mkdir -p "$src"
(cd "$ROOT" && tar --exclude='./.git' -cf - .) | (cd "$src" && tar -xf -)

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"

"$src/setup" --host claude >"$tmp/setup.out" 2>"$tmp/setup.err" || {
  sed -n '1,40p' "$tmp/setup.err" >&2
  fail "setup --host claude exited non-zero against the copied tree"
}

settings="$HOME/.claude/settings.json"
[ -s "$settings" ] || fail "setup wrote no $settings"

# One line per armed entry: event<TAB>matcher-or-<NOKEY><TAB>script basename.
actual="$tmp/actual.tsv"
jq -r '
  (.hooks // {}) | to_entries[] | .key as $event
  | .value[]
  | (if has("matcher") then .matcher else "<NOKEY>" end) as $m
  | (.hooks // [])[]
  | [$event, $m, ((.command // "") | split(" ")[0] | split("/") | last)] | @tsv
' "$settings" > "$actual"

while IFS=$'\t' read -r script event matcher; do
  [ -n "$script" ] || continue
  want_matcher="$matcher"
  [ -z "$want_matcher" ] && want_matcher="<NOKEY>"

  # Exactly one entry, on exactly this event, in a group of exactly this shape.
  n_here=$(awk -F'\t' -v e="$event" -v m="$want_matcher" -v s="$script" \
    '$1==e && $2==m && $3==s {c++} END {print c+0}' "$actual")
  [ "$n_here" = "1" ] || fail \
    "hooks/$script: expected exactly 1 entry on $event with matcher ${matcher:-<none>}, found $n_here. Registration call must pass event \"$event\" and matcher \"$matcher\" (an empty matcher means the group carries no matcher key)."

  # And nowhere else: an extra copy on another event is a second live hook.
  n_total=$(awk -F'\t' -v s="$script" '$3==s {c++} END {print c+0}' "$actual")
  n_want=$(printf '%s\n' "$EXPECTED" | awk -F'\t' -v s="$script" '$1==s {c++} END {print c+0}')
  [ "$n_total" = "$n_want" ] || fail \
    "hooks/$script: armed $n_total times across all events, the table expects $n_want. An unexpected registration is a second live hook."
done <<< "$EXPECTED"

# read-before-edit.sh is RETIRED. It is checked here as well as in
# hooks-guards.sh because this test reads the PRODUCED settings rather than
# setup's source text, so it also catches a re-arm that no grep of setup finds.
if awk -F'\t' '$3=="read-before-edit.sh"' "$actual" | grep -q .; then
  fail "read-before-edit.sh is armed in the produced settings.json. It is retired: its deny ended the whole turn and froze unattended runs."
fi

# Every entry the installer wrote must be in the table. A hook armed by setup
# and absent here is wiring nobody declared.
while IFS=$'\t' read -r event matcher script; do
  [ -n "$script" ] || continue
  if ! printf '%s\n' "$EXPECTED" | awk -F'\t' -v e="$event" -v m="$matcher" -v s="$script" \
      '{ wm = ($3 == "" ? "<NOKEY>" : $3) } $1==s && $2==e && wm==m { found=1 } END { exit found?0:1 }'; then
    fail "settings.json carries $script on $event (matcher $matcher) and the table in this test does not. Add the row, or remove the registration."
  fi
done < "$actual"

echo "ok"
