#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

good="$tmp/good.md"
cat > "$good" <<'GOOD'
workspace="<WORKSPACE>"
find "$workspace" -mindepth 2 -maxdepth 3 -type d -name .git -prune \
  | while IFS= read -r git_dir; do
      repo="${git_dir%/.git}"
      git -C "$repo" rev-parse --show-toplevel
      git -C "$repo" worktree list --porcelain
      repo_status="$(git -C "$repo" status --porcelain)"
    done
GOOD
"$ROOT/bin/last-stack-lint-prompts" "$good"

bad_status="$tmp/bad-status.md"
printf '%s\n' "fbrain doctor >/dev/null; stat""us=\$?; echo \"\$stat""us\"" > "$bad_status"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_status" >/dev/null 2>&1; then
  echo "expected reserved status assignment to fail prompt lint" >&2
  exit 1
fi

bad_workspace_git="$tmp/bad-workspace-git.md"
{
  printf '%s\n' "pwd && git stat""us --short --branch"
  printf '%s\n' "git -C /Users/tomtang/code/edge""vector status --short"
  printf '%s\n' "git work""tree list --porcelain"
} > "$bad_workspace_git"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_git" >/dev/null 2>&1; then
  echo "expected unsafe workspace/root Git probes to fail prompt lint" >&2
  exit 1
fi

bad_gh_release="$tmp/bad-gh-release.md"
printf '%s\n' "gh release view --repo owner/repo --json tagName,is""Latest,isPrerelease" > "$bad_gh_release"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_release" >/dev/null 2>&1; then
  echo "expected unsupported gh release isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

bad_fkanban_show_board="$tmp/bad-fkanban-show-board.md"
printf '%s\n' "fkanban sh""ow some-card --bo""ard default --json" > "$bad_fkanban_show_board"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_fkanban_show_board" >/dev/null 2>&1; then
  echo "expected unsupported fkanban show --board usage to fail prompt lint" >&2
  exit 1
fi

bad_fkanban_move_board="$tmp/bad-fkanban-move-board.md"
printf '%s\n' "fkanban mo""ve some-card doing --bo""ard default" > "$bad_fkanban_move_board"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_fkanban_move_board" >/dev/null 2>&1; then
  echo "expected unsupported fkanban move --board usage to fail prompt lint" >&2
  exit 1
fi

bad_fkanban_list_full_body="$tmp/bad-fkanban-list-full-body.md"
printf '%s\n' "fkanban li""st --column doing --full""-body --json" > "$bad_fkanban_list_full_body"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_fkanban_list_full_body" >/dev/null 2>&1; then
  echo "expected unsupported fkanban list --full-body usage to fail prompt lint" >&2
  exit 1
fi

bad_fkanban_list_full_body_underscore="$tmp/bad-fkanban-list-full-body-underscore.md"
printf '%s\n' "fkanban li""st --full""_body" > "$bad_fkanban_list_full_body_underscore"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_fkanban_list_full_body_underscore" >/dev/null 2>&1; then
  echo "expected unsupported fkanban list --full_body usage to fail prompt lint" >&2
  exit 1
fi

good_fkanban_full_body="$tmp/good-fkanban-full-body.md"
cat > "$good_fkanban_full_body" <<'GOOD_FULL_BODY'
fkanban list has NO --full-body flag; never use it. For one card's full body
run `fkanban show <slug> --json`, or pass `full_body: true` to the MCP
`fkanban_list` / `fkanban_search` tools.
GOOD_FULL_BODY
"$ROOT/bin/last-stack-lint-prompts" "$good_fkanban_full_body"

bad_ambiguous_repo_skip="$tmp/bad-ambiguous-repo-skip.md"
printf '%s\n' "SK""IP ambiguous repo targets and leave it in todo." > "$bad_ambiguous_repo_skip"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_ambiguous_repo_skip" >/dev/null 2>&1; then
  echo "expected ambiguous repo-target no-op skip guidance to fail prompt lint" >&2
  exit 1
fi

good_aline_guard="$tmp/good-aline-guard.md"
cat > "$good_aline_guard" <<'GOOD_ALINE'
if command -v aline >/dev/null 2>&1; then
  aline search "prior decision"
fi
GOOD_ALINE
"$ROOT/bin/last-stack-lint-prompts" "$good_aline_guard"

bad_aline_unguarded="$tmp/bad-aline-unguarded.md"
printf '%s\n' "aline sea""rch \"prior decision\"" > "$bad_aline_unguarded"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_aline_unguarded" >/dev/null 2>&1; then
  echo "expected unguarded aline sea""rch guidance to fail prompt lint" >&2
  exit 1
fi

pickup="$ROOT/routines/fkanban-pickup.md"
grep -q 'Repo: (workspace root' "$pickup"
grep -q 'Repo: (machine-hygiene skill' "$pickup"
grep -q 'fkanban-pickup cannot resolve' "$pickup"
grep -q -- '--block-status needs_human' "$pickup"

memory_home="$tmp/home"
mkdir -p "$memory_home"
env -u CODEX_HOME HOME="$memory_home" bash -eu <<'SH'
automation_id="last-stack-smoke"
memory_path=""
if [ -z "$memory_path" ]; then
  memory_path="${CODEX_HOME:-$HOME/.codex}/automations/$automation_id/memory.md"
fi
case "$memory_path" in
  ""|/automations/*) echo "unsafe automation memory path: $memory_path" >&2; exit 1 ;;
esac
mkdir -p "$(dirname "$memory_path")"
touch "$memory_path"
test "$memory_path" = "$HOME/.codex/automations/$automation_id/memory.md"
test -f "$memory_path"
SH

if command -v zsh >/dev/null 2>&1; then
  zsh -fc 'fbrain() { return 7; }; fbrain doctor >/dev/null 2>&1; doctor_status=$?; test "$doctor_status" -eq 7'
fi

echo "ok"
