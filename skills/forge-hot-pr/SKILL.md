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

Load credentials from the macOS keychain when using the API:

```bash
TOKEN=$(security find-generic-password -s forgejo-token -w)
ROOT=http://localhost:3300
```

## Create PR

Push the branch, then create the PR through the Forgejo API:

```bash
git push origin "$branch"

curl -s -X POST "$ROOT/api/v1/repos/EdgeVector/$repo/pulls" \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"title\":\"$title\",\"body\":\"$body\",\"head\":\"$branch\",\"base\":\"main\"}"
```

Write a real PR body before requesting review or auto-merge. Include motivation,
changes, validation, risks, and follow-ups.

## Auto-Merge

Arm auto-merge immediately after creating the PR, ideally while required checks
are still pending:

```bash
curl -s -X POST "$ROOT/api/v1/repos/EdgeVector/$repo/pulls/$number/merge" \
  -H "Authorization: token $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"Do":"merge","merge_when_checks_succeed":true,"delete_branch_after_merge":true}'
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
curl -s "$ROOT/api/v1/repos/EdgeVector/$repo/actions/tasks?limit=100" \
  -H "Authorization: token $TOKEN"
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
git fetch origin main
git branch --merged origin/main
```

Delete the merged branch from Forgejo if auto-merge left it behind. Do not
delete unrelated branches.
