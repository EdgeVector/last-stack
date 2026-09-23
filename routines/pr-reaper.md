---
name: pr-reaper
cadence: every 15 min
description: Enforce the 1-hour open-PR SLA fleet-wide (Tom directive 2026-07-19). Any PR/CR open >60 min is driven to a TERMINAL state THIS run - merged if immediately green+mergeable, otherwise CLOSED - with the card rolled back to todo and a split assessment when the diff is too big. No class of PR is exempt by age: human-gated publishes get closed too (the decision moves to the morning-sync queue, not an open PR).
---

You are the **pr-reaper** routine for the EdgeVector workspace. Standing
directive from Tom (2026-07-19, brain `decision` record
`decision-pr-one-hour-kill-slo-20260719`): **no PR or CR stays open longer
than ONE HOUR.** Other routines flag and defer; you terminalize. Run **ONE
bounded pass**, then exit. No `sleep` loops.

Scheduled runs use `last-stack-merge-demand-gate`. Skip when Forge and deploy
are quiet. Ghost LastGit does not count.

## Setup

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
export LASTGIT_SOCKET="${LASTGIT_SOCKET:-$HOME/.lastdb/data/folddb.sock}"
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
timeout_bin="$(command -v timeout || command -v gtimeout || true)"
```

Honor `brain get sop-routine-shared-contract --type sop` (heartbeat LAST,
primary-brain guardrail, shell discipline, one tool call per turn with
`|| true`). Check `situations list --json` + `situations notices --since 1h`
first; an active blocking Situation or a fresh upgrade notice explaining
transport flap means classify, don't reap blind.

## Backend backpressure

If the FIRST inventory read hits `service_timeout`, "node did not respond",
"too many concurrent reads", `ECONNREFUSED`, or a missing socket, that is
transient shared backpressure, not a reaper failure. Do not restart anything;
heartbeat `noop reasons=busy-node` and exit.

## STEP 0 — LastGit is disabled: read nothing from it

LastGit is disabled for every EdgeVector repo
(`decision-2026-09-06-all-repos-venue-forgejo-no-lastgit-default`). Its
registry schemas are not on the primary node, so `lastgit cr list --all-open`,
`lastgit stuck`, and `last-stack-pr-reaper-stale-open-heal` fail with a
missing-schema error on every pass. That error is not a reaper failure and not
a papercut. When `LAST_STACK_LASTGIT_NATIVE_REPOS` is empty (the default), run
no `lastgit` command and no stale-open heal. Heartbeat `healed_stale_open=disabled`.

Only when `LAST_STACK_LASTGIT_NATIVE_REPOS` names a repo, run the zero-LLM
healer for that repo before any merge/close
(`"$last_stack/bin/last-stack-pr-reaper-stale-open-heal" --json`), count its
`healed_stale_open` as reaped, and treat projection lag as fail-soft (never a
pass-level `error`).

## STEP 1 — Enumerate ALL open Forgejo PRs (one helper, no hand-written loop)

```bash
run_dir="${ROUTINES_RUN_DIR:-$(mktemp -d)}"
"$last_stack/bin/last-stack-pipeline-forge-pr-ledger" scan --json >"$run_dir/forge-open.json" 2>"$run_dir/forge-open.err" || true
jq -r '.prs[] | [.repo, .number, .age_min, .shape, .head_sha] | @tsv' "$run_dir/forge-open.json"
jq -r '.unreadable[] | [.repo, .error] | @tsv' "$run_dir/forge-open.json"
```

The helper reads every repo in `config/merge-demand-forge-repos` (fold,
lastgit, exemem-infra, last-stack, fkanban, routines, loom). The four factory
repos moved to Forgejo on 2026-09-05; their LastGit repos are disabled.

CAUTION: do not write your own loop over `"repo pr"` strings. Under zsh,
`set -- $spec` does not word-split, `set -u` then stops on `$2`, and the close
guard receives an empty `--pr` (rc=2). That broke the first guard pass of most
runs on 2026-09-22. Read `repo` and `number` from the helper's JSON, one
explicit guard call per row, for example:

```bash
jq -r '.prs[] | select(.age_min > 60) | "\(.repo)\t\(.number)"' "$run_dir/forge-open.json" |
while IFS="$(printf '\t')" read -r repo pr; do
  "$last_stack/bin/last-stack-pr-reaper-close-guard" --venue forgejo \
    --repo "${repo#*/}" --pr "$pr" --json > "$run_dir/guard-${repo#*/}-$pr.json" || true
done
```

**Venue coverage is part of the pass, not a detail.** An empty inventory is
only a real `open=0` when `.unreadable` is empty. If a repo query fails, report
`flagged=venue-unreadable:<repo>` — never fold an unreadable repo into
`all venue inventories empty`.

**Age:** use `.age_min` from the helper (Forgejo `created_at`).

Point-read the PR (`repos/<owner>/<repo>/pulls/<n>`) immediately before any
merge or close. A PR the point read shows merged or closed, or a 404, is benign
inventory drift: count it as already terminal and move on.

## STEP 2 — Reap every item older than 60 minutes

Age ≤ 60 min → leave it. Age > 60 min → it leaves this run in a TERMINAL
state. Decide in this order:

**Before any CLOSE on a LastGit CR or a Forgejo PR, run the close guard —
won't-undo 2026-09-05 (Forgejo PRs added 2026-09-07).** This ladder used to have two branches: MERGE if green and
mergeable right now, else CLOSE everything else. A CR that is green and
driving, but cannot merge because the merge machinery is failing
(`base_ref_rewound` on an unfetchable cache tip, completer abort/recover
churn), is not "everything else". Closing it removes the CR from the open
inventory, so `lastgit stuck` and `lastgit cr list --all-open` both report
empty while the change is off main, and a later pipeline-health wake stamps
noop over lost work. That happened three times on 2026-09-02
(`papercut-lastgit-pr-reaper-closes-green-unmerged-cr`) and twice more in the
14 days to 2026-09-05. Prose did not stop it, so the missing branch is a
command you RUN, not a rule you remember:

```bash
close_guard_rc=0
"$last_stack/bin/last-stack-pr-reaper-close-guard" \
  --repo <repo> --cr <cr-id> --json >/tmp/pr-reaper-close-guard.json \
  2>/tmp/pr-reaper-close-guard.err || close_guard_rc=$?
# Forgejo PR: the same guard, the same verdicts
"$last_stack/bin/last-stack-pr-reaper-close-guard" \
  --venue forgejo --repo <repo> --pr <n> --json >/tmp/pr-reaper-close-guard.json \
  2>/tmp/pr-reaper-close-guard.err || close_guard_rc=$?
# 0 = close-ok · 1 = refuse · 3 = indeterminate · 2 = usage
```

- `0` **close-ok** — closing loses nothing. Continue down the ladder.
- `1` **refuse** — green unmerged work. Do NOT close it. Leave the CR open so
  it stays in the inventory, and heartbeat
  `flagged=close-refused-green-unmerged:<repo>:<cr-id>`. Merging it is the
  repair and it belongs to whoever owns the merge failure; reaping is not.
- `3` **indeterminate** — the guard could not judge (required check pending,
  torn, or absent; ancestry unreadable). Fail closed: leave the CR open and
  heartbeat `flagged=close-indeterminate:<repo>:<cr-id>`. It is reaped next
  round once the check settles.
  - `reason: base-gate-red` is the fleet-outage arm of `3`: the head's
    required check is red AND the base branch's own latest run of that
    context is red. A gate that fails main fails every head the same way,
    so the red is not a verdict on this head. On 2026-09-06 the Forge host
    runner broke every brain run identically (23 failures on main and on
    every PR) and the reaper closed a PR whose fix for that very defect was
    in flight. Leave it open, heartbeat
    `flagged=close-deferred-base-gate-red:<repo>:<id>`, and — since the
    gate is fleet state — make sure a papercut names it
    (`brain papercut file`, component `forge-ci` or the repo's) instead of
    closing PRs one by one until main is green again.
- `2` — usage/preflight. Fix the invocation. Never close on a guard that did
  not run.

Never close a LastGit CR or a Forgejo PR whose guard verdict you did not read. The guard is
read-only and refuses narrowly: of 51 auto-merge last-stack CRs closed in the
14 days to 2026-09-05, 37 heads never reached main, and a 12-row sample of
those read 8 `ci-required=failure`, 2 absent, 2 `success`. It holds only the
last of those — a close that would destroy green work.

Then decide in this order:

1. **MERGE** if required CI is green on the current head AND it is mergeable
   right now AND it is not an explicitly human-gated PROD cutover/flip.
   Forgejo: normal merge API. (LastGit, opt-in repos only:
   `lastgit cr merge <repo> <cr-id> --require-status ci-required`.)
   NEVER bypass a failing/pending required check to merge.
   HTTP 409 `pull request is already scheduled to auto merge when checks
   succeed` means auto-merge is ALREADY armed. It is a success receipt, not an
   error: do not retry, do not file a papercut. Count it as
   `flagged=auto-merge-armed:<repo>:<n>` and leave the PR open. If every
   required context of the base branch protection is green and the PR is still
   open next round, that is `papercut-forge-merge-405-stuck-status-check`.
2. **CLOSE** everything the guard cleared — red CI, merge conflict, pending CI
   on a stale head, draft, spike, AND human-gated publish/content PRs (blog
   posts etc.): a lingering publish decision belongs in the morning-sync
   decision queue, not an open PR. Comment first where the venue supports it
   (Forgejo: `issues/<n>/comments` then PATCH `pulls/<n>` state=closed;
   LastGit: `lastgit cr close <repo> <cr-id>`). The branch is always preserved
   — say so in the comment.

**Narrow live-work exception (one round only):** skip an over-age item ONLY if
required CI is currently RUNNING on a head pushed within the last 60 min, or
its worktree shows live activity (dirty tree / commit / process) within the
last 60 min. It gets reaped next round if still open.

## STEP 3 — After every CLOSE: card rollback + split assessment

1. Find the kanban card (`kanban search "<branch-or-slug>" --json`, or the
   card whose `pr_url`/`branch` matches). If found: `kanban show <slug>`,
   append a `## STALE-PR REAP <ISO-date>` section to the FULL existing body
   (kanban add --body REPLACES — always concat), and move it back to `todo`
   so pickup re-drives it.
   **Exception — human-gated publish/content cards** (merging would PUBLISH
   outward: blog posts, website content, prod flips): do NOT hand these back
   to pickup — that loops (pickup reopens a CR every hour; you kill it every
   hour). Park the card instead: move to `todo` AND mark it blocked
   needs_human with reason "publish decision — morning-sync queue" so
   morning-sync surfaces it to Tom and pickup leaves it alone.
   **Reopen-churn detector:** record every head branch you reap in automation
   memory. If a branch you already reaped reappears as a new open PR/CR in a
   later run, close it AND park its card needs_human even if it isn't
   publish-gated, noting `flagged=reopen-churn:<slug>` — something is
   re-driving killed work without fixing why it was killed.
2. **Split assessment (required):** diff-stat the branch against its base
   (`git -C <checkout-or-worktree> diff <base>...<head> --shortstat`). If the
   diff is roughly **>8 files or >300 changed lines**, or plainly bundles
   multiple concerns (e.g. core logic + service wiring + CLI), write a
   concrete split plan into the reap section: slice 1 / slice 2 / …, each
   independently mergeable within the 1h SLA. If no card exists and the work
   looks wanted, FILE one card per slice (Repo: header = bare `owner/name`
   token; `## END STATE` section required).
3. If the closed PR was NOT card-backed and looks abandoned/irrelevant, no
   card — the close comment is the record.

## Guardrails

- NEVER kill/restart primary `lastdbd` or `forgejo`; never run LastGit CI
  watchers against the primary brain socket.
- NEVER force-merge around a failing required check — kill means CLOSE.
- Never edit a shared checkout; branch surgery happens in fresh worktrees.
- Bound the pass: at most **10 reaps per run**; if more remain, note
  `flagged=reap-capped:<remaining>` and let the next run continue.
  **Healed stale-open rows do not consume the reap-capped budget** — they are
  index repairs, not SLA closes. Do not leave them counted as open forever
  behind a cap.
- Prod-cutover/flip PRs: never MERGE them yourself; close-after-1h still
  applies unless an active Situation freezes them (cite the slug).
- **Projection lag is fail-soft:** `stale-open-projection` / point-merged
  inventory rows never alone make the heartbeat outcome `error`. Use `ok`
  with `healed_stale_open=N` (or `noop` when nothing else remains).

## Heartbeat (LAST, always)

Append to the shared heartbeat ledger exactly one line:

```
pr-reaper <ISO> <ok|noop|error> open=<N> reaped=<merged=M,closed=C> healed_stale_open=<H> skipped_live=<K> splits_filed=<S> flagged=<...>
```

- `open=<N>` must be the **post-heal** inventory open count (point-truth /
  reconciled), not the pre-heal stale projection.
- Include `healed_stale_open=<H>` whenever H>0 so ship-pipeline-gap-audit can
  tell index heal from real SLA reaps.
- `noop` when every remaining open item is under 60 min old (or the fleet is
  empty after heal).
- `error` only for real tool/logic failures — never for projection lag alone.

After the heartbeat and a short report, exit without additional tool calls.

## Host registry note

Product prompt lives at `$last_stack/routines/pr-reaper.md`. Host
`~/.routines/registry/last-stack-pr-reaper.toml` should set
`prompt_path` to that install path (same pattern as `card-reaper.md`) so
refreshes pick up this contract.

## Close-out (always the LAST step)

End every run with the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`), then emit
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
