---
name: wait-merge
version: 0.2.0
description: |
  Robustly wait for one or more GitHub PRs to merge, then report. Replaces the
  fragile "Watch PR N until merged" background command that exits 1 on transient
  merge-queue / CI states and then looks like a failure. Interprets PR state
  instead of trusting a watcher's exit code, tolerates merge-queue churn,
  re-asserts auto-merge when a clean+approved PR stalls, and only declares
  failure on a genuinely terminal state.
  Use when asked to "watch PR N until it merges", "wait for this PR to land",
  "babysit this PR to merge", "make sure PR N merges", or after opening a PR with
  auto-merge and you need to confirm it actually lands.
allowed-tools:
  - Bash
triggers:
  - wait for pr to merge
  - watch pr until merged
  - babysit pr
  - make sure pr merges
  - confirm pr landed
---

# wait-merge — confirm a PR actually lands, without false failures

## Why this exists

A naive pattern — a single long-lived background command like
`gh pr checks <n> --watch && gh run watch ...` labeled "Watch PR N until merged"
— **exits non-zero** the moment a check goes transiently red, the PR enters a
merge queue, or `--watch` returns on a non-success terminal. The harness then
surfaces it as a *failed task*, you re-kick it, and it fails again.

The fix: **don't trust a watcher's exit code. Poll PR state and interpret it.**
A non-zero exit is "re-poll," not "the PR failed."

## Interpret state, don't watch exit codes

Each poll, read the real state (one call, never let it cancel the turn):

```bash
gh -R <repo> pr view <n> \
  --json state,mergeStateStatus,mergeable,reviewDecision,statusCheckRollup,autoMergeRequest \
  2>/dev/null || true
```

Decision table:

| Observed | Meaning | Action |
|---|---|---|
| `state == MERGED` (or `mergedAt` set) | **Terminal: success** | Report merged, stop. |
| `state == CLOSED` (not merged) | **Terminal: closed without merge** | Report it, stop — do not reopen. |
| `mergeStateStatus` in `BEHIND` / `DIRTY` | behind base / conflicts | rebase on `origin/<base>`, re-verify, force-push with lease; keep polling |
| `reviewDecision == CHANGES_REQUESTED` | needs human/code response | report as blocked-on-review, stop looping (don't spin waiting on a human) |
| `statusCheckRollup` has a **required** check `FAILURE` (stable across 2 polls) | CI genuinely red | if it's your card, fix + push; otherwise report red, stop |
| `mergeStateStatus == BLOCKED` but checks green | usually auto-merge not armed, or in queue | re-assert auto-merge (below); keep polling |
| checks `PENDING` / `IN_PROGRESS`, or `mergeStateStatus` churning | **transient — NOT a failure** | keep polling |

A single red check or a `BLOCKED` status on one poll means nothing — CI flaps and
a merge queue transitions through ugly intermediate states. Only treat
red/blocked as real if it persists across at least two polls.

## Merge-queue gotcha

For merge-queue repos, `autoMergeRequest` can read **null in the REST/`pr view`
JSON even when auto-merge is actually armed**. Don't conclude "auto-merge isn't
set" from a null there — confirm via GraphQL:

```bash
gh api graphql -f query='{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<n>){autoMergeRequest{enabledAt}}}}' 2>/dev/null || true
```

Re-assert auto-merge when a clean, approved PR is just sitting. Match your
repo's merge policy:
- **Merge-queue repos** → bare `gh pr merge <n> --auto` (NO strategy flag; the
  queue sets the method). A `BLOCKED` state / `AWAITING_CHECKS` queue entry is
  the normal pre-merge resting state, not a failure.
- **Plain auto-merge** → `gh pr merge <n> --auto --squash` (or your repo's
  preferred method).
- A PR whose auto-merge predates its repo getting a queue may need a
  disable→re-enable to enter the queue (bare `--auto` no-ops on an
  already-armed PR).

Never force-merge around a failing required gate.

## How to actually wait (respect the async-wait rules)

**Never chain `sleep` to poll:**

1. **Best — re-enter on the next wake.** If a scheduled routine or a later turn
   will re-check, do one poll now, record state, and exit. Waiting is the gap
   *between* invocations, not a loop inside one.
2. **In-turn, if you must confirm now — sleepless foreground watcher, wrapped so
   its exit code can't end the turn:**
   ```bash
   gh -R <repo> pr checks <n> --watch || true   # returns when checks settle; || true neutralizes the exit-1
   ```
   then re-read `pr view` and apply the decision table. The watcher is just a
   blocking wait primitive — the **state read** is what decides, not its exit.
3. **Fire-and-continue** for long CI: launch the watch in the background and keep
   doing other work; you're re-invoked when it exits. Don't park the turn idle
   on it.

In scheduled/unattended runs: one tool call per turn, always append `|| true`,
and prefer (1) — exit and let the next scheduled run re-check.

## Stop conditions

Stop and report on: MERGED (success), CLOSED, persistent required-check failure
after a fix attempt, or CHANGES_REQUESTED (blocked on human). Don't loop
indefinitely on a PR that's waiting on a person — say what it's waiting for and
hand back.
