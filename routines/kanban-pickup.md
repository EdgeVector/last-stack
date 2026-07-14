---
name: kanban-pickup
cadence: every 15 minutes
description: Drain the ready board queue one work-unit at a time — YOU perform kanban-agent WORK mode yourself in an isolated worktree and drive to a MERGED PR. No subagents, no collab SpawnAgent, no background harness fan-out. If the queue is empty, exit (or idle-mode simplification if opted in).
---

You pick **one** ready work-unit per run and **do the work yourself** — isolate
in a git worktree, implement, open a PR/CR, drive it to MERGED, then exit. This
is the WORK-mode counterpart to `kanban-watch` (reconcile). Do **not** do
reconcile work here. Do **not** spawn sub-agents, collab workers, Task tools,
or background `codex`/`claude`/`grok` processes. Scheduled harness runs (esp.
`codex exec --ephemeral`) cannot keep collab children alive; fan-out was
silently dropping workers while cards sat stranded in `doing`.

**Throughput model:** one reliable work-unit per fire, scheduled every ~15
minutes. Prefer correctness over parallel fan-out. If a prior run is still
in-flight (single-flight lock), this fire is skipped — that is fine; do not
try to overlap yourself. The next free slot drains the next card.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
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

## Selection rule (form ONE work-unit)
1. Read only the ready queue: `<board CLI> list --column todo --json`. If the
   read returns `service_timeout`, "node did not respond", or "too many
   concurrent reads", treat it as busy-node backpressure: do not run doctor/init
   or restart anything; heartbeat `kanban-pickup ... noop busy-node` and EXIT.
2. Eligible = a card in `todo` whose body has parseable `Repo:` and `Base:`
   headers. `Repo:` must be either `owner/name` or an absolute local Git checkout
   path. Ignore `backlog` entirely.
3. Leave missing `Repo:`/`Base:` cards in `todo` for `kanban-watch` self-heal.
   Leave cards with a `BLOCKED:` note alone. For present-but-unresolvable `Repo:`
   headers, convert once to a loud human blocker — do not re-skip every hour:
   - Append exactly one line if absent: `BLOCKED: kanban-pickup cannot resolve
     Repo: "<repo header>"; replace it with owner/name or an absolute Git
     checkout path.`
   - Persist via `<board CLI> add <slug> --column review
     --block-status needs_human --block-reason "Repo target not resolvable:
     <repo header>"` and confirm with `show`.
   - Examples that must take this path unless a real Git checkout is proven
     before selection: `Repo: (workspace root — .claude/launch.json lives at
     /Users/tomtang/code/edgevector/.claude/launch.json; commit it in whichever
     repo tracks that file, else file note)` and
     `Repo: (machine-hygiene skill — /Users/tomtang/.claude or the repo tracking
     the machine-hygiene SKILL.md)`.
4. **Surface-overlap gate:** before a card can enter the work-unit, run
   `<board CLI> overlap <slug> --json`. On conflict, SKIP and leave in `todo`;
   note `collision=<slug>:<in-flight-slug>` in the heartbeat.
5. Sort eligible, non-colliding cards by priority (lowest `position`; tie-break
   oldest `created_at`). Form **exactly one** work-unit:
   - Prefer a **singleton** (one card).
   - Optionally batch 2–3 cards only if they share the same `Repo:`, same
     `Base:`, and a clear shared subsystem tag **and** you can finish the batch
     PR in this single session. When in doubt, singleton.
6. **Shared-build-cache:** if the target repo has heavy concurrent-build risk
   and other `doing` work already targets it, prefer a different repo's card
   when one exists; else proceed with the singleton (you are not fanning out).
7. If none are eligible, EXIT cleanly (see "Nothing to pick up").

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
When the `todo` queue is empty (or nothing eligible):

### Idle mode `exit` (default)
Exit cleanly. Report "queue empty, nothing to build". Do NOT invent work.

### Idle mode `ship-one-simplification` (opt-in)
Only if the scheduled prompt contains `Idle mode: ship-one-simplification` and
zero cards were claimed this run: ship ONE small high-confidence simplification
**yourself** in a fresh worktree (same no-spawn rules). If you cannot find a
safe simplification, open no PR and exit.

## Hard rules
- AT MOST **one work-unit per run** (singleton preferred).
- Claim (`doing`) only for work **you** will execute in this session.
- Never kill the process hosting your brain/board node or any node you didn't
  start. Never `stash`/`reset`/`clean` a shared repo — isolate with
  `git worktree add`.
- Before referencing "current state" of a repo, fetch the default branch first —
  the work may already be merged.

End with a one-line report: which card(s) you claimed + worked, PR/CR url if
any, final column (`done` / `review` / rolled-back `todo`); or "queue empty,
nothing to build." Then exit.

> **Heartbeat (LAST action, always).** Call
> `<last-stack>/bin/last-stack-brain-append-heartbeat --line "kanban-pickup
> <ISO-ts> <ok|noop|error> <one-line outcome>"`.
>
> - `noop` — queue empty / busy-node / nothing eligible (and no idle ship).
> - `error` — rate-limit abort, claim failure with no recovery, harness fault.
> - `ok` — you executed the unit: include
>   `cards=<n> worked=<slug[,slug…]> result=merged|review-blocked|rolled-back-todo`
>   plus `pr=<url>` when opened. Example:
>   `ok cards=1 worked=foo-service-shared-surface-contract result=merged pr=http://…/pulls/12`.
>
> Do **not** report `spawned=` or child thread ids — this routine does not spawn.
> Optional machine trailer (helps the routines dashboard): print a final line
> `ROUTINE_RESULT outcome=ok|noop|error detail=…` before exit.
