---
name: fkanban-pickup
cadence: hourly
description: Drain the ready board queue as fast as is safe — pick the top ready `todo` cards, optionally BATCH same-subsystem cards into one PR to cut CI cost, and fan them out to background fkanban-agent (WORK) workers, each driving its card(s) to a MERGED PR. If the queue is empty, just exit (or, with `Idle mode: ship-one-simplification` opted in, ship one small simplification PR instead). Never authors/ships card work itself.
---

You pick up to `<N, e.g. 8>` ready board cards per run and fan them out — one
background agent per WORK-UNIT (a singleton card, or a BATCH of ≤3 same-subsystem
cards landed as one PR) — each driving its card(s) all the way to a MERGED PR
(not just an opened PR), then exit. This is the WORK-mode counterpart to the
`fkanban-watch` (reconcile) routine — do NOT do reconcile work here. The goal is
to DRAIN THE READY QUEUE AS FAST AS IS SAFE every hour so cards don't back up.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly.

> **Why batch?** If your CI recompiles the whole workspace on every run
> regardless of diff size, 3 small same-subsystem PRs each pay a full CI run
> while one batched PR pays it once. Batching is a CI-cost lever — only batch
> cards that share a subsystem so the combined PR stays reviewable.

## Rate-limit guard (check FIRST)
- Do NOT start if your agent account is rate-limited. Spawning many parallel
  agents into a rate-limited account just produces half-finished, wedged agents.
- There's usually no reliable pre-flight check, so treat the error as the signal:
  if at ANY point you hit a rate-limit / 429 / "limit reached", STOP — do NOT
  spawn any more agents, do NOT sleep-and-retry (that violates no-sleep-to-wait
  and wedges the run). Print "at rate limit, not starting" and EXIT.
- If you already moved some cards to `doing` before hitting the limit, move them
  back to `todo` so the next run re-picks them, then exit.
- If your scheduled prompt gates pickup on merge-queue depth, compute that depth
  with GraphQL or a helper wrapping GraphQL. Never render or run
  a `gh pr` JSON request for `isInMergeQueue`; local GitHub CLI versions can
  reject that field before the routine starts.

## Setup
- Drive the board CLI from `<board repo dir>` with `<board CLI> ...`.
- Each spawned agent follows the **fkanban-agent** skill, WORK mode — that skill
  is the source of truth for the per-card lifecycle. This prompt is just the
  trigger + selection + fan-out rule.
- **Forge-hosted repos:** `gh` only works for github.com remotes. If a card's
  repo has its `origin` on a self-hosted forge (Forgejo/Gitea/GitLab, often on
  localhost), the worker must use that forge's API for PR create/merge/status —
  check the workspace brain/AGENTS.md for the repo's forge SOP before assuming
  GitHub, and never act on a read-only GitHub mirror.

## Selection rule (pick up to `<N>` cards)
1. `<board CLI> list --json`.
2. Eligible = a card in the `todo` column whose body has parseable `Repo:` and
   `Base:` header lines. `Repo:` must be either `owner/name` or an absolute local
   Git checkout path. `todo` is the ready queue — only work cards promoted there.
   Ignore `backlog` (unready) entirely.
3. Leave missing `Repo:`/`Base:` cards in `todo`; `fkanban-watch` owns the
   header self-heal path. Leave cards carrying a `BLOCKED:` note alone. For cards
   whose `Repo:` header is present but not a resolvable target, do NOT silently
   skip and reconsider them every run. Convert the card into a loud one-time
   blocker:
   - Read it with `<board CLI> show <slug> --json`.
   - Append exactly one line if absent: `BLOCKED: fkanban-pickup cannot resolve
     Repo: "<repo header>"; replace it with owner/name or an absolute Git
     checkout path.`
   - Persist the amended body via `<board CLI> add <slug> --column review
     --block-status needs_human --block-reason "Repo target not resolvable:
     <repo header>" < "$body_file"`, then confirm with `<board CLI> show <slug>
     --json`.
   - Examples that must take this deterministic blocker path unless a real Git
     checkout is proven before selection: `Repo: (workspace root — .claude/launch.json lives at /Users/tomtang/code/edgevector/.claude/launch.json; commit it in whichever repo tracks that file, else file note)` and `Repo: (machine-hygiene skill — /Users/tomtang/.claude or the repo tracking the machine-hygiene SKILL.md)`.
   This blocker conversion counts as forward action. Do it before computing
   work-units so the unchanged card is not logged as a recurring pickup skip.
4. Sort eligible cards by priority (lowest `position`; tie-break oldest
   `created_at`) and take the top `<N>`.
5. **Shared-build-cache sub-cap (if applicable):** if concurrent builds against
   one repo thrash a shared build cache (e.g. a workspace `target/` that can
   deadlock under `--all-targets`), cap how many of the selected cards may target
   that repo in one run (e.g. ≤3), and fill the remaining slots with cards
   targeting other repos. Leave the extras in `todo` for next hour. When in
   doubt, under-pick that repo — the next run drains the rest. Note: pickup runs
   overlap (this is fire-and-exit), so last hour's agents may still be in
   `doing`.
6. If none are eligible, EXIT cleanly (see "Nothing to pick up").

## Fan-out — spawn ONE background agent per WORK-UNIT
**Compute the work-units FIRST, before moving or spawning anything.**

**STEP A — group selected cards into work-units (MANDATORY, do this first).** A
work-unit is EITHER a singleton card OR a BATCH of 2–3 cards that share the SAME
`Repo:` + SAME `Base:` + a shared **subsystem tag** (the epic). Define your
subsystem tags for your codebase (a card's subsystem = the first such tag present
in its `tags`). Whenever 2+ selected cards share an epic, batch them into one
work-unit (≤3 per batch; a 4th+ same-epic card waits for next run). NEVER batch
across different repos/bases; NEVER batch a `blocked`/`design-needed` card or one
with a `BLOCKED:` note (keep it singleton). List your computed work-units
explicitly before proceeding (e.g. "unit1 = BATCH[a, b, c] (subsystemX);
unit2 = SINGLE[d]").

**STEP B — for EACH work-unit:**
- FIRST move its card(s) to `doing` (`<board CLI> move <slug> doing`) so siblings
  and the next run don't double-pick. For a batch, move ALL its cards.
- Use the fkanban CLI-supported command shapes. `show` and `move` use the
  current/default board context; only commands whose help lists a board option
  may receive one.
- Then spawn ONE background agent for that work-unit (run it in the background so
  this parent isn't blocked) — ONE agent per unit, so a 3-card batch is ONE
  agent/branch/PR, not three. Give each agent a fully self-contained prompt:
  - Singleton: "Follow the fkanban-agent skill, WORK mode. Work EXACTLY this one
    card: `<slug>`. Its Repo is `<repo>` and Base is `<base>`."
  - Batch: "Follow the fkanban-agent skill, WORK mode (BATCH). Work these
    same-subsystem cards as ONE combined PR: `<slug1>`, `<slug2>`[, `<slug3>`].
    Shared Repo `<repo>`, Base `<base>`, epic `<subsystem>`. Implement all on ONE
    branch, keep each card's change a coherent section of the PR body, and move
    ALL of them to `done` only once the single PR MERGES. If one card proves
    problematic (conflict, needs human judgment), SPLIT it out — leave it in
    `doing`→`review` with a `BLOCKED:` note — and ship the rest; never let one
    bad card strand the batch."
  - "Isolate your work only after a checkout-resolution guard: resolve `<repo>`
    to an explicit `<target-repo-root>` (never the aggregate workspace), verify
    it with `git -C "$target_repo" rev-parse --show-toplevel`, then change into
    `$target_repo` before any `git fetch` or `git worktree add
    <worktrees-dir>/<lead-slug> -b fkanban/<lead-slug> origin/<base>` command
    (for a batch, `<lead-slug>` = the highest-priority card). Never edit a shared
    checkout in place; never stash/reset/clean a shared repo. The worker must
    use `gh -R <repo>` for GitHub commands. If `<repo>` cannot be resolved, it
    must block the card in `review` instead of probing the workspace root."
  - "Implement per the card brief, matching the repo's conventions and style.
    Honor OUT OF SCOPE; keep the PR atomic. Run the brief's VERIFY commands and
    validate by running the app where the brief calls for it, not just tests."
  - "`git push -u origin HEAD` → `gh -R <repo> pr create --fill --base <base>` →
    enable auto-merge per the repo's merge strategy (for a merge-queue repo, bare
    `gh -R <repo> pr merge <n> --auto` — the queue sets the method; for plain auto-merge add
    your strategy flag)."
  - "Then DRIVE THE PR TO MERGED — do NOT hand off a green-but-unmerged PR (that
    fire-and-forget hand-off is exactly what lets PRs pile up stranded). Use the
    `wait-merge` skill (or a sleepless `gh -R <repo> pr checks <n> --watch`, NEVER `sleep`)
    and act on each state change: re-arm if auto-merge was dropped,
    `gh -R <repo> pr update-branch <n>` if BEHIND, rebase if DIRTY, fix if a required check
    fails. When MERGED, move the card (for a batch, EVERY card that shipped) to
    `done` and EXIT."
  - "When checking merge-queue membership, NEVER request `isInMergeQueue` through `gh pr view/list --json`; query the queue flag through the Last Stack `last-stack-gh-pr-queue-state` helper or `gh api graphql` with explicit owner/name variables, never `gh -R <repo> api graphql`."
  - "If you hit a GENUINE human-only blocker (ambiguous spec, a conflict needing
    product judgment, a required gate only a human can clear, a dependency on
    unmerged work): leave the branch clean, move the card to `review`, append a
    one-line `BLOCKED: <why>` note, and EXIT."
  - "CRITICAL: drive to MERGED, then EXIT. Wait ONLY with a FOREGROUND sleepless
    `--watch` that returns on real state change, held in THIS turn through to
    merge (bounded work, not idling). Do NOT push your fix, spawn a detached
    watcher, and end the turn 'to be re-woken' — that re-wake isn't reliable and
    the PR strands. NEVER a `sleep`-loop, NEVER a turn parked doing nothing. Do
    not pick up other cards, do not spawn sub-agents."
- After spawning all agents, this parent EXITS immediately. Do NOT wait, sleep,
  or park watching the spawned agents — they run independently; `fkanban-watch`
  is the backstop for anything that slips.

## Nothing to pick up
When the `todo` queue is empty, behavior depends on the scheduled prompt's **idle
mode** (default `exit`):

### Idle mode `exit` (default)
Just exit cleanly. Do NOT go hunt for a bug to fix and ship — in this mode the
routine is the BUILD EXECUTOR for ready cards, not a work author. Keeping the
queue full is the generator routines' job (`self-improvement-loop`,
`papercut-sweep`, `program-driver`, `groom-board`, and `fkanban-watch`'s
quiet-sweep all FILE cards). Report "queue empty, nothing to build" and exit.

### Idle mode `ship-one-simplification` (opt-in)
Enable by putting `Idle mode: ship-one-simplification` in the scheduled prompt.
Instead of idling, spend the wake shipping ONE small, high-confidence
simplification. Do this ONLY when zero cards were picked this run (if you picked
≥1 card, skip it and exit). The rate-limit guard still applies — if you hit a
limit, do NOT spawn it. Spawn exactly ONE background agent (no nested spawns, no
`sleep`-loops), then the parent EXITS immediately. Self-contained agent prompt:

> Idle-time simplification — no card; you're improving a codebase you work during
> a quiet wake. Pick ONE repo, preferring one WITHOUT a shared build cache that
> concurrent builds would thrash (see the shared-build-cache sub-cap in selection
> step 5); a shared-cache repo is allowed only if nothing else fits. Resolve it
> to an explicit local checkout, reject the aggregate workspace root, verify with
> `git -C "$target_repo" rev-parse --show-toplevel`, then `cd "$target_repo"` and
> `git fetch` before isolating in a fresh worktree off the default branch (`git
> worktree add <worktrees-dir>/simplify-<repo>-<short-ts> -b
> chore/simplify-<short-ts> origin/<default-branch>` — never
> edit/stash/reset a shared checkout; skip any repo that already has an active
> sibling worktree). Find ONE simplification
> scoped to a single concern — dead code, a redundant branch, a needless
> abstraction, a duplicated helper, an over-complex expression (reuse / clarity /
> efficiency, NOT a behavior change, NOT a bug hunt), small enough to review in
> one sitting. Make the edit, confirm the touched package still builds and its
> tests pass, open a PR (`gh -R <owner>/<repo> pr create --fill`, title prefixed `chore(simplify):`),
> enable auto-merge per the repo's merge strategy (merge-queue repo: bare `gh -R
> <owner>/<repo> pr merge <n> --auto`; plain auto-merge: add your strategy flag), then DRIVE IT TO
> MERGED — use the `wait-merge` skill or a sleepless `gh -R <owner>/<repo> pr checks <n> --watch`
> (NEVER `sleep`), acting on each state change. If you can't find a genuinely
> safe, worthwhile simplification, open NO PR, remove the worktree, and exit — do
> NOT manufacture churn. Stay dev-only: escalate only prod cutover / public-facing
> / money-legal / irreversible. One simplification only.

## Hard rules
- AT MOST `<N>` cards per run (and any shared-build-cache sub-cap from step 5) —
  one background agent per GROUP. Each agent works one card OR one same-epic batch
  (≤3) and drives its single PR to MERGED, or exits to `review` on a genuine
  human-only blocker — no nested spawning, no `sleep`-loops, no idle parking.
- Move each card to `doing` BEFORE spawning its agent.
- Never kill the process hosting your brain/board node or any node you didn't
  start. Never `stash`/`reset`/`clean` a shared repo — every agent isolates with
  `git worktree add`.
- Dev, not prod, when a card touches a prod-facing surface or an in-flight design.
- Before referencing "current state" of a repo, resolve the repo to an explicit
  local checkout first, then `git -C "$target_repo" fetch` and check the default
  branch — the work may already be merged (avoid a duplicate PR).

End with a one-line report: which cards you picked + spawned (by slug); or "queue
empty, nothing to build." Then exit.

> **Heartbeat (optional but recommended).** As the LAST action — even when the
> queue was empty or you aborted at the rate limit — call
> `<last-stack>/bin/last-stack-fbrain-append-heartbeat --line "fkanban-pickup
> <ISO-ts> <ok|noop|error> <one-line outcome>"`. `morning-sync` reads
> `routine-heartbeats` to make a silent pickup failure loud. Use `error` for the
rate-limit abort; `noop` when the queue was empty AND you did not spawn the idle
simplification agent; otherwise `ok` with the count of card agents spawned (and
note the idle simplification agent if you spawned one).
>
> If the parent spawned worker agents, the heartbeat must include the spawned
> child/thread ids when the harness exposes them. If the harness leaves stale
> child edges, active listeners, or other cleanup state that might suppress the
> next hourly pickup, record that explicitly as `error scheduler-cleanup-stale`
> in the heartbeat and automation memory. Do not let a successful worker merge
> hide the fact that future pickup runs may be suppressed.
