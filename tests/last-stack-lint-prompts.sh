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

bad_local_status="$tmp/bad-local-status.md"
printf '%s\n' "local stat""us=\$?; echo \"\$stat""us\"" > "$bad_local_status"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_local_status" >/dev/null 2>&1; then
  echo "expected reserved local status declaration to fail prompt lint" >&2
  exit 1
fi

bad_workspace_git="$tmp/bad-workspace-git.md"
{
  printf '%s\n' "pwd && git stat""us --short --branch"
  printf '%s\n' "git -C /Users/tomtang/code/edge""vector status --short"
  printf '%s\n' "git -C \"\$workspace_ro""ot\" status --short"
  printf '%s\n' "git -C \"\$workspa""ce_dir\" rev-parse --show-toplevel"
  printf '%s\n' "git work""tree list --porcelain"
  printf '%s\n' "git rev""-parse --show-toplevel"
} > "$bad_workspace_git"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_git" >/dev/null 2>&1; then
  echo "expected unsafe workspace/root Git probes to fail prompt lint" >&2
  exit 1
fi

bad_gh_pr_without_repo="$tmp/bad-gh-pr-without-repo.md"
printf '%s\n' "gh pr vi""ew 123 --json state" > "$bad_gh_pr_without_repo"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_pr_without_repo" >/dev/null 2>&1; then
  echo "expected gh pr commands without explicit repo to fail prompt lint" >&2
  exit 1
fi

good_gh_pr_with_repo="$tmp/good-gh-pr-with-repo.md"
printf '%s\n' "gh -R owner/repo pr vi""ew 123 --json state" > "$good_gh_pr_with_repo"
"$ROOT/bin/last-stack-lint-prompts" "$good_gh_pr_with_repo"

bad_gh_repo_graphql="$tmp/bad-gh-repo-graphql.md"
printf '%s\n' "gh -R owner/repo api graph""ql -f query='{}'" > "$bad_gh_repo_graphql"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_repo_graphql" >/dev/null 2>&1; then
  echo "expected gh -R api graphql usage to fail prompt lint" >&2
  exit 1
fi

good_gh_queue_helper="$tmp/good-gh-queue-helper.md"
printf '%s\n' 'last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"' '"$last_stack/bin/last-stack-gh-pr-queue-state" owner/repo 123' > "$good_gh_queue_helper"
"$ROOT/bin/last-stack-lint-prompts" "$good_gh_queue_helper"

bad_gh_pr_unknown_json="$tmp/bad-gh-pr-unknown-json.md"
printf '%s\n' "gh -R owner/repo pr vi""ew 123 --json number,is""InMergeQueue" > "$bad_gh_pr_unknown_json"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_pr_unknown_json" >/dev/null 2>&1; then
  echo "expected unsupported gh pr JSON fields to fail prompt lint" >&2
  exit 1
fi

bad_gh_pr_unknown_json_multiline="$tmp/bad-gh-pr-unknown-json-multiline.md"
printf '%s\n' "gh -R owner/repo pr vi""ew 123 \\" "  --json number,is""InMergeQueue" > "$bad_gh_pr_unknown_json_multiline"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_pr_unknown_json_multiline" >/dev/null 2>&1; then
  echo "expected unsupported multiline gh pr JSON fields to fail prompt lint" >&2
  exit 1
fi

bad_mapfile="$tmp/bad-mapfile.md"
printf '%s\n' "map""file -t cards < <(fkanban list --json)" > "$bad_mapfile"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_mapfile" >/dev/null 2>&1; then
  echo "expected map""file/read""array usage to fail prompt lint" >&2
  exit 1
fi

good_mapfile_warning="$tmp/good-mapfile-warning.md"
printf '%s\n' "Do not use map""file/read""array in zsh/macOS snippets; use while-read or Python." > "$good_mapfile_warning"
"$ROOT/bin/last-stack-lint-prompts" "$good_mapfile_warning"

bad_unquoted_heredoc="$tmp/bad-unquoted-heredoc.md"
printf '%s\n' "cat > body.md <<""EOF" 'Markdown with `backticks`' "EOF" > "$bad_unquoted_heredoc"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_unquoted_heredoc" >/dev/null 2>&1; then
  echo "expected unquoted heredoc to fail prompt lint" >&2
  exit 1
fi

good_quoted_heredoc="$tmp/good-quoted-heredoc.md"
printf '%s\n' "cat > body.md <<'EOF'" 'Markdown with `backticks`' "EOF" > "$good_quoted_heredoc"
"$ROOT/bin/last-stack-lint-prompts" "$good_quoted_heredoc"

bad_raw_markdown_shell_block="$tmp/bad-raw-markdown-shell-block.md"
printf '%s\n' \
  '```'"bash" \
  "fkanban sh""ow some-card --json" \
  "## GO""AL" \
  "- this card body is data, not a command" \
  "[[""placeholder]]" \
  ":90""01 failure is prose, not a shell builtin" \
  '```' > "$bad_raw_markdown_shell_block"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_raw_markdown_shell_block" >/dev/null 2>&1; then
  echo "expected raw Markdown/card text inside a shell block to fail prompt lint" >&2
  exit 1
fi

good_markdown_body_file="$tmp/good-markdown-body-file.md"
cat > "$good_markdown_body_file" <<'GOOD_MARKDOWN_BODY'
```bash
cat > /tmp/card-body.md <<'EOF'
## GOAL
- this card body is data, not a command
[[placeholder]]
:9001 failure is prose, not a shell builtin
EOF
fkanban add some-card --body-file /tmp/card-body.md
```
GOOD_MARKDOWN_BODY
"$ROOT/bin/last-stack-lint-prompts" "$good_markdown_body_file"

bad_gh_release="$tmp/bad-gh-release.md"
printf '%s\n' "gh release view --repo owner/repo --json tagName,is""Latest,isPrerelease" > "$bad_gh_release"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_release" >/dev/null 2>&1; then
  echo "expected unsupported gh release isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

bad_fkanban_show_board="$tmp/bad-fkanban-show-board.md"
printf '%s\n' "fkanban sh""ow some-card --bo""ard default --json" > "$bad_fkanban_show_board"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_fkanban_show_board" >/dev/null 2>&1; then
  echo "expected unsupported fkanban show board flag usage to fail prompt lint" >&2
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

bad_default_board_unscoped="$tmp/bad-default-board-unscoped.md"
printf '%s\n' "Use workspace \`<workspace>\`, board CLI \`<board-cli>\`, default bo""ard \`<board>\`, and global CLIs from PATH." > "$bad_default_board_unscoped"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_default_board_unscoped" >/dev/null 2>&1; then
  echo "expected unscoped default-board advertisement to fail prompt lint" >&2
  exit 1
fi

good_default_board_scoped="$tmp/good-default-board-scoped.md"
printf '%s\n' "Use \`<board-cli>\`, default bo""ard \`<board>\` (the board name is only a --board argument for list and add; show, move, rm, and rank/dep/tag verbs operate on the default board implicitly and reject --board)." > "$good_default_board_scoped"
"$ROOT/bin/last-stack-lint-prompts" "$good_default_board_scoped"

bad_routine_skeleton="$tmp/bad-routine-skeleton.md"
printf '%s\n' "Run the Last Stack routine \`<routine>\`: set \`last_stack=\"<last-stack>\"\`; then read the routine and execute one bounded pass." > "$bad_routine_skeleton"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_routine_skeleton" >/dev/null 2>&1; then
  echo "expected routine skeleton without PATH prelude/preflight to fail prompt lint" >&2
  exit 1
fi

good_routine_skeleton="$tmp/good-routine-skeleton.md"
printf '%s\n' "Run the Last Stack routine \`<routine>\`: set \`last_stack=\"<last-stack>\"\`; source \`\$last_stack/bin/last-stack-shell-prelude\`; run \`\$last_stack/bin/last-stack-cli-preflight git curl jq gh <board-cli> <brain-cli>\`; then read the routine and execute one bounded pass. Before repo-scoped git, resolve the child repo with \`\$last_stack/bin/last-stack-repo-op-guard \"\$target_repo\" \"<workspace>\"\`." > "$good_routine_skeleton"
"$ROOT/bin/last-stack-lint-prompts" "$good_routine_skeleton"

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
grep -q 'checkout-resolution guard' "$pickup"
grep -q 'git -C "$target_repo" rev-parse --show-toplevel' "$pickup"
grep -q 'reject the aggregate workspace root' "$pickup"

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
