---
name: merge-babysit
cadence: every 15 min
description: Self-heal stuck PRs - green-unmerged, dropped auto-merge, BEHIND, red/missing ci-required. GitHub PRs for every repo except lastgit (Forgejo). LastGit is retired.
---

You are the **merge-babysit** routine for `<WORKSPACE>`. You are the fleet
**self-heal** path for stuck pull requests. Since 2026-09-30 every EdgeVector
repo except `lastgit` is on GitHub (LastGit and the gaming PC are retired), so
the live work is the open PR pass in step 1. Nothing resolves a merge conflict
for you: you (or kanban-pickup via a card you file) must rebase, fix mechanical
conflicts, re-green CI, and merge.

CAUTION: LastGit is retired for every EdgeVector repo
(`decision-2026-09-29-retire-lastgit-all-repos-to-github`). Run no `lastgit`
command. Its registry schemas are not on the primary node, so every `lastgit`
call fails.

Scheduled runs use `last-stack-merge-demand-gate`. Skip when the open-PR pass
and deploy scan are quiet. Aged open PRs and blocked deploys proceed. The repo
lists are `config/merge-demand-github-repos` (every moved repo) and
`config/merge-demand-forge-repos` (only `lastgit`).

Run **ONE bounded pass**, then exit. No `sleep` loops.

## Priority policy

Stuck merges are **P0**. Outrank ordinary product work. Compete with
`pipeline-health` only on **merge** work - leave deploy-pipeline reds to
pipeline-health unless a PR is also stuck.

## Automation memory

If the scheduled prompt includes an `Automation memory:` path, use it.
Else `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
or `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`.
Read only a **bounded recent tail** (`tail -n 80 "$memory_path"`). Never
`cat`/`sed -n '1,Np'` the whole history into the transcript - old heartbeat
lines contaminate outcome parsers and waste the budget.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
"$last_stack/bin/last-stack-cli-preflight" git curl jq gh <board-cli> <brain-cli>
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
```

Never restart primary `lastdbd`. Never restart `forgejo`.

## Backend backpressure

Before declaring this wake an error, classify unavailable shared transport:
`service_timeout`, "node did not respond", "too many concurrent reads",
`uds_connection_limit`, `ECONNREFUSED`, missing `folddb.sock`,
`lastdb-unreachable`, "node read route not reachable", "node not running", or
"Was there a typo in the url or port?".

If the first posture or board read hits one of those signals before any PR set
is determined, this is transient shared backpressure, not a merge-babysit
failure. Do not run doctor/init, do not restart LastDB, do not mutate PRs or
cards, and exit after reporting a `noop` with a busy-node/backend-unreachable reason:

```
merge-babysit <ISO> noop stuck=unknown fixed=0 filed=0 reasons=busy-node flagged=backend-unreachable
```

If a matching `situations notices --since 1h` entry exists, add
`flagged=lastdb-transient`; otherwise still use `noop`. A GitHub API error
(rate limit, 5xx) is the same class: `noop`, flag `github-api-unavailable`.

## STEPS

### 0. Board closeout (CHEAP — always)

Merged PRs often leave the kanban card in `doing` when watch is paused.
Before detect/exit:

```bash
"$last_stack/bin/last-stack-board-closeout-sweep" || true
```

If stuck count is later 0, still report any `closed=` from this sweep in the
heartbeat instead of pure `noop` when cards were closed.

### 1. Open PR pass - GitHub (every repo except lastgit) and Forgejo (lastgit)

The PR pass covers every repo in `config/merge-demand-github-repos` (GitHub) and
`config/merge-demand-forge-repos` (`lastgit`, Forgejo). One scan reads both
venues:

```bash
"$timeout_bin" 300s "$last_stack/bin/last-stack-pipeline-forge-pr-ledger" scan --json >"$scratch/forge-open.json" 2>"$scratch/forge-open.err" || true
jq -r '.prs[] | select(.stuck) | [.repo, .number, .shape, .head_sha] | @tsv' "$scratch/forge-open.json"
```

The scan classifies each PR from the base branch's required contexts. Do not
write a per-repo shell loop; do not file per-PR papercuts (pipeline-health's
ledger owns `papercut-pipeline-forge-<repo>-pr-<n>`). If the scan finds no
stuck PR and board closeout closed nothing, heartbeat `noop no-stuck-prs` and
EXIT.

The collection read can list a PR that a point read shows closed and merged.
Before you count or act on a PR from that list, point-read it and drop it
unless it is still open and unmerged.

**GitHub PRs** (every repo except `lastgit`). Point-read a PR before you act, and read its check run:

```bash
gh -R <owner>/<repo> pr view <n> --json state,mergedAt,mergeable,mergeStateStatus,autoMergeRequest
gh -R <owner>/<repo> pr checks <n>
```

Treat a GitHub PR as stuck when it is open for more than 10 minutes and one of
these holds. Fix it with the cheap action, never a per-repo loop:

- `ci-required` is green, the PR is CLEAN and auto-merge is OFF or dropped
  (`autoMergeRequest` null): `gh -R <owner>/<repo> pr merge <n> --auto --squash
  --delete-branch`.
- The PR is BEHIND and `ci-required` is not running: `gh -R <owner>/<repo> pr
  update-branch <n>`, then make sure auto-merge is armed. Never update a branch
  while its `ci-required` run is pending; the new commit cancels the run.
- `ci-required` failed for the current head on a flaky or cancelled job: `gh -R
  <owner>/<repo> run rerun <run-id> --failed`. Find the run with `gh -R
  <owner>/<repo> pr checks <n>`.
- `ci-required` is missing (no check run) for more than 10 minutes: Actions may be
  disabled or the workflow file is broken. Do not merge around it. Flag
  `flagged=github-no-ci-required:<repo>#<n>` and let pipeline-health file it.
- `gh pr merge` returns a GraphQL 502, "Something went wrong" or "Merge already in
  progress": read `gh -R <owner>/<repo> pr view <n> --json state` first (the merge
  may have landed), then retry with `gh api -X PUT
  repos/<owner>/<repo>/pulls/<n>/merge -f merge_method=squash`. A 405 on that
  call with green checks means a protection rule blocks it: flag, do not force.

Branch protection requires the `ci-required` check and applies to admins, so a
PR can never merge red. Do not disable protection to unstick a PR.

**Forgejo PRs** (the `lastgit` repo only). Treat a Forgejo PR as stuck when it is open for more than 10 minutes and any
of these hold: required check `Forge CI / ci-required` is green but the PR is
still open; the required check is red for the current head; the required check
is missing or pending with no update for more than 10 minutes; or merge returns
405 with green checks (stuck status-check task - heal with an empty commit per
`papercut-forge-merge-405-stuck-status-check`).

Point-read a Forgejo PR before you act:

```bash
"$timeout_bin" 30s "$last_stack/bin/last-stack-forge-api" \
  "repos/EdgeVector/$repo/pulls/$number" --jq '[.state, .merged] | @tsv'
# act only on: open	false
```

HTTP 409 `pull request is already scheduled to auto merge when checks succeed`
means auto-merge is already armed: a success receipt, not an error. Do not
retry it and do not file it.

An ARMED Forgejo PR whose required check is already green can stay open forever:
Forgejo 15.0.3 evaluates a scheduled auto-merge only on a new status event
(`papercut-forgejo-auto-merge-armed-after-green-never-fires-20260923`). For
each `green-unmerged` PR from the scan, run the bounded fallback. It merges
only a PR that is armed, only after a 90s grace, and it re-arms the schedule if
the direct merge fails:

```bash
"$timeout_bin" 120s "$last_stack/bin/last-stack-pipeline-forge-pr-ledger" \
  merge-green --repo "EdgeVector/$repo" --pr "$number" --apply || true
# merged-now = healed - green-not-armed = leave it (owner did not arm)
# merge-405 = stuck status task: empty-commit heal
```

Report Forgejo counts in the heartbeat as `forge_stuck=<n>` alongside `stuck=<n>`.

### 2. HEAVY - fix ONE agent-fixable PR this wake

Step 1 handles the cheap cases. Prefer this order for the one heavy fix:

1. BEHIND or `DIRTY` (merge conflict) on a green base
2. red `ci-required` that is mechanical (lint, snapshot, lockfile)
3. anything else that is agent-fixable

For the chosen GitHub PR:

1. `git fetch origin` in an isolated worktree (`git worktree add`) on the **PR head branch**
2. Merge or rebase onto current `origin/main`
3. Resolve **mechanical** conflicts only
4. Run the repo CI script or a narrow VERIFY
5. `git push origin HEAD:<head-branch>`
6. Wait for green with a **hard outer shell timeout**: poll
   `"$timeout_bin" 120s gh -R <owner>/<repo> pr checks <n>` a few times. Do
   **not** hang the whole wake on `gh -R <owner>/<repo> pr checks <n> --watch`.
7. Make sure auto-merge is armed: `gh -R <owner>/<repo> pr merge <n> --auto --squash`

If product judgment is required: **do not** mint a default/`todo` `Kind: pr`
card without milestone + North Star because that shape poisons board pickup.
Prefer Brain papercut (below). For a
true human gate only, file/update one card in **`backlog`** with
`block_status=needs_human`, tags `pipeline,p0,merge`, body with PR url + conflict
files + `BLOCKED:`, and **never** leave it as a milestone-less `Kind: pr` in
`todo`. Then EXIT.

### 3. Escalate the rest as Brain papercuts (never bare todo Kind:pr)

For every stuck GitHub PR you did not fix: pipeline-health's ledger
(`last-stack-pipeline-forge-pr-ledger sync --apply`) files one Brain papercut
row per PR, so file nothing per PR here and record the PR in the heartbeat
(`stuck=<n>`). Do not call `last-stack-pipeline-stuck-papercut-file`: it is a
retired no-op that writes nothing. Do **not** create
`stuck-*` / pipeline P0 `Kind: pr` cards in default `todo` without a real
milestone + North Star + cold-start body - those cards cause pickup
`write-guard` no-claims that block unrelated valid work. For a problem that no
PR row covers, file a Brain papercut yourself (`brain papercut file`, same
policy as `preference-always-file-papercuts-in-brain`; search first). Never mint
`papercut-pipeline-stuck-cr-<repo>-<pr-number>` and never `brain put` a
type:reference stand-in.

Count these as `filed=<n>` in the heartbeat (`filed` means Brain papercuts
and/or backlog human-gate cards — **not** bare todo Kind:pr).

If you *must* file a pickup-ready board card (rare; only when a live
milestone already owns the PR's repo work): attach `--north-star` +
`--milestone`, full `Repo:`/`Base:`/`Kind: pr` + GOAL/CONTEXT/STEPS/VERIFY body,
and never use an empty/annotation-only body.

### 4b. Heal legacy poison stuck-merge cards (cheap)

Before heartbeat, drain any already-poisoned todo cards left by older
authoring paths:

```bash
"$last_stack/bin/last-stack-park-stuck-merge-poison-cards" --board-cli <board CLI> --json || true
```

The helper point-reads the PR when possible: closed/merged PRs → `done`;
malformed milestone-less stuck-status cards → `backlog` (not `needs_human`).
Include `poison_parked=` / `poison_closed=` in the heartbeat when non-zero.

### 5. Heartbeat

```
merge-babysit <ISO> ok|noop|error stuck=<n> fixed=<n> filed=<n> reasons=<...>
```

Use `ok` when you fixed or filed, including when fallback detection filed
Brain papercuts. Use `noop` when stuck count was 0 or the first shared backend/inventory read is temporarily unreachable. Use `error` only for a real
local routine failure.

## DONE-WHEN (per wake)

- stuck list empty after complete, OR
- one mechanical PR advanced (new head and/or merged), OR
- every remaining stuck PR has a live Brain papercut (or a pickup-safe board
  card with milestone + North Star + cold-start body — never a bare todo Kind:pr)

## Guardrails

- Never force-merge around red required checks
- Never edit shared checkouts in place (`git worktree add`)
- Never spawn background agents; you ARE the worker for at most one PR
- Run no `lastgit` command (retired)

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`${LAST_STACK_ROOT:-$HOME/.last-stack}/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
the heartbeat + `ROUTINE_RESULT` trailer as the final output (contract §1).
The close-out skill makes two brain writes; do not skip them:

1. **Brain report** — write the closeout report of what this run did (what
   changed, findings, decisions) per `preference-always-save-to-brain-when-done`.
   On a pure noop run, the heartbeat line may serve as the report.
2. **Papercuts → Brain** — file a `papercut-<topic>` brain record for every
   friction hit this run (BRAIN ONLY, never a board card; search first, update
   in place) per `preference-always-file-papercuts-in-brain`.

Skip close-out steps that do not apply to this routine (for example PR or card
steps on a read-only pass). Never skip the two brain writes when the run did
substantive work or hit friction.
