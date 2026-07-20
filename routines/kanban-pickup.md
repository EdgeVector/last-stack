---
name: kanban-pickup
cadence: every 5 minutes
description: Drain the ready board queue fast (one unit default, optional second sequential) — YOU perform kanban-agent WORK mode yourself in an isolated worktree and drive to a MERGED PR. No subagents, no collab SpawnAgent, no background harness fan-out. If the queue is empty, run Idle mode smart-heal (program next-slice, CodeRings hotspot, or low-risk simplification) instead of no-oping.
---

## NO REVIEW COLUMN (Tom 2026-07-16 — won't-undo)

There is **no `review` column**. Board columns are only:
`backlog → todo → doing → done`.

- Incomplete work: stay in `todo` or `doing`
- Complete work: `done` only with merge/END-STATE proof
- Intentional holds: rare `needs_human` → **backlog only**; `deferred` /
  `design_first` also stay out of `todo`

Never `kanban move <slug> review`. The live board rejects it. Do not invent
a review lane on custom boards either.


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

**Run-budget guard (prevents timeout zombies):** immediately after CLI preflight,
record a local start timestamp:
```bash
run_started_epoch="$(date +%s)"
run_timeout_min="${ROUTINES_TIMEOUT_MIN:-${TIMEOUT_MIN:-45}}"
```
Before starting any optional work after the first claimed unit — including a
second pickup unit, or idle smart-heal that would file **and immediately claim**
a new card — recompute remaining seconds:
```bash
elapsed=$(( $(date +%s) - run_started_epoch ))
remaining=$(( run_timeout_min * 60 - elapsed ))
```
Only start that optional executable work when `remaining >= 2100` (35 minutes).
If less remains, do not claim another card. For idle mode, prefer filing the
card only and exiting with `ok idle=program-filed` / `ok idle=filed`; if no
clear file-only slice exists, heartbeat `noop idle nothing-safe
reason=budget-low`. If a card has already been claimed and the budget drops
below 600 seconds before a PR/CR URL is recorded, roll it back to `todo` rather
than trying to beat the harness timeout.

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
  leave a file-only card in `todo`), heartbeat `noop idle=budget-exhausted`,
  print the machine trailer by using the `ROUTINE_RESULT` token followed by
  `outcome=noop detail=idle=budget-exhausted`, and EXIT.
- Before every foreground watcher, deploy wait, sync drain, or other END STATE
  proof that can run for minutes, recompute elapsed/remaining budget. Only start
  or continue that wait when there is enough time left to finish the proof,
  perform board closeout, append heartbeat, and print the machine trailer. If a
  claimed card still has no recorded PR/CR URL and remaining time is under
  **10 minutes**, roll it back to `todo` now and exit with
  `ok cards=1 worked=<slug> result=rolled-back-todo reason=budget-low`; do not
  watch external progress until the harness SIGTERM cuts off closeout.
- Long foreground commands must be self-timeboxed by the shell, not by manual
  interrupt. For deploys, Docker builds, Rust/Cargo builds, cloud smoke suites,
  sync drains, log follows, or any command that may ignore Ctrl-C while
  unwinding, compute a command timeout that ends before the closeout reserve
  and run it through `timeout -k 30s <seconds> ...` (or `gtimeout -k 30s` on
  macOS). If no timeout binary is available, do not start that command from
  pickup; roll the card back to `todo` and exit with `result=rolled-back-todo
  reason=no-command-timebox`. If the timeout fires, immediately record the
  observed state, move the unpublished card back to `todo`, heartbeat
  `ok cards=1 worked=<slug> result=rolled-back-todo reason=command-timebox`,
  print the machine trailer using the `ROUTINE_RESULT` token, and EXIT.
  Do not wait for a long child process to finish unwinding after the timebox.
- If elapsed time reaches **45 minutes** before a PR/CR URL has been recorded,
  stop immediately after rollback/memory note best-effort. Do not launch a final
  multi-command publish block near the harness timeout; the next scheduled fire
  can reclaim cleanly.
- If a PR/CR URL has been recorded and elapsed time reaches **35 minutes** (or
  fewer than **10 minutes** remain), stop immediately after one best-effort card
  update / memory note. Leave the card in `doing` with the recorded `pr_url` and
  `branch`, heartbeat
  `ok cards=1 worked=<slug> result=in-flight-budget-handoff pr=<url>
  final_column=doing`, print the `ROUTINE_RESULT` token followed by
  `outcome=<ok> detail=worked=<slug> result=in-flight-budget-handoff pr=<url>`,
  and EXIT.
  Do not start another fetch, rebase, push, validation retry, CI poll, manual
  LastGit status publication, `lastgit cr complete`, or merge-closeout command
  after the 35-minute publish stop line; `kanban-watch` or a later pickup fire
  can reconcile a visible in-flight PR/CR, but routinesd cannot recover a killed
  foreground process cleanly.
- LastGit missing-CI is a handoff condition, not pickup work. After a LastGit CR
  is recorded on the card, you may run **one** bounded `lastgit cr complete
  --once` / `lastgit ci status` check. If that still shows no `ci-required`
  status, do **not** hand-build or manually publish the status from pickup, do
  **not** start another watcher, and do **not** keep polling. Ensure a P0
  `pipeline` / `missing-ci` card exists for the affected CR if one is not already
  present, then heartbeat
  `ok cards=1 worked=<slug> result=in-flight-ci-pending pr=<url>
  final_column=doing`, print the `ROUTINE_RESULT` token followed by
  `outcome=ok detail=worked=<slug> result=in-flight-ci-pending pr=<url>`, and
  EXIT. `pipeline-health`, `kanban-watch`, or a later pickup fire owns the
  missing-CI repair path.
- Live operational proof watches are bounded too. If the card only needs
  evidence from an external process that is already running (sync catch-up,
  deploy propagation, mirror polling, CI completion, etc.), stop watching when
  fewer than **10 minutes** remain. If the END STATE is proven, close out the
  card immediately. If it is still pending, append the observed state to the
  card, move/leave it in `todo` as appropriate, heartbeat
  `ok cards=1 worked=<slug> result=rolled-back-todo reason=watch-budget-reserved`
  (or the proven closeout result), print the machine trailer by using the
  `ROUTINE_RESULT` token followed by `outcome=ok detail=worked=<slug>
  reason=watch-budget-reserved`, and EXIT. Never consume the final budget
  reserve with a watch loop and then start board closeout at the harness edge.
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

## Attribution (routine provenance — required)
You are a **scheduled routine** (dispatch envelope + env). Interactive human
sessions do not set `DRIVEN_BY=routine`. When you land code:

1. Prefer commits via `"$last_stack/bin/last-stack-git-commit" -m "…" …` so
   trailers are automatic. Or append `"$last_stack/bin/last-stack-attribution-trailers"`.
2. Every commit message and every PR / LastGit CR body must end with:
   - `Driven-By: routine`
   - `Automation-Id: <this Automation ID>`
   - `Run-Id: <ROUTINES_RUN_ID if set>`
3. LastGit CR actor is already `routine:<id>` via `LASTGIT_ACTOR` — do not
   override it to your shell username.
4. Situations notices: `--actor routine:<Automation ID>` (or `routine:<id>`).

Never invent these trailers when `DRIVEN_BY` is unset (interactive Tom-driven
work must stay unmarked).

> **No-spawn policy (hard).** NEVER use Codex `SpawnAgent` / collab agents,
> Claude Task/subagent tools, `nohup codex|claude|grok … &`, or any other
> background agent launch. If you cannot finish the work-unit in this session,
> move cards back to `todo` before a PR/CR is recorded, or to `backlog` with
> `block_status=needs_human` for a genuine human gate, and EXIT. A partial claim
> left in `doing` with no live worker is the
> failure mode this policy prevents.

## Rate-limit guard (check FIRST)
- Do NOT start if your agent account is rate-limited.
- If an active Situation, preflight, or harness notice says this automation is
  fenced by a Codex usage-limit / rate-limit **before any card is claimed**, do
  no work, do not claim a card, heartbeat `noop rate-limit ... no_card_claimed`,
  print the final machine trailer using the `ROUTINE_RESULT` token followed by
  `outcome=noop detail=rate-limit active_situation=<slug> no_card_claimed`, and
  EXIT. This is an intentional external blocker heartbeat, not a routine error.
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
- Record `run_started_epoch` / `run_timeout_min` for the run-budget guard above.
  The prelude must leave `~/.local/bin` ahead of ad-hoc checkout paths so
  host-track-managed CLI installs win over stale WIP binaries. Before expensive
  work, or whenever `brain`, `<board-cli>`, `situations`, `lastgit`, or another
  shared CLI behaves oddly, run `host-track status` when available and
  `<cmd> which` (for example `lastgit which`) before changing PATH or running a
  checkout-local command.
- **Direct `prompt_path` freshness guard:** pickup workers load this file
  directly from the installed Last Stack checkout, so they do not get
  `last-stack-routine-read`'s auto-upgrade before prompt load. After CLI
  preflight and before any board claim, run:
  ```bash
  if [ -x "$last_stack/bin/last-stack-self-upgrade" ]; then
    upgrade_check="$("$last_stack/bin/last-stack-self-upgrade" --check-only --reason=kanban-pickup-prompt-freshness 2>&1 || true)"
    case "$upgrade_check" in
      *"result=would-upgrade"*)
        if "$last_stack/bin/last-stack-self-upgrade" --reason=kanban-pickup-prompt-freshness >/tmp/last-stack-pickup-self-upgrade.$$ 2>&1; then
          stale_detail="stale-last-stack-install upgraded-before-claim no_card_claimed"
        else
          stale_detail="stale-last-stack-install upgrade-failed no_card_claimed"
        fi
        rm -f /tmp/last-stack-pickup-self-upgrade.$$
        "$last_stack/bin/last-stack-brain-append-heartbeat" --line "kanban-pickup $(date -u +%Y-%m-%dT%H:%M:%SZ) noop $stale_detail" || true
        printf '%s %s\n' 'ROUTINE_RESULT' "outcome=noop detail=$stale_detail"
        exit 0
        ;;
    esac
  fi
  ```
  If the upgrade attempt fails, still do not claim a card from a stale prompt:
  heartbeat `noop stale-last-stack-install upgrade-failed no_card_claimed` and
  exit. The next scheduled fire can retry after the install is current.
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
- If `claimed=false` with `reason=at-capacity`, or with any non-empty `skipped`
  list / `scanned_ready>0` (for example `surface-overlap`), this is **not** an
  empty queue. Heartbeat `noop no-claim reason=<reason> skipped=<slug:reason>`
  and EXIT. Do not enter idle mode while ready-but-conflicting work exists.
- If `claimed=false` only because the ready queue is truly empty
  (`scanned_ready=0` and no skipped cards), go to **Nothing to pick up**. Include
  the claim reason in the heartbeat. If diagnostics show default-`todo` blockers
  that are only terminal North Star proof cards (`Kind: validation` / `meta`,
  `terminal-verification`, `terminal` + `north-star` tags), first run the narrow
  repair helper:
  `"$last_stack/bin/last-stack-park-terminal-validation-todo" --board-cli <board CLI> --json`.
  The helper reads only `todo`, excludes `Kind: pr`, idempotently parks those
  proof cards in `backlog`, and also parks pending valid non-PR `DONE-WHEN`
  cards while closing satisfied ones to `done`. Do not hand-sweep the board. If
  the helper reports `parked>0` or `done>0`, treat that as this run's one idle
  action: heartbeat `ok idle=terminal-validation-parked result=parked-card
  parked=<n> done=<n>`, print the `ROUTINE_RESULT` token followed by
  `outcome=ok detail=idle=terminal-validation-parked parked=<n> done=<n>`, and
  EXIT. Continue to idle mode only when the helper reports zero changes.
- If `pickup claim` still exits nonzero after the **bounded flap retries** above
  and the output mentions board-write backpressure (`max_outbox_entries`,
  `uds_connection_limit`, HTTP 503, `service_timeout`, "node did not respond",
  or "too many concurrent reads"), no card was claimed. Treat as temporary
  busy-node/no-write backpressure: do not run doctor/init, do not restart
  anything, do not fall through to manual claim, heartbeat
  `noop busy-node board_write_rejected=<reason> no_card_claimed attempts=3`,
  print the machine trailer by using the `ROUTINE_RESULT` token followed by
  `outcome=noop detail=busy_node board_write_rejected=<reason> no_card_claimed`,
  and EXIT. If the heartbeat append itself fails with the same mutation
  rejection, still print the machine trailer with `outcome=noop`.
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
7. If none are eligible because all ready work collided with `doing` cards,
   shared-build-cache, surface overlap, or another in-flight claim, heartbeat
   `noop queue-blocked skipped=<slug:reason,...>` and EXIT. That is pipeline
   backpressure, not idle capacity.
8. If none are eligible because the queue is genuinely empty, go to **Nothing to
   pick up** (Idle mode: smart-heal). If the only todo noise is terminal North
   Star proof cards, run `last-stack-park-terminal-validation-todo`; if it parks
   or completes any card, heartbeat `ok idle=terminal-validation-parked
   result=parked-card` and EXIT before starting idle invent.
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
  mkdir -p "${WORKTREES_DIR:-$HOME/.fkanban/worktrees}"
  git -C "$target_repo" worktree add \
    "${WORKTREES_DIR:-$HOME/.fkanban/worktrees}/<lead-slug>" \
    -b "kanban/<lead-slug>" "origin/<base>"
  cd "${WORKTREES_DIR:-$HOME/.fkanban/worktrees}/<lead-slug>"
  ```
  `WORKTREES_DIR` must be outside the shared checkout; never point it at
  `<repo>/.worktrees` or any other repo-local path. Never edit a shared checkout
  in place; never blanket stash/reset/clean a shared repo.
  If you discover that you started in the shared checkout before isolating, move
  only your own edits into the worktree, restore those exact files in the shared
  checkout, or run `last-stack-repark-shared-checkouts` to salvage attributable
  leftovers. Do not leave abandoned root-checkout edits behind.
4. **Implement** per the card brief and repo conventions. Honor OUT OF SCOPE.
   Run VERIFY commands from the brief; validate by running the app when the
   brief requires it, not only unit tests. Before starting any long-running
   VERIFY / END STATE proof such as a deploy wait, cloud sync drain, status
   watch, or log-follow, recompute remaining budget. Do not begin the wait
   unless it can plausibly finish with at least a 5-minute closeout margin. If
   the card has no recorded PR/CR URL yet and the margin is gone, move it back
   to `todo`, heartbeat `ok ... result=rolled-back-todo reason=budget-low`,
   print the `ROUTINE_RESULT` token followed by
   `outcome=ok detail=worked=<slug> final_column=todo reason=budget-low`, and
   EXIT. For long deploy/build/proof commands, reserve closeout time by wrapping
   the command in `timeout -k 30s <seconds> ...` or `gtimeout -k 30s <seconds>
   ...`; choose `<seconds>` so the command returns before the 10-minute reserve.
   A command timebox firing is a clean rollback/handoff result, not a routine
   error, provided the card is moved back to `todo` or a pending rollback is
   written to automation memory.
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
   - Before every expensive post-publish operation (fetch/rebase after a
     non-fast-forward push, another push, validation retry, CI watch/poll,
     `lastgit ci status`, `lastgit cr complete`, or merge-closeout polling),
     recompute elapsed/remaining budget from
     `run_started_epoch` / `run_timeout_min`. If a PR/CR URL and branch are
     already recorded and either elapsed time is **35 minutes or more** or fewer
     than **10 minutes** remain, do not continue the publish/merge loop.
     Heartbeat `ok cards=1 worked=<slug>
     result=in-flight-budget-handoff pr=<url> final_column=doing`, print
     the `ROUTINE_RESULT` token followed by `outcome=<ok>
     detail=worked=<slug> result=in-flight-budget-handoff pr=<url>`, and EXIT.
     This is a clean
     bounded handoff, not an error; the card is visible with a review artifact
     for `kanban-watch` / the next scheduled fire.
   - If pushing or opening the PR/CR fails because the review venue or required
     board transport is unavailable (for example a missing LastGit socket,
     socket-unreachable, `service_timeout`, "node did not respond", or "too
     many concurrent reads") **before a PR/CR URL is recorded**, do not report a
     routine `error` and do not leave the card silently claimed. Try to move the
     card back to `todo` so the next pickup can retry from a clean claim. If
     that board write also fails, append one automation-memory line
     `pending_rollback=<slug> reason=<transport-unavailable>` when writable,
     heartbeat `ok cards=1 worked=<slug> result=rolled-back-todo-unconfirmed
     reason=<transport-unavailable>`, print the machine trailer by using the
     `ROUTINE_RESULT` token followed by `outcome=ok detail=worked=<slug>
     pr=none final_column=todo-unconfirmed reason=<transport-unavailable>`,
     and EXIT. This is an external transport
     interruption, not a harness fault; `kanban-watch` or the next pickup fire
     will reconcile the visible card state.
6. **On MERGED (hard closeout — verify before claiming done):**
   Before board closeout, leave any shared checkout you touched clean or
   explicitly salvaged; the isolated worktree may be removed later, but the
   ambient `~/code/edgevector/<repo>` checkout is not your working copy.
   For every shipped slug, run the closeout helper (preferred) or equivalent:
   ```bash
   "$last_stack/bin/last-stack-card-closeout" <slug> \
     --pr-url "<merged-pr-or-lastgit-cr-url>" \
     --branch "<head-branch>"
   ```
   The helper stamps PR/branch, moves to `done`, and **re-reads** the card.
   You may print `final_column=done` / "card is done" **only** after the helper
   exits 0 (or after `show --json` proves `column=done`). If closeout fails,
   retry once with `--force`; if still not done, heartbeat
   `result=merged-board-closeout-failed` and EXIT without lying about column.
   Then EXIT the run (no second unit after a failed closeout).
7. **Genuine human-only blocker** (ambiguous spec, product judgment, human-only
   gate, dep on unmerged work): leave the branch clean, move the card(s) to
   `backlog` with `block_status=needs_human`, append `BLOCKED: <why>`, and
   EXIT.
8. **If you must abort mid-work** (timeout pressure, rate limit, harness death
   risk) and the PR is not open yet: move card(s) **back to `todo`** so the next
   run reclaims them. Do not leave zombie `doing` cards with no worker.
9. **Never re-claim a card already in `done` with a merged PR** for the same
   unit in this or a sibling fire — that is how concurrent pickups re-open
   `doing` after a good closeout.

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

#### Idle budget guard
- Idle mode is allowed only after a **true empty queue** claim/read, not after
  `surface-overlap`, `at-capacity`, or any ready-card skip.
- Start idle with a bias to fast exit: if the first cheap probe does not reveal
  a clear PR-sized action, heartbeat `noop idle nothing-safe` and EXIT.
- Do not run broad repo scans (`rg --files` / whole-repo `rg`) or open an idle
  worktree unless you can still finish and merge with at least a 10-minute
  harness margin. If that margin is uncertain, file one card or true-noop.
- A run may either file one idle card **or** work one already-existing card; it
  must not create a new synthetic idle card and then claim/work that same card
  in the same fire.

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

**0) Feature Ship Loop frontier (preferred over idle invent)**  
Canonical: brain `sop-feature-ship-loop`. If any live `feature-owner` card has
`STATUS: driving|proving` and a pickup-ready `Kind: pr` child tagged
`feature-ship` is already in `todo`, **do not idle** — EXIT so a sibling
pickup claims it (or claim it if you are selecting from todo). If the frontier
slice is only in `backlog` and unblocked, promote that one card to `todo` and
EXIT with `ok idle=feature-frontier-promoted slug=...` (do not implement in the
same fire unless you claimed it via normal WORK). Never pick up the
feature-owner validation card itself. Never invent idle simplifications while a
P0/P1 feature-ship frontier is waiting.

Only `Kind: pr` child frontiers are pickup work. If the next feature frontier is
a terminal proof card (`Kind: validation` / `meta` / `tracker`, or any non-PR
card whose only executable contract is `DONE-WHEN`), do not promote or claim it
from pickup. If such a terminal proof card already drifted into default `todo`,
run `last-stack-park-terminal-validation-todo` and EXIT with the helper outcome;
`feature-prove` / `kanban-watch` own the proof evaluation path.

Access pattern for this frontier probe must stay scan-free: read scoped queues
with `fkanban list --column todo --json` and `fkanban list --column backlog
--json`, filter those previews locally for `feature-owner` / `feature-ship`
candidate slugs, then run keyed `fkanban show <slug> --json` only for the few
candidates whose body or deps are needed. Do not run broad board search or
full-body board scans from this idle hot path; if scoped reads do not identify
a clear frontier quickly, continue down the idle ladder or true-noop.

**1) Program / North Star next slice (preferred)**  
Read `brain get active-programs` (project). For each active program, if:
- Next move is a **concrete PR-sized** step, and
- The candidate is pickup work with `Kind: pr`, and
- No card for that step is already in `todo`/`doing`/`backlog`, and
- It is not human-gated / dep-blocked / capstone-as-pickup,
then either:
- **File one** PR card to `todo` with full GOAL/STEPS/VERIFY + `Repo:`/`Base:` +
  `Kind: pr` + kanban-agent header, then EXIT with `ok idle=program-filed slug=...` so the
  next pickup fire claims it with a fresh budget, **or**
- File only and EXIT if the slice is large / uncertain (heartbeat
  `ok idle=program-filed slug=…`).
Existing terminal, capstone, tracker, meta, or validation cards stay in
`backlog`; pickup must not force them into `todo`. If a program's next visible
artifact is non-pickup work, skip it or file a concrete `Kind: pr` follow-up
card instead of promoting the terminal card itself. Do not dump whole
programs/capstones into `todo`. Prefer the most-behind program with a clear
next slice. Verify facts against `origin/main` before filing.

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
File **one** small improvement for later pickup:
- Prefer: unused private code, dead flags, clear bug with test, redundant
  wrapper, docs that block installs (dev-only).
- Prefer repos with green CI and no open migration/human gate on that surface.
- Create a full PR-shaped kanban card in `todo` with Repo/Base/Branch/Kind,
  GOAL/STEPS/VERIFY/END STATE, and surfaces.
- Heartbeat `ok idle=filed slug=<slug> result=filed-card`, print the machine
  trailer by using the `ROUTINE_RESULT` token followed by
  `outcome=ok detail=idle=filed slug=<slug> result=filed-card`, and EXIT.
- Do **not** immediately claim or implement the card you just created. A later
  pickup fire will claim it through normal overlap and budget gates.
- Only ship instead of file when the simplification is already represented by
  an existing unblocked card before idle starts and you can merge it without
  creating a new card first.
- If nothing safe → step 5.

**5) True noop**  
Heartbeat `noop idle nothing-safe` (distinguish from "didn't run"). EXIT.

#### After any idle ship/file
- Heartbeat must include `idle=<program-slice|coderings|chore|simplify|filed>`
  and `result=…` / `slug=…` / `pr=…` as applicable.
- If automation memory is writable, append one line:
  `last_idle_at=<ISO> kind=<…> repo=<…> slug=<…>`.
- Print a final trailer by using the `ROUTINE_RESULT` token followed by
  `outcome=ok|noop detail=idle=...`, then EXIT immediately. Do not continue to
  another card, another idle ladder step, or implementation after recording an
  idle terminal result.

## Hard rules
- AT MOST **two sequential work-units per run** (default one; second only if first merged and ≥35m budget left). Never spawn. Idle mode stays one action: file one card or work one pre-existing card, never both.
- Claim (`doing`) only for work **you** will execute in this session.
- Never kill the process hosting your brain/board node or any node you didn't
  start. Never `stash`/`reset`/`clean` a shared repo — isolate with
  `git worktree add`.
- Before referencing "current state" of a repo, fetch the default branch first —
  the work may already be merged.
- Idle work still honors **checkout-resolution guard**, overlap, and venue
  routing. Idle is not a free pass to edit the workspace root.

End with a one-line report: which card(s) you claimed + worked, PR/CR url if
any, final column (`done` / human-gated `backlog` / rolled-back `todo`); or idle outcome
(`idle=program-slice|coderings|chore|simplify|filed|nothing-safe`). Then exit.

> **Heartbeat (LAST action, always).** Call
> `<last-stack>/bin/last-stack-brain-append-heartbeat --line "kanban-pickup
> <ISO-ts> <ok|noop|error> <one-line outcome>"`.
>
> - `noop` — busy-node, or idle ladder reached nothing-safe / `Idle mode: exit`.
>   A pre-claim board-write rejection such as `max_outbox_entries` is `noop`
>   because no card was claimed and retrying immediately only re-escalates the
>   same shared backpressure.
>   A pre-claim active Situation / harness fence for Codex usage-limit is also
>   `noop rate-limit ... no_card_claimed`; it should not file routine-error P0s.
> - `error` — rate-limit after a card was claimed and could not be safely rolled
>   back, non-backpressure claim failure with no recovery, harness fault.
> - `ok` — you executed a unit (pickup or idle): include
>   `cards=<n> worked=<slug[,slug…]> result=merged|human-blocked|rolled-back-todo|in-flight-budget-handoff`
>   plus `pr=<url>` when opened; for idle add `idle=<kind>`. Example:
>   `ok cards=1 worked=foo-service-shared-surface-contract result=merged pr=http://…/pulls/12`.
>   Idle example:
>   `ok idle=simplify cards=1 worked=chore-drop-dead-helper result=merged pr=…`.
>
> Do **not** report `spawned=` or child thread ids — this routine does not spawn.
> Optional machine trailer (helps the routines dashboard): print a final line
> a machine trailer before exit: the token `ROUTINE_RESULT`, then
> `outcome=ok|noop|error detail=...`.

## LastDB access

Do not full-scan LastDB schemas on hot paths. Prefer column-scoped `kanban list --column` and keyed reads. See `docs/lastdb-no-product-scan.md`.
