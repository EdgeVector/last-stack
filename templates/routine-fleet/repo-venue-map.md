---
type: reference
slug: repo-venue-map
title: Repo Venue Map - <PROJECT_NAME>
status: active
tags: routines, portability, config, forge
---
# Repo Venue Map - <PROJECT_NAME>

Structured roster for where each repo's review artifacts live. Routines use
this record before creating, watching, updating, or merging PRs/CRs. Workflow
mechanics belong in `sop-routine-shared-contract`; this record is only the
roster and routing policy.

## Fields

<!-- owner/name token or absolute local repo path. Keep one repo per row. -->
- **repo**: `owner/name`

<!-- One of: github, forgejo, lastgit. Add other venues only after the routine
engine supports them. -->
- **venue**: `github|forgejo|lastgit`

<!-- Branch that task PRs should target. Usually main. -->
- **base**: `<BASE_BRANCH>`

<!-- Required CI/check context. Use "none" only if the repo deliberately has no
required gate. -->
- **ci_gate**: `<REQUIRED_CHECK_NAME_OR_NONE>`

<!-- One of: github-auto, github-manual, forgejo-auto, lastgit-auto,
merge-queue. -->
- **merge_mechanism**: `<MERGE_MECHANISM>`

<!-- Optional notes such as mirror-only, hands-off, human-owned, or public. -->
- **notes**: `<NOTES>`

## GitHub repos

| repo | base | ci_gate | merge_mechanism | notes |
|---|---|---|---|---|
| `<GITHUB_OWNER>/<GITHUB_REPO>` | `<BASE_BRANCH>` | `<GITHUB_CHECK_CONTEXT>` | `github-auto` | `<PUBLIC_OR_PRIVATE_NOTES>` |

## Forgejo repos

<!-- forge_url should match workspace-config. Store raw tokens only in a secret
manager and reference them by locator. -->
- **forge_url**: `<FORGE_URL>`
- **forge_token_ref**: `<FORGE_TOKEN_REF>`

| repo | base | ci_gate | merge_mechanism | notes |
|---|---|---|---|---|
| `<FORGE_OWNER>/<FORGE_REPO>` | `<BASE_BRANCH>` | `<FORGE_CHECK_CONTEXT>` | `forgejo-auto` | `<MIRROR_OR_PROTECTION_NOTES>` |

## LastGit-native repos

| repo | lastgit_slug | base | ci_gate | merge_mechanism | notes |
|---|---|---|---|---|---|
| `<OWNER>/<REPO>` | `<LASTGIT_REPO_SLUG>` | `<BASE_BRANCH>` | `<LASTGIT_STATUS_CONTEXT>` | `lastgit-auto` | `<LASTGIT_NOTES>` |

## Hands-off repos

| repo | why |
|---|---|
| `<OWNER>/<REPO>` | `<WHY_AGENTS_MUST_NOT_TOUCH_THIS_REPO>` |

## Invariants

- Routines qualify all GitHub CLI calls with `-R owner/repo`.
- Routines resolve a concrete local checkout before any git work.
- A repo listed as mirror-only or hands-off is never pushed by an agent.
- Unknown repo or unknown venue means stop and ask for a card/config update.
