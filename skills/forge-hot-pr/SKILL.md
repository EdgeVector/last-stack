---
name: forge-hot-pr
description: "Use when Codex needs to create, inspect, debug, auto-merge, or clean up pull requests for EdgeVector forge-hot non-public repos on the local Forgejo forge: fold, exemem-infra, exemem-workspace, and lastgit. Trigger for requests involving PRs, CI checks, failing Forgejo Actions, merge readiness, auto-merge, branch cleanup, or repo-routing for these repos. Do not use for public repos, GitHub-primary repos, or Keepside_Desktop."
---

# Forge Hot PR

Use Forgejo as source of truth for forge-hot repos. Their GitHub copies are mirrors;
do not use `gh`, do not push GitHub remotes, and do not open GitHub PRs.

Forge-hot repos:
- `EdgeVector/fold`
- `EdgeVector/exemem-infra`
- `EdgeVector/exemem-workspace`
- `EdgeVector/lastgit`

Exception: `Keepside_Desktop` stays GitHub-primary. Public repos such as
`fbrain`, `fkanban`, `last-stack`, websites, and schema repos use the normal
GitHub flow.

## Start

Confirm the repo remote before acting:

```bash
git remote -v
```

For a forge-hot repo, `origin` should point at Forgejo. Push branches to
`origin`; never push to a `github` remote.

Prefer the Last Stack API wrapper for Forgejo calls. It loads the macOS keychain
token, prefixes `/api/v1`, and can run a control-character-safe `jq` projection:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
forge_api="$last_stack/bin/last-stack-forge-api"

"$forge_api" repos/EdgeVector/fold/pulls?state=open --jq '.[] | [.number,.title] | @tsv'
```

Run forge API helpers from a shell that can reach `localhost:3300`; sandboxed
Codex Bash may block that TCP path and surface it as `command not found: curl`.

For normal git operations against Forgejo remotes, use the git wrapper instead
of hand-building `http.<scope>.extraHeader` commands. It injects the same
keychain token only for this one invocation:

```bash
forge_git="$last_stack/bin/last-stack-forge-git"
"$forge_git" -C /Users/tomtang/code/edgevector/fold fetch origin main
"$forge_git" -C /Users/tomtang/code/edgevector/fold ls-remote --heads origin main
"$forge_git" -C /Users/tomtang/code/edgevector/fold push -u origin "$branch"
```

For new Forgejo API calls, prefer `last-stack-forge-api --jq`. If you inherit an
older `curl | last-stack-forge-json-jq` snippet, the compatibility wrapper now
exists, but do not add new uses unless `last-stack-forge-api --jq` cannot express
the call.

## Create PR

Push the branch, then create the PR through the Forgejo API:

```bash
git push origin "$branch"

body_json="$(jq -n \
  --arg title "$title" \
  --arg body "$body" \
  --arg head "$branch" \
  '{title:$title,body:$body,head:$head,base:"main"}')"
"$forge_api" --method POST --data "$body_json" "repos/EdgeVector/$repo/pulls"
```

Write a real PR body before requesting review or auto-merge. Include motivation,
changes, validation, risks, and follow-ups.

## Auto-Merge

Arm auto-merge immediately after creating the PR, ideally while required checks
are still pending:

```bash
"$forge_api" --method POST \
  --data '{"Do":"merge","merge_when_checks_succeed":true,"delete_branch_after_merge":true}' \
  "repos/EdgeVector/$repo/pulls/$number/merge"
```

Forgejo 15.0.3 quirks:
- `merge_when_checks_succeed` only self-triggers from a later status update. If
  armed after checks are already green, it can get stuck. Push a trivial commit
  only when needed to create a fresh status event.
- `delete_branch_after_merge` is not honored on the scheduled auto-merge path.
  Sweep merged branches separately.

## Check CI

List recent tasks and filter by commit SHA; the list mixes branches and stale
attempts:

```bash
"$forge_api" "repos/EdgeVector/$repo/actions/tasks?limit=100"
```

For `fold`, the protected required context is exactly:

```text
Forge CI / ci-required (pull_request)
```

If the workflow name or job name changes, branch protection must change in the
same PR.

## Read Forge CI Logs

Prefer the paved helper from `last-stack`:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-forge-ci-log" EdgeVector/fold 455
"$last_stack/bin/last-stack-forge-ci-log" EdgeVector/fold --sha 3fcc90ab
FORGE_CI_LOG_TAIL=0 "$last_stack/bin/last-stack-forge-ci-log" EdgeVector/fold 455 0 1
```

Use the helper instead of guessing API endpoints. Forgejo 15.0.3 has no useful
`/api/v1` log endpoint; job logs are behind a web route with a session cookie
and an `/attempt/<n>/` path segment.

## Failure Triage

- If the first CI attempt fails with image pull/access noise, rerun before
  changing code.
- If a forge-hot repo still has GitHub-era scheduled/deploy workflows, audit
  whether Forgejo should run them. A green minimal PR gate does not prove deploy
  automation survived migration.
- Keep forge PR gates under the standing 10-minute target unless Tom makes a
  fresh decision. Heavy suites belong on GitHub mirrors or separate follow-up
  validation, not the pre-merge forge gate.

## Close Out

After merge:

```bash
"$forge_git" -C /path/to/repo fetch origin main
git branch --merged origin/main
```

Delete the merged branch from Forgejo if auto-merge left it behind. Do not
delete unrelated branches.
