#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# Keep this test hermetic even on machines with an authenticated `gh` in PATH.
export LASTSTACK_GH_PR_JSON_FIELDS="additions assignees author autoMergeRequest baseRefName baseRefOid body changedFiles closed closedAt closingIssuesReferences comments commits createdAt deletions files fullDatabaseId headRefName headRefOid headRepository headRepositoryOwner id isCrossRepository isDraft labels latestReviews maintainerCanModify mergeCommit mergeStateStatus mergeable mergedAt mergedBy milestone number potentialMergeCommit projectCards projectItems reactionGroups reviewDecision reviewRequests reviews state statusCheckRollup title updatedAt url"
export LASTSTACK_GH_RELEASE_JSON_FIELDS="apiUrl assets author body createdAt databaseId id isDraft isImmutable isPrerelease name publishedAt tagName tarballUrl targetCommitish uploadUrl url zipballUrl"
export LASTSTACK_GH_RUN_VIEW_JSON_FIELDS="attempt conclusion createdAt databaseId displayTitle event headBranch headSha jobs name number startedAt status updatedAt url workflowDatabaseId workflowName"
export LASTSTACK_GH_RUN_LIST_JSON_FIELDS="attempt conclusion createdAt databaseId displayTitle event headBranch headSha name number startedAt status updatedAt url workflowDatabaseId workflowName"
export LASTSTACK_GH_PR_CHECKS_JSON_FIELDS="bucket completedAt description event link name startedAt state workflow"

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
printf '%s\n' "brain doctor >/dev/null; stat""us=\$?; echo \"\$stat""us\"" > "$bad_status"
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

bad_workspace_dash_c_status="$tmp/bad-workspace-dash-c-status.md"
printf '%s\n' "git -C /Users/tomtang/code/edge""vector status --short" > "$bad_workspace_dash_c_status"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_dash_c_status" >/dev/null 2>&1; then
  echo "expected git -C aggregate workspace status to fail prompt lint" >&2
  exit 1
fi

bad_workspace_dash_c_redirected_status="$tmp/bad-workspace-dash-c-redirected-status.md"
printf '%s\n' "git -C /Users/tomtang/code/edge""vector status --short 2>&1" > "$bad_workspace_dash_c_redirected_status"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_dash_c_redirected_status" >/dev/null 2>&1; then
  echo "expected git -C aggregate workspace status with redirection to fail prompt lint" >&2
  exit 1
fi

bad_workspace_var_dash_c_revparse="$tmp/bad-workspace-var-dash-c-revparse.md"
printf '%s\n' "git -C \"\$workspace_ro""ot\" rev-parse --show-toplevel" > "$bad_workspace_var_dash_c_revparse"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_var_dash_c_revparse" >/dev/null 2>&1; then
  echo "expected git -C workspace variable rev-parse to fail prompt lint" >&2
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
printf '%s\n' "map""file -t cards < <(kanban list --json)" > "$bad_mapfile"
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
  "kanban sh""ow some-card --json" \
  "## GO""AL" \
  "- this card body is data, not a command" \
  "[[""placeholder]]" \
  ":90""01 failure is prose, not a shell builtin" \
  '```' > "$bad_raw_markdown_shell_block"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_raw_markdown_shell_block" >/dev/null 2>&1; then
  echo "expected raw Markdown/card text inside a shell block to fail prompt lint" >&2
  exit 1
fi

bad_board_text_shell_block="$tmp/bad-board-text-shell-block.md"
printf '%s\n' \
  '```'"zsh" \
  "back""log" \
  "to""do" \
  "kanban-""agent" \
  '```' > "$bad_board_text_shell_block"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_board_text_shell_block" >/dev/null 2>&1; then
  echo "expected copied board/prompt tokens inside a shell block to fail prompt lint" >&2
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
kanban add some-card --body-file /tmp/card-body.md
```
GOOD_MARKDOWN_BODY
"$ROOT/bin/last-stack-lint-prompts" "$good_markdown_body_file"

bad_gh_release="$tmp/bad-gh-release.md"
printf '%s\n' "gh release view --repo owner/repo --json tagName,is""Latest,isPrerelease" > "$bad_gh_release"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_release" >/dev/null 2>&1; then
  echo "expected unsupported gh release isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

bad_gh_run_view="$tmp/bad-gh-run-view.md"
printf '%s\n' "gh run view 123 --repo owner/repo --json databaseId,is""Latest,status" > "$bad_gh_run_view"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_run_view" >/dev/null 2>&1; then
  echo "expected unsupported gh run view isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

bad_gh_run_list="$tmp/bad-gh-run-list.md"
printf '%s\n' "gh run list -R owner/repo --json databaseId,is""Latest,status" > "$bad_gh_run_list"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_run_list" >/dev/null 2>&1; then
  echo "expected unsupported gh run list isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

bad_gh_pr_checks="$tmp/bad-gh-pr-checks.md"
printf '%s\n' "gh -R owner/repo pr checks 123 --json name,is""Latest,state" > "$bad_gh_pr_checks"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_gh_pr_checks" >/dev/null 2>&1; then
  echo "expected unsupported gh pr che""cks isLatest JSON field to fail prompt lint" >&2
  exit 1
fi

good_gh_run_and_checks="$tmp/good-gh-run-and-checks.md"
cat > "$good_gh_run_and_checks" <<'GOOD_GH_RUN_AND_CHECKS'
gh run view 123 --repo owner/repo --json databaseId,status,conclusion
gh run list -R owner/repo --json databaseId,status,conclusion
gh -R owner/repo pr checks 123 --json name,state,bucket
GOOD_GH_RUN_AND_CHECKS
"$ROOT/bin/last-stack-lint-prompts" "$good_gh_run_and_checks"

bad_kanban_show_board="$tmp/bad-kanban-show-board.md"
printf '%s\n' "kanban sh""ow some-card --bo""ard default --json" > "$bad_kanban_show_board"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_show_board" >/dev/null 2>&1; then
  echo "expected unsupported kanban show board flag usage to fail prompt lint" >&2
  exit 1
fi

bad_kanban_move_board="$tmp/bad-kanban-move-board.md"
printf '%s\n' "kanban mo""ve some-card doing --bo""ard default" > "$bad_kanban_move_board"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_move_board" >/dev/null 2>&1; then
  echo "expected unsupported kanban move --board usage to fail prompt lint" >&2
  exit 1
fi

bad_kanban_tag_board="$tmp/bad-kanban-tag-board.md"
printf '%s\n' "kanban ta""g add some-card p1 --bo""ard default" > "$bad_kanban_tag_board"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_tag_board" >/dev/null 2>&1; then
  echo "expected unsupported kanban tag --board usage to fail prompt lint" >&2
  exit 1
fi

bad_kanban_search_full_body="$tmp/bad-kanban-search-full-body.md"
printf '%s\n' "kanban sea""rch auth --full""-body --json" > "$bad_kanban_search_full_body"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_search_full_body" >/dev/null 2>&1; then
  echo "expected unsupported kanban search --full-body usage to fail prompt lint" >&2
  exit 1
fi

bad_kanban_search_full_body_underscore="$tmp/bad-kanban-search-full-body-underscore.md"
printf '%s\n' "kanban sea""rch auth --full""_body" > "$bad_kanban_search_full_body_underscore"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_search_full_body_underscore" >/dev/null 2>&1; then
  echo "expected unsupported kanban search --full_body usage to fail prompt lint" >&2
  exit 1
fi

good_kanban_full_body="$tmp/good-kanban-full-body.md"
cat > "$good_kanban_full_body" <<'GOOD_FULL_BODY'
kanban list accepts `--full-body`, but kanban search has no such flag. For one
card's full body run `kanban show <slug> --json`, or pass `full_body: true` to
the MCP `kanban_search` tool.
GOOD_FULL_BODY
"$ROOT/bin/last-stack-lint-prompts" "$good_kanban_full_body"

good_kanban_list_full_body="$tmp/good-kanban-list-full-body.md"
printf '%s\n' "kanban li""st accepts --full""-body for syntax, but routines must not use it; use capped/column previews plus show for selected cards instead." > "$good_kanban_list_full_body"
"$ROOT/bin/last-stack-lint-prompts" "$good_kanban_list_full_body"

bad_kanban_list_full_body="$tmp/bad-kanban-list-full-body.md"
printf '%s\n' "kanban li""st --full""-body --json" > "$bad_kanban_list_full_body"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_list_full_body" >/dev/null 2>&1; then
  echo "expected broad kanban list --full-body usage to fail prompt lint" >&2
  exit 1
fi

bad_kanban_list_all="$tmp/bad-kanban-list-all.md"
printf '%s\n' "<board CLI> li""st --json --a""ll" > "$bad_kanban_list_all"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_kanban_list_all" >/dev/null 2>&1; then
  echo "expected broad board list --all usage to fail prompt lint" >&2
  exit 1
fi

bad_routine_doctor_health="$tmp/bad-routine-doctor-health.md"
printf '%s\n' "First: <board CLI> doc""tor, then continue if it passes." > "$bad_routine_doctor_health"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_routine_doctor_health" >/dev/null 2>&1; then
  echo "expected routine doctor health check to fail prompt lint" >&2
  exit 1
fi

good_busy_node_backoff="$tmp/good-busy-node-backoff.md"
cat > "$good_busy_node_backoff" <<'GOOD_BUSY_NODE_BACKOFF'
Run a socket-backed narrow read first:
<board CLI> list --column todo --json
Then read selected cards with:
<board CLI> show <slug> --json
On `service_timeout`, "node did not respond", or "too many concurrent reads",
exit or retry one idempotent slug upsert; do not run doctor/init or restart.
GOOD_BUSY_NODE_BACKOFF
"$ROOT/bin/last-stack-lint-prompts" "$good_busy_node_backoff"

bad_routine_result_literal="$tmp/bad-routine-result-literal.md"
printf '%s\n' 'print `ROUTINE_RESULT outcome=noop detail=idle=nothing-safe` before exit' > "$bad_routine_result_literal"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_routine_result_literal" >/dev/null 2>&1; then
  echo "expected literal ROUTINE_RESULT outcome= prompt text to fail prompt lint" >&2
  exit 1
fi

good_routine_result_literal="$tmp/good-routine-result-literal.md"
printf '%s\n' 'print the `ROUTINE_RESULT` token followed by `outcome=noop detail=idle=nothing-safe` before exit' > "$good_routine_result_literal"
"$ROOT/bin/last-stack-lint-prompts" "$good_routine_result_literal"

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

bad_global_cli_path="$tmp/bad-global-cli-path.md"
printf '%s\n' "Use global CLIs from PA""TH." > "$bad_global_cli_path"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_global_cli_path" >/dev/null 2>&1; then
  echo "expected global CLI guidance without shell prelude/preflight to fail prompt lint" >&2
  exit 1
fi

good_global_cli_path="$tmp/good-global-cli-path.md"
printf '%s\n' "Use global CLIs from PA""TH after the prelude below: \`last-stack-shell-prelude\` and \`last-stack-cli-preflight\`." > "$good_global_cli_path"
"$ROOT/bin/last-stack-lint-prompts" "$good_global_cli_path"

bad_local_checkout_git="$tmp/bad-local-checkout-git.md"
printf '%s\n' 'repo="<local-checkout>"' 'git -C "$repo" status --short --branch' > "$bad_local_checkout_git"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_local_checkout_git" >/dev/null 2>&1; then
  echo "expected local-checkout git without repo-op guard to fail prompt lint" >&2
  exit 1
fi

good_local_checkout_git="$tmp/good-local-checkout-git.md"
printf '%s\n' \
  'last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"' \
  'repo="<local-checkout>"' \
  'repo="$("$last_stack/bin/last-stack-repo-op-guard" "$repo" "<WORKSPACE>")"' \
  'git -C "$repo" status --short --branch' > "$good_local_checkout_git"
"$ROOT/bin/last-stack-lint-prompts" "$good_local_checkout_git"

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

bad_admin_ui_repo="$tmp/bad-admin-ui-repo.md"
cat > "$bad_admin_ui_repo" <<'BAD_ADMIN_UI_REPO'
Repo: EdgeVector/brain
Base: main

## GOAL
Add the Brain tab in web/admin and reuse openDelivery with kanban-crypto.
BAD_ADMIN_UI_REPO
if "$ROOT/bin/last-stack-lint-prompts" "$bad_admin_ui_repo" >/dev/null 2>&1; then
  echo "expected hosted admin UI work under a non-exemem-infra repo to fail prompt lint" >&2
  exit 1
fi

good_admin_ui_repo="$tmp/good-admin-ui-repo.md"
cat > "$good_admin_ui_repo" <<'GOOD_ADMIN_UI_REPO'
Repo: EdgeVector/exemem-infra
Base: main

## GOAL
Add the Brain tab in web/admin and reuse openDelivery with kanban-crypto.
GOOD_ADMIN_UI_REPO
"$ROOT/bin/last-stack-lint-prompts" "$good_admin_ui_repo"

bad_aline_unguarded="$tmp/bad-aline-unguarded.md"
printf '%s\n' "aline sea""rch \"prior decision\"" > "$bad_aline_unguarded"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_aline_unguarded" >/dev/null 2>&1; then
  echo "expected unguarded aline sea""rch guidance to fail prompt lint" >&2
  exit 1
fi

# Bare repo-scoped git probes run before a checkout is resolved (the recurring
# workspace-root `fatal: not a git repository` class) must fail the lint.
bad_bare_git_status="$tmp/bad-bare-git-status.md"
printf '%s\n' "pwd" "git stat""us" > "$bad_bare_git_status"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_bare_git_status" >/dev/null 2>&1; then
  echo "expected bare workspace-root git status to fail prompt lint" >&2
  exit 1
fi

bad_workspace_cd_git_branch="$tmp/bad-workspace-cd-git-branch.md"
printf '%s\n' "cd /Users/tomtang/code/edge""vector" "git bra""nch" > "$bad_workspace_cd_git_branch"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_cd_git_branch" >/dev/null 2>&1; then
  echo "expected bare git branch after cd to workspace root to fail prompt lint" >&2
  exit 1
fi

bad_workspace_var_git_lsremote="$tmp/bad-workspace-var-git-lsremote.md"
printf '%s\n' 'cd "$workspace"' "git ls-rem""ote origin" > "$bad_workspace_var_git_lsremote"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_workspace_var_git_lsremote" >/dev/null 2>&1; then
  echo "expected bare git ls-remote after cd to a workspace var to fail prompt lint" >&2
  exit 1
fi

# A probe run after a concrete checkout has been resolved is allowed.
good_resolved_checkout_probe="$tmp/good-resolved-checkout-probe.md"
printf '%s\n' \
  'repo="$("$last_stack/bin/last-stack-repo-op-guard" "$repo" "<WORKSPACE>")"' \
  'cd "$repo"' \
  "git stat""us --porcelain" \
  "git rev-pa""rse HEAD" > "$good_resolved_checkout_probe"
"$ROOT/bin/last-stack-lint-prompts" "$good_resolved_checkout_probe"

# `git -C <checkout>` forms and negative guidance never trip the probe check.
good_git_dash_c_probe="$tmp/good-git-dash-c-probe.md"
printf '%s\n' \
  'git -C "$repo" bra''nch --show-current' \
  "Do not run git stat""us from the workspace root; resolve a checkout first." > "$good_git_dash_c_probe"
"$ROOT/bin/last-stack-lint-prompts" "$good_git_dash_c_probe"

bad_live_routine_result="$tmp/bad-live-routine-result.md"
printf '%s\n' 'ROUTINE_RESULT outcome=ok detail=example-from-prompt' > "$bad_live_routine_result"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_live_routine_result" >/dev/null 2>&1; then
  echo "expected literal live-looking ROUTINE_RESULT examples to fail prompt lint" >&2
  exit 1
fi

good_placeholder_routine_result="$tmp/good-placeholder-routine-result.md"
printf '%s\n' 'Use the ROUTINE_RESULT token followed by outcome=<ok|noop|error> detail=<one-line-outcome>.' > "$good_placeholder_routine_result"
"$ROOT/bin/last-stack-lint-prompts" "$good_placeholder_routine_result"

pickup="$ROOT/routines/kanban-pickup.md"
"$ROOT/bin/last-stack-lint-prompts" "$pickup"
"$ROOT/bin/last-stack-lint-prompts" "$ROOT/routines/kanban-validate.md"
grep -q 'kanban-pickup cannot resolve' "$pickup"
grep -q 'do \*\*not\*\* set `block_status=needs_human`' "$pickup"
grep -q 'checkout-resolution guard' "$pickup"
grep -q 'git -C "$target_repo" rev-parse --show-toplevel' "$pickup"
grep -q 'reject the aggregate workspace root' "$pickup"
grep -q 'last-stack-pr-venue' "$pickup"
grep -q 'lastgit cr create' "$pickup"
grep -q 'overlap <slug> --json' "$pickup"
grep -q 'Surface-overlap gate' "$pickup"
grep -q 'collision=<slug>:<in-flight-slug>' "$pickup"
grep -q 'ready-but-conflicting work exists' "$pickup"
grep -q 'Idle budget guard' "$pickup"
grep -q 'noop no-claim reason=<reason>' "$pickup"
grep -q 'machine trailer before exit' "$pickup"
grep -q 'outcome=ok|noop|error detail=...' "$pickup"
grep -q 'record `pr_url` and `branch` on the card' "$pickup"
grep -q 'Wall-clock budget (hard)' "$pickup"
grep -q 'idle=budget-exhausted' "$pickup"
grep -q 'Do not start any new validation or PR/CR publish sequence after \*\*35 minutes\*\*' "$pickup"

agent="$ROOT/skills/kanban-agent/SKILL.md"
grep -q 'last-stack-pr-venue' "$agent"
grep -q 'sop-lastgit-native-forge-workflow' "$agent"
grep -q 'lastgit cr complete' "$agent"
grep -q 'PR/CR opened is not done' "$agent"
grep -q 'there is no separate background driver' "$agent"
grep -q 'kanban add <slug> --pr-url "$pr_url" --branch "$branch"' "$agent"
grep -q 'local test-merge' "$agent"

watch="$ROOT/routines/kanban-watch.md"
grep -q 'last-stack-pr-venue' "$watch"
grep -q 'lastgit cr list' "$watch"
grep -q 'lastgit ci status' "$watch"
grep -q 'noop board-socket-unreachable no-reconcile' "$watch"
grep -q 'routine-error-last-stack-fkanban-watch' "$watch"
grep -q 'Use `noop`, not `error`, for expected no-action external blockers' "$watch"
grep -q 'DIRTY-WORKTREE-STALLED' "$watch"
grep -q 'attempts>=3' "$watch"
grep -q 'dirty worktree with \*\*no live process\*\* is not an infinite skip' "$watch"

pipeline="$ROOT/routines/pipeline-health.md"
grep -q 'LASTGIT_PRIMARY_SOCKET' "$pipeline"
if rg -n 'lastgit/code|code node|both forge nodes|LASTGIT_CODE_SOCKET' "$pipeline" >/dev/null; then
  echo "pipeline-health should not reference the retired LastGit code socket" >&2
  exit 1
fi

bad_pipeline_root="$tmp/bad-pipeline-root"
mkdir -p "$bad_pipeline_root/routines"
printf '%s\n' 'LASTGIT_CODE_SOCKET=$HOME/.lastgit/code/data/folddb.sock lastgit list --json' > "$bad_pipeline_root/routines/pipeline-health.md"
if "$ROOT/bin/last-stack-lint-prompts" "$bad_pipeline_root" >/dev/null 2>&1; then
  echo "expected retired LastGit code socket prompt lint to fail" >&2
  exit 1
fi

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
  zsh -fc 'brain() { return 7; }; brain doctor >/dev/null 2>&1; doctor_status=$?; test "$doctor_status" -eq 7'
fi

echo "ok"
