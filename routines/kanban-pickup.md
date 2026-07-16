---
name: kanban-pickup
cadence: every 5 minutes
description: Drain the ready board queue fast (one unit default, optional second sequential) — YOU perform kanban-agent WORK mode yourself in an isolated worktree and drive to a MERGED PR. No subagents, no collab SpawnAgent, no background harness fan-out. If the queue is empty, run Idle mode smart-heal (program next-slice, CodeRings hotspot, or low-risk simplification) instead of no-oping.
---

You pick ready work and **do it yourself** — isolate in a git worktree,
implement, open a PR/CR, drive it to MERGED. This is the WORK-mode counterpart
to `kanban-watch` (reconcile). Do **not** do reconcile work here. Do **not**
spawn sub-agents, collab workers, Task tools, or background
`codex`/`claude`/`grok` processes. Scheduled harness runs (esp.
`codex exec --ephemeral`) cannot keep collab children alive; fan-out was
silently dropping workers while cards sat stranded in `doing`.

**Throughput model (Tom 2026-07-14 — drain faster):** scheduled every ~5 minutes.
Default **one** work-unit per fire. If that unit merges with **≥35 minutes**
of session budget remaining and another non-overlapping eligible card exists,
you MAY claim and complete **one second** unit in the same run (still no
spawn/fan-out — sequential only). Prefer correctness; never strand a card in
`doing` without finishing or rolling it back to `todo`. If a prior run is
still in-flight (single-flight lock), this fire is skipped.

**Empty queue:** default **Idle mode: smart-heal** (below) so the fleet keeps
self-improving between feature waves. Prefer real program / North Star work
over random cleanup. Never invent product scope, never reopen closed planes
(desktop UI, transform/view/WASM).

## Wall-clock budget (hard)
Treat each scheduled fire as a bounded foreground session, not an open-ended
agent workspace. At the beginning of the run, record `run_started_epoch=$(date
-u +%s)` and use elapsed wall-clock time before every expensive phase.

- Do not start an idle implementation unless elapsed time is under **10
  minutes** and the chosen change is plausibly shippable within **25 minutes**.
- Do not start any new validation or PR/CR publish sequence after **35 minutes**
  elapsed. Instead, move any claimed-but-unpublished card back to `todo` (or
  leave a file-only card in `todo`), heartbeat `noop idle=budget-exhausted`, print
  `ROUTINE_RESULT outcome=noop detail=idle=budget-exhausted`, and EXIT.
- If elapsed time reaches **45 minutes** before a PR/CR URL has been recorded,
  stop immediately after rollback/memory note best-effort. Do not launch a final
  multi-command publish block near the harness timeout; the next scheduled fire
  can reclaim cleanly.
- Idle mode is optional when budget is tight. A clean `noop idle=budget-exhausted`
  is better than a red harness timeout with a zombie `doing` card.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path (routinesd injects
one under `## Dispatch envelope`), read and write **that exact file**. Prefer it
over any guessed path.

Fallback order only when no envelope path is present:
1. `${ROUTINES_HOME:-$HOME/.routines}/memory/<automation-id>/memory.md`
2. `${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`

`<automation-id>` is the routines registry id (e.g. `last-stack-fkanban-pickup`),
**not** the skill frontmatter `name:` (e.g. not bare `kanban-pickup`). Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly. If the
sandbox refuses the path, note `memory_unwritable=<path>` in the heartbeat and
continue — do not fail the whole run.

> **No-spawn policy (hard).** NEVER use Codex `SpawnAgent` / collab agents,
> Claude Task/subagent tools, `nohup codex|claude|grok … &`, or any other
> background agent launch. If you cannot finish the work-unit in this session,
> move cards back to `todo` (or `review` with `BLOCKED:` for a genuine human
> gate) and EXIT. A partial claim left in `doing` with no live worker is the
> failure mode this policy prevents.

## Rate-limit guard (check FIRST)
- Do NOT start if your agent account is rate-limited.
- If at ANY point you hit a rate-limit / 429 / "limit reached", STOP — do NOT
  sleep-and-retry. If you already moved a card to `doing`, move it back to
  `todo`, print "at rate limit, not starting", and EXIT.
- If your scheduled prompt gates pickup on merge-queue depth, compute that depth
  with GraphQL or a helper wrapping GraphQL. Never render or run a `gh pr` JSON
  request for `isInMergeQueue`.

## LastDB flap retry (bounded — try a few times)
LastDB/Mini can flap under load (brief `service_timeout`, "node did not respond",
"too many concurrent reads", `uds_connection_limit`, socket blips). **That is not
an outage.** For board/brain socket commands used by pickup (claim, list, show,
move, add, heartbeat append):

1. Prefer the helper when present:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   "$last_stack/bin/last-stack-lastdb-retry" --attempts 3 --sleep-ms 750 -- \
     <board CLI> pickup claim --json --worker "<automation-id>"
   ```
2. If the helper is missing, **retry the same command up to 3 total attempts**
   with a short ~0.5–1s pause between attempts on those transient signals only.
3. **Do not** restart `lastdbd`, do not run doctor/init, do not open an incident
   card solely for a flap.
4. **Do not** retry forever, and **do not** thrash on structural rejects:
   `max_outbox_entries` / `lastdb-sync-outbox-full` → one attempt then
   `noop busy-node board_write_rejected=…` (retrying only re-escalates).
5. Rate-limit remains non-retryable (see guard above).

Only after 3 failed attempts on a true flap signal should you heartbeat
`noop busy-node` and EXIT. Prefer completing a claimed unit over aborting on a
single blip mid-work: re-try the board write; if it still fails, roll the card
back to `todo` (or `pending_rollback=` in memory) per transport rules below.

## Setup
- Drive the board CLI from `<board repo dir>` with `<board CLI> ...`.
- Normalize the scheduled shell before any CLI-heavy work so GUI/sandboxed
  launches can still find `git`, `gh`, `curl`, `jq`, `<board CLI>`, and
  `<brain-cli>`:
  ```bash
  last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
  . "$last_stack/bin/last-stack-shell-prelude"
  "$last_stack/bin/last-stack-cli-preflight" git curl jq gh <board-cli> <brain-cli>
  ```
- Follow the **kanban-agent** skill, **WORK mode**, yourself — that skill is the
  source of truth for the per-card lifecycle. This prompt is selection + the
  no-spawn execution contract.
- **Forge-hosted repos:** `gh` only works for github.com remotes. If a card's
  repo has its `origin` on a self-hosted forge (Forgejo/Gitea/GitLab, often on
  localhost), use that forge's API for PR create/merge/status — check the
  workspace brain/AGENTS.md for the repo's forge SOP, and never act on a
  read-only GitHub mirror. Poll forge PR/CI JSON with
  `"$last_stack/bin/last-stack-forge-json-jq"` rather than raw `jq`.
- **LastGit-native repos:** resolve the concrete checkout and run
  `"$last_stack/bin/last-stack-pr-venue" --json <owner/repo> "$target_repo"`.
  If `.venue == "lastgit"`, read `brain get sop-lastgit-native-forge-workflow`,
  use `.lastgit_slug` and `.ci_context`, open a `lastgit cr` instead of a
  Forgejo/GitHub PR, and drive it with `lastgit cr view` / `lastgit ci status` /
  `lastgit cr complete --once`. Never run LastGit CI against the primary brain
  socket.

### Recover prior transport/board-write interruptions

Before selecting a new card, read automation memory. If the newest unresolved
`pending_rollback=<slug> reason=<reason>` entry exists from a prior run, first
try (with flap retries)
`"$last_stack/bin/last-stack-lastdb-retry" --attempts 3 -- <board CLI> move
<slug> todo`, append `pending_rollback_cleared=<slug>` on success, heartbeat
`ok cards=1 worked=<slug> result=rolled-back-todo reason=<reason>`, and EXIT.
If the board is still busy/unreachable after retries, heartbeat
`noop busy-node pending_rollback=<slug> attempts=3` and EXIT. Do not start
another work-unit while a prior claimed card only needs rollback reconciliation.

## Selection rule (form ONE work-unit)

**Preferred path (board CLI with `pickup claim`):** let the board pick and
CAS-claim the next card so you do not reimplement priority / overlap / races:

```bash
CLAIM_JSON=$("$last_stack/bin/last-stack-lastdb-retry" --attempts 3 -- \
  <board CLI> pickup claim --json --worker "<automation-id>")
# optional: --prefer-repo owner/name --exclude-repo owner/name --max-doing N
```

- If `claimed=true` and `reason=claimed`: the card is already in `doing`.
  **Do not** `move … doing` again. Use `.card` (slug, repo, base, body, …) as
  the work-unit and continue at Execute (isolate / implement). Still drive to
  **MERGED** as usual.
- If `claimed=false` (`no-eligible` / `at-capacity`): go to **Nothing to pick
  up** (or heartbeat noop at-capacity and EXIT). Include useful `skipped`
  entries in the heartbeat.
- If `pickup claim` still exits nonzero after the **bounded flap retries** above
  and the output mentions board-write backpressure (`max_outbox_entries`,
  `uds_connection_limit`, HTTP 503, `service_timeout`, "node did not respond",
  or "too many concurrent reads"), no card was claimed. Treat as temporary
  busy-node/no-write backpressure: do not run doctor/init, do not restart
  anything, do not fall through to manual claim, heartbeat
  `noop busy-node board_write_rejected=<reason> no_card_claimed attempts=3`,
  print `ROUTINE_RESULT outcome=noop detail=busy_node board_write_rejected=<reason>
  no_card_claimed`, and EXIT. If the heartbeat append itself fails with the same
  mutation rejection, still print the `ROUTINE_RESULT outcome=noop` trailer.
- If the CLI rejects `pickup claim` (unknown subcommand / old board binary):
  fall through to the manual steps below.

1. Read only the ready queue (with the same flap-retry wrapper):
   `"$last_stack/bin/last-stack-lastdb-retry" --attempts 3 -- <board CLI> list
   --column todo --json`. If the read still returns `service_timeout`, "node did
   not respond", or "too many concurrent reads" after retries, treat as
   busy-node backpressure: do not run doctor/init or restart anything;
   heartbeat `kanban-pickup ... noop busy-node attempts=3` and EXIT.
2. Eligible = a card in `todo` whose body has parseable `Repo:` and `Base:`
   headers. `Repo:` must be either `owner/name` or an absolute local Git checkout
   path. Ignore `backlog` entirely.
3. Leave missing `Repo:`/`Base:` cards in `todo` for `kanban-watch` self-heal.
   Leave cards with a `BLOCKED:` note alone. For present-but-unresolvable `Repo:`
   headers: append **one** body line
   `BLOCKED: kanban-pickup cannot resolve Repo: "<repo header>"; replace with
   owner/name or absolute Git checkout path.` if absent, **leave the card in
   `todo`**, and do **not** set `block_status=needs_human` (Tom 2026-07-14:
   no human gates for agent-filed routing bugs — next agent/groom fixes the
   header). Skip that card this run; pick another eligible card.
4. **Surface-overlap gate:** before a card can enter the work-unit, run
   `<board CLI> overlap <slug> --json`. On conflict, SKIP and leave in `todo`;
   note `collision=<slug>:<in-flight-slug>` in the heartbeat.
5. Sort eligible, non-colliding cards by priority (lowest `position`; tie-break
   oldest `created_at`). **Pipeline blocks outrank ordinary work:** if any
   eligible card has `Priority: P0` / tag `p0` **and** tags or title matching
   `pipeline` / `deploy-pipeline` / `deploy-pipeline-red-`, pick that card
   first (Tom 2026-07-14: a blocked merge or deploy pipeline is always P0).
   Form the work-unit(s):
   - Default: **one singleton** card.
   - Optionally batch 2–3 cards only if they share the same `Repo:`/`Base:` and
     a clear shared subsystem tag **and** you can finish the batch PR in this
     session. When in doubt, singleton.
   - After a singleton **merges**, if ≥35m budget remains, you may start **one
     more** non-overlapping singleton (sequential; no spawn).
6. **Shared-build-cache:** if the target repo has heavy concurrent-build risk
   and other `doing` work already targets it, prefer a different repo's card
   when one exists; else proceed with the singleton (you are not fanning out).
7. If none are eligible, go to **Nothing to pick up** (Idle mode: smart-heal).
   Do not invent a random feature first — follow the idle ladder.

## Execute — YOU are the worker (no fan-out)

**Compute the work-unit FIRST, then claim, then implement.**

1. **Claim:** move every card in the unit to `doing`
   (`<board CLI> move <slug> doing`). Prefer
   `move <slug> doing --from todo` when the CLI supports it (atomic claim). On
   `claim_conflict`, skip that card and pick the next eligible unit — do not
   implement without a successful claim.
2. **Read the full brief:** `<board CLI> show <slug> --json` for each card in
   the unit.
3. **Isolate (checkout-resolution guard):** resolve `<repo>` to an explicit
   `<target-repo-root>` and **reject the aggregate workspace root**. Verify with
   `"$last_stack/bin/last-stack-repo-op-guard" "$target_repo" "<workspace>"`
   and `git -C "$target_repo" rev-parse --show-toplevel`. Then:
   ```bash
   git -C "$target_repo" fetch origin
   git -C "$target_repo" worktree add \
     "${WORKTREES_DIR:-$HOME/.fkanban/worktrees}/<lead-slug>" \
     -b "kanban/<lead-slug>" "origin/<base>"
   cd "${WORKTREES_DIR:-$HOME/.fkanban/worktrees}/<lead-slug>"
   ```
   Never edit a shared checkout in place; never stash/reset/clean a shared repo.
4. **Implement** per the card brief and repo conventions. Honor OUT OF SCOPE.
   Run VERIFY commands from the brief; validate by running the app when the
   brief requires it, not only unit tests.
5. **Route review artifacts:**
   ```bash
   route_json="$("$last_stack/bin/last-stack-pr-venue" --json "<repo>" "$target_repo")"
   ```
   - `venue=github`: push → `gh -R <repo> pr create --fill --base <base>` →
     immediately record `pr_url` and `branch` on the card with
     `<board CLI> add <slug> --pr-url <url> --branch <branch>` → enable
     auto-merge per repo strategy → drive to MERGED with `wait-merge` or
     sleepless `gh -R <repo> pr checks <n> --watch` (NEVER `sleep`).
   - `venue=forgejo`: local Forgejo SOP/API only — never `gh` against a mirror;
     record `pr_url` and `branch` on the card immediately after create.
   - `venue=lastgit`: `lastgit cr create … --auto-merge …`, record
     `PR: lastgit://…` plus the branch on the card, drive with
     `lastgit cr view` / `ci status` / `cr complete --once`.
   - If pushing or opening the PR/CR fails because the review venue or required
     board transport is unavailable (for example a missing LastGit socket,
     socket-unreachable, `service_timeout`, "node did not respond", or "too
     many concurrent reads") **before a PR/CR URL is recorded**, do not report a
     routine `error` and do not leave the card silently claimed. Try to move the
     card back to `todo` so the next pickup can retry from a clean claim. If
     that board write also fails, append one automation-memory line
     `pending_rollback=<slug> reason=<transport-unavailable>` when writable,
     heartbeat `ok cards=1 worked=<slug> result=rolled-back-todo-unconfirmed
     reason=<transport-unavailable>`, print `ROUTINE_RESULT outcome=ok
     detail=worked=<slug> pr=none final_column=todo-unconfirmed
     reason=<transport-unavailable>`, and EXIT. This is an external transport
     interruption, not a harness fault; `kanban-watch` or the next pickup fire
     will reconcile the visible card state.
6. **On MERGED:** move every shipped card in the unit to `done` and EXIT.
7. **Genuine human-only blocker** (ambiguous spec, product judgment, human-only
   gate, dep on unmerged work): leave the branch clean, move the card(s) to
   `review`, append `BLOCKED: <why>`, and EXIT.
8. **If you must abort mid-work** (timeout pressure, rate limit, harness death
   risk) and the PR is not open yet: move card(s) **back to `todo`** so the next
   run reclaims them. Do not leave zombie `doing` cards with no worker.

### Hard bans during execute
- No nested agents / SpawnAgent / Task subagents / detached harness processes.
- No `sleep` loops; wait only with foreground sleepless `--watch` style tools.
- Do not pick up other cards in this run after the unit is chosen.
- Do not kill any brain/board node you did not start.

## Nothing to pick up
When the `todo` queue is empty (or nothing eligible after selection gates):

### Idle mode selection
- **Default: `smart-heal`** (always on unless the scheduled prompt sets
  `Idle mode: exit`).
- `Idle mode: exit` — report "queue empty, nothing to build" and EXIT (no invent).
- `Idle mode: ship-one-simplification` — only step 4 of the ladder below
  (legacy opt-in; prefer smart-heal).

### Idle mode `smart-heal` (default)
Zero pickup-eligible cards were claimed this run. Do **exactly one** action from
the ladder, top-down. Stop after the first successful action. Same no-spawn
rules, same one-PR / one-worktree discipline as WORK mode.

#### Anti-thrash (check before any idle work)
- If rate-limited / node busy → `noop busy-node` or rate-limit EXIT (same as
  normal path).
- If elapsed time is already **10 minutes or more**, do not start idle
  implementation. You may file one clear small PR card if that takes only a few
  minutes; otherwise heartbeat `noop idle=budget-exhausted` and EXIT.
- Read automation memory (if writable) for `last_idle_at` / `last_idle_repo` /
  `last_idle_kind`. If you shipped an idle merge in the **same repo** within
  the last **2 hours**, skip that repo (try another ladder step or true noop).
- At most **one** idle implement or **one** card-file per run — never both a
  full implement and a second invent.
- Do **not** reopen closed product planes: desktop/Tauri UI, transform/view/WASM,
  temp fold LastGit homes, inventing new North Stars.

#### Ladder (stop at first real action)

**1) Program / North Star next slice (preferred)**  
Read `brain get active-programs` (project). For each active program, if:
- Next move is a **concrete PR-sized** step, and
- No card for that step is already in `todo`/`doing`/`review`, and
- It is not human-gated / dep-blocked / capstone-as-pickup,
then either:
- **File one** PR card to `todo` with full GOAL/STEPS/VERIFY + `Repo:`/`Base:` +
  kanban-agent header, then **immediately claim and WORK it** in this same run
  (preferred when the slice is clear), **or**
- File only and EXIT if the slice is large / uncertain (heartbeat
  `ok idle=program-filed slug=…`).
Do not dump whole programs/capstones into `todo`. Prefer the most-behind program
with a clear next slice. Verify facts against `origin/main` before filing.

**2) CodeRings high-impact hotspot (sensor, not full scan)**  
Cheap read only — do **not** run a full fold capture every idle fire:
- Prefer existing board/brain signals: CodeRings continuous exerciser RED cards,
  weekly growth cards, or a recent snapshot summary if already on disk/brain.
- If you can identify **one** localizable hotspot (oversized file, dead export,
  obvious duplication, unused path) with a **small** fix:
  - **High confidence** (delete-only / internal, tests prove safe) → implement
    as a normal WORK unit (synthetic card optional but preferred for audit).
  - **Medium/low or API/data/crypto** → **file a PR card** only for human/groom
    pickup; do not force a large refactor.
- If CodeRings data is missing or stale and consult would be expensive → skip
  to step 3 (do not burn the idle slot on a weekly-scale scan).

**3) Known fleet chore (allowlist only)**  
Only if (1)–(2) yield nothing. At most one of:
- A ready papercut already on the board you can finish this session, or
- A single **idempotent** cleanup already described on an existing card in
  backlog that is PR-sized and unblocked (promote + work), or
- Note a true generator gap in the heartbeat (`idle=no-program-slice`) — do
  **not** run doctor/init, full canonicalize sweeps, or brain stress as idle.

**4) Low-risk simplification (fallback)**  
Ship **one** small improvement in a fresh worktree:
- Prefer: unused private code, dead flags, clear bug with test, redundant
  wrapper, docs that block installs (dev-only).
- Prefer repos with green CI and no open migration/human gate on that surface.
- **Ship** (PR → merge) when confidence is high and blast radius is low.
- **File for review** (card in `review` or PR without auto-merge) when medium
  confidence or public API / multi-crate / data format.
- If nothing safe → step 5.

**5) True noop**  
Heartbeat `noop idle nothing-safe` (distinguish from "didn't run"). EXIT.

#### After any idle ship/file
- Heartbeat must include `idle=<program-slice|coderings|chore|simplify|filed>`
  and `result=…` / `slug=…` / `pr=…` as applicable.
- If automation memory is writable, append one line:
  `last_idle_at=<ISO> kind=<…> repo=<…> slug=<…>`.
- Optional trailer: `ROUTINE_RESULT outcome=ok|noop detail=idle=…`.

## Hard rules
- AT MOST **two sequential work-units per run** (default one; second only if first merged and ≥35m budget left). Never spawn. Idle mode stays one action.
- Claim (`doing`) only for work **you** will execute in this session.
- Never kill the process hosting your brain/board node or any node you didn't
  start. Never `stash`/`reset`/`clean` a shared repo — isolate with
  `git worktree add`.
- Before referencing "current state" of a repo, fetch the default branch first —
  the work may already be merged.
- Idle work still honors **checkout-resolution guard**, overlap, and venue
  routing. Idle is not a free pass to edit the workspace root.

End with a one-line report: which card(s) you claimed + worked, PR/CR url if
any, final column (`done` / `review` / rolled-back `todo`); or idle outcome
(`idle=program-slice|coderings|chore|simplify|filed|nothing-safe`). Then exit.

> **Heartbeat (LAST action, always).** Call
> `<last-stack>/bin/last-stack-brain-append-heartbeat --line "kanban-pickup
> <ISO-ts> <ok|noop|error> <one-line outcome>"`.
>
> - `noop` — busy-node, or idle ladder reached nothing-safe / `Idle mode: exit`.
>   A pre-claim board-write rejection such as `max_outbox_entries` is `noop`
>   because no card was claimed and retrying immediately only re-escalates the
>   same shared backpressure.
> - `error` — rate-limit abort, non-backpressure claim failure with no recovery,
>   harness fault.
> - `ok` — you executed a unit (pickup or idle): include
>   `cards=<n> worked=<slug[,slug…]> result=merged|review-blocked|rolled-back-todo`
>   plus `pr=<url>` when opened; for idle add `idle=<kind>`. Example:
>   `ok cards=1 worked=foo-service-shared-surface-contract result=merged pr=http://…/pulls/12`.
>   Idle example:
>   `ok idle=simplify cards=1 worked=chore-drop-dead-helper result=merged pr=…`.
>
> Do **not** report `spawned=` or child thread ids — this routine does not spawn.
> Optional machine trailer (helps the routines dashboard): print a final line
> `ROUTINE_RESULT outcome=ok|noop|error detail=…` before exit.
