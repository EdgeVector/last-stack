---
name: drain-open-prs
cadence: daily
description: Drive the count of open PRs across ALL your repos toward zero every day — for each PR, classify relevance, then merge (rebasing/fixing mechanical CI) or close (stale/superseded/irrelevant) with a comment. Skips PRs with a live worktree and human-gated prod-cutover PRs.
---

No-tests policy: `instructions/no-tests.md`; Situation
`no-tests-all-repos-20261009`. This policy supersedes older test requirements in
shared contracts, prompts, and cards. Keep non-test checks and product proof.

You are the daily open-PR drainer for `<WORKSPACE>`. Goal: drive the count of
open PRs across ALL your repos toward ZERO every day. For each open PR, decide
whether it's still wanted, then take it to a terminal state: MERGE it
(rebasing/resolving conflicts and fixing mechanical CI as needed), or CLOSE it
(stale / superseded / abandoned / irrelevant) with a one-line comment saying why.

Scheduled runs use `last-stack-merge-demand-gate`. Skip when open PRs and deploy
are quiet. Ghost LastGit does not count. The default lists are
`config/merge-demand-github-repos` (every moved repo) and
`config/merge-demand-forge-repos` (only `lastgit`, on Forgejo).
Run ONE full sweep, emit a fresh `ROUTINE_RESULT` line, then exit with a
report. Do not keep inspecting old memory, waiting on CI, or re-enumerating once
the report and result line are written.

> You ARE authorized to merge green-CI PRs even if unreviewed, and to close PRs
> you judge irrelevant — that's the whole point of this routine. (Decide for
> your own fleet whether that authorization holds; tighten it if not.)

This complements the more frequent `kanban-watch` reconciler (which only
advances carded PRs). You are the broader once-a-day backstop that drains the
long tail across every repo and actually closes dead PRs.

## Repos to sweep
List them explicitly: `<owner>/<repo-1>`, `<owner>/<repo-2>`, … Every EdgeVector
repo except `lastgit` is on GitHub (2026-09-30; LastGit and the gaming PC are
retired). The only repo on a self-hosted forge is `lastgit` (Forgejo): sweep it
through the Forgejo API (`last-stack-forge-api`), not `gh`. For forge API JSON
reads, pipe curl through `"$last_stack/bin/last-stack-forge-json-jq"` so raw
control characters in PR bodies cannot make `jq` abort.

Before enumerating a repo, resolve its concrete checkout and run
`"$last_stack/bin/last-stack-pr-venue" --json <owner/repo> "$target_repo"`.
The answer is `github` for every repo except `lastgit` (`forgejo`). A
`.venue == "lastgit"` answer is a stale marker: LastGit is retired. Run no
`lastgit` command and skip that repo with a flag. For a GitHub repo a green PR merges with
`gh -R <owner>/<repo> pr merge <n> --auto --squash --delete-branch` (the required
check is the `ci-required` check run; on a GraphQL 502 read the state first, then
`gh api -X PUT repos/<owner>/<repo>/pulls/<n>/merge -f merge_method=squash`).
Enumerate each GitHub repo:
```bash
gh -R <owner>/<repo> pr list --state open \
  --json number,title,headRefName,isDraft,mergeable,mergeStateStatus,reviewDecision,autoMergeRequest,updatedAt,statusCheckRollup,author
```

Do not add `isInMergeQueue` to `gh pr view/list --json`; use GraphQL when
queue membership is needed:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-gh-pr-queue-state" <owner>/<repo> <n> 2>/dev/null || true
```

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path. Read only a bounded recent tail, for example
`tail -n 120 "$memory_path"`; never `cat` or paste the full historical memory
file into the transcript. Old memory can contain prior heartbeat/result lines,
so it is context only and must not be treated as this run's outcome.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-fkanban-pickup`),
**not** the skill frontmatter `name:` (e.g. not bare `kanban-pickup`). Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly. If the
sandbox refuses the path, note `memory_unwritable=<path>` in the heartbeat and
continue — do not fail the whole run.

## 🛑 Hard guardrails — obey exactly
- **NEVER touch a PR whose head branch has a _LIVE_ worktree — but a _PARKED_
  worktree is yours to drive.** Before acting on ANY PR, `git -C <repo> worktree
  list` and check every worktree location. When one is on the PR's head branch,
  classify it:
  - **LIVE → SKIP** (a sibling agent is mid-work; it will drain itself). ANY of:
    `git -C <wt> status --porcelain` non-empty; the last commit or a non-`.git`/
    non-build-cache file was touched in the last ~2h; or a process is cwd'd in it
    (`lsof +D <wt>` non-empty).
  - **PARKED → ADOPT and drive it to terminal state.** Clean tree, last commit
    hours old, no live process, PR already open. The owner finished and walked
    away — finish it (re-run flaky CI, fix mechanical failures, merge if green,
    or close if superseded). A parked worktree is exactly where green-able PRs
    rot for a day; don't skip just because the directory exists.
- **NEVER kill the process hosting your brain/board node** or any node you didn't
  start.
- **NEVER bypass a failing required CI gate.** A red required check means DO NOT
  MERGE. You may fix it or leave it; never force-merge around it.
- **NEVER edit a shared checkout, and never `stash`/`reset --hard`/`clean` in any
  shared repo.** All conflict/CI work happens in a fresh `git worktree add`.
  Never `git add -A`/`git add .` in a shared checkout.
- **Dev, not prod, when a design is in flight.** If merging a PR FIRES a prod
  deploy and it's an explicitly human-gated cutover/flip, LEAVE IT and flag it
  for a human. When unsure whether a merge ships to prod, leave it and flag.

## Per-PR decision logic (after the worktree guard)
1. **Worktree on head branch** → classify LIVE vs PARKED per the guardrail. LIVE
   → SKIP. PARKED → drive it to terminal state.
2. **Draft PR**: if updated < ~10 days ago, leave it (live WIP). If untouched
   >10 days, it's abandoned → close with a comment.
3. **Classify relevance — cross-check before deciding; never just defer.** Read
   the PR and check it against three sources:
   - **the default branch** — is the change already landed/superseded?
   - **the brain** (`<brain search>` / your memory / project docs) — does it
     match or contradict decided direction?
   - **the board** — is there a card driving it (then finish it), is the card
     already `done`/closed (then it's stale → close it), or is there no card at
     all for a months-old branch (likely abandoned)?
   CLOSE when: already on the default branch (superseded); contradicts a decided
   /abandoned design; its card is done/dropped; a months-stale experiment nobody
   will finish; or plainly irrelevant. To close:
   `gh -R <repo> pr comment <n> --body "Closing in daily PR drain: <reason>. Reopen if still wanted."`
   then `gh -R <repo> pr close <n>`. **Every PR must leave this sweep with a
   recorded decision** — "left as-is, in-flight" is only legitimate for a LIVE
   worktree or still-running CI.
4. **Relevant + MERGEABLE + all required checks green** → merge (re-assert auto-
   merge per your merge strategy; approve first if a *review* gate — not a CI
   gate — blocks and you're authorized to).
5. **Relevant + CONFLICTING/DIRTY/BEHIND** → (BEHIND only, no conflict:
   skip while a CI run on the head is pending — a push cancels it; GitHub
   `gh -R <r> pr checks <n>` shows the `ci-required` run; Forgejo (the `lastgit`
   repo) probe `last-stack-forge-pr-update-branch --repo <r> --pr <n>`, exit 3 =
   in flight)
   `git worktree add <fresh-path> <headRef>`, fetch the base, rebase, resolve,
   re-run the PR's verify, force-push with lease, then merge. Remove the worktree
   when done. If the conflict needs real product judgment, don't guess — comment
   flagging it and leave it.
6. **Relevant + a required check RED** → ALWAYS read the failing job first
   (`gh run view <run-id> --log-failed -R <repo>`). Do not stop at umbrella
   checks like `ci-required`; inspect the underlying failed job(s). Branch on the
   failure KIND:
   - **Retired test or test coverage requirement** → remove the command and
     requirement from CI, linters, and the PR brief in a worktree. Do not repair
     or rerun tests. Keep the remaining required non-test checks.
   - **Infra flake** — cancelled / runner shutdown / timeout / lost-runner, with
     no non-test check failure. NOT a code failure and the #1 reason a green-able PR
     sits stuck for hours. Action: `gh run rerun <run-id> --failed -R <repo>`
     (or push an empty commit from a worktree if the run is too old to re-run),
     confirm auto-merge is still on, move on. NEVER leave a flaky-cancelled check
     sitting — re-running it IS the action.
   - **Mechanical** (formatter/linter/version-consistency) → fix in a worktree as
     in (5), push, re-assert merge.
   - **Real product failure needing product judgment** → don't guess; comment
     flagging the specific failure and leave it for a human.
7. **Pending** (CI running, or waiting on a human you can't satisfy) → leave for
   the next daily run.
8. **Branch owned by another active routine** (e.g. `kanban/*` → the pickup
   pipeline) → defer ONLY while it's genuinely progressing (LIVE worktree, CI
   running now, or a commit pushed in the last ~2h). The moment it's PARKED —
   worktree clean+idle (or gone) and the PR stuck on a stale red/BLOCKED state —
   ADOPT it and drive it to terminal state. A parked pickup-pipeline PR (agent
   pushed, CI flaked, agent exited) is the canonical thing this drain must
   finish.

## Execution discipline (scheduled/unattended run)
- Issue ONE tool call per turn and append `|| true` so a non-zero exit doesn't
  cancel the rest of the queue.
- Do NOT chain `sleep` to wait on CI. For a PR whose merge you just enabled,
  either confirm with a sleepless `gh -R <repo> pr checks <n> --watch` if you must see it
  land in-turn, or just leave it for tomorrow — auto-merge fires when CI goes
  green. Interpret PR STATE, not a watcher's exit code (a BLOCKED/red/queue
  state = re-poll, not a failure).
- Bound conflict/CI-fix work to a few PRs per run — fix the clearest ones and
  list the rest in the report.
- Clean up any worktrees you created (`git worktree remove --force`).

## Report (end of run)
Per repo: which PRs were MERGED, CLOSED (with reason), FIXED+merged, SKIPPED
(live worktree / pending CI / draft-WIP), and FLAGGED for a human (human-gated
prod cutover, real logic failures, ambiguous relevance). End with the remaining
open-PR count per repo and the headline: how many drained to zero vs how many
still need a human.

Immediately before the final report, print exactly one fresh result line using
the `ROUTINE_RESULT` token followed by `outcome=<ok|noop|error>`,
`actions=<N>`, and `detail=<short counters>`.

Use `ok` when this run merged, closed, fixed, commented, re-ran CI, pushed, or
otherwise changed state. Use `noop` when the sweep completed and the only
remaining PRs/CRs are accepted soft blockers such as recent draft WIP, pending
CI, already-flagged human gates, or an empty fleet. Use `error` only for a real
failure in this run. After printing `ROUTINE_RESULT` and the report, exit
without additional tool calls.

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
