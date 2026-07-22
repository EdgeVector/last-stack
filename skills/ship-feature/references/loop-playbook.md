# ship-feature — autonomous loop & recovery playbook

Read this when you reach Phase 5/6 of SKILL.md. It's the detailed "how to drive
the board unattended and not get stuck" guide, tuned to this workspace
(`~/code/edgevector/`). Lean on the `kanban` skill for the actual board ops; this
file is the judgment layer on top.

## The heartbeat loop

Kanban agents run in their own sessions — finishing one does **not** auto-wake
this session. So poll with `ScheduleWakeup` (the Monitor tool's streaming
notifications do NOT reach this user — do not use it).

- Default cadence: **~1200s** (20 min). Long enough that work progresses between
  checks; the user can always interrupt sooner. Don't poll every minute —
  agents take many minutes per task and tight polling just burns context.
- If you're waiting on something external and slower (a deploy, CI), match the
  delay to how fast that state actually changes.
- **Stop scheduling the moment the feature validates** — that's how the loop
  ends. A lingering wakeup after done is noise.

Each wake, in order:
1. Read the milestone first (`fkanban milestone detail <slug> --json`), then
   inspect only its linked cards and PRs. The milestone is supervisory and is
   never a pickup card.
2. Triage each in-progress/awaiting task: merged? progressing? wedged? (taxonomy
   below).
3. Recover wedges. Unblock the next dependency tier. Create fix-forward tasks for
   anything that regressed.
4. If all implementation cards merged → run Phase 7 validation, record proof
   on the linked terminal card, and run `fkanban milestone reconcile <slug>`.
5. Re-schedule unless done.

## Reading task state correctly (don't false-positive a wedge)

- **`awaiting_review` is usually NOT stuck.** On a plan-mode task it's parked for
  human plan approval (surface it, don't trash it). On a normal task it's a
  transient hook pause — diagnose real stuck-ness from `session.pid` liveness +
  `lastOutputAt` staleness, not the state string.
- **Trash column = done** (PR merged). It's the normal terminal state, not a
  kill. Verify done-ness by the merged PR, not by the column.
- **Detect a live agent by its cwd**, not argv: a working agent's PID has the
  worktree as its cwd (`lsof`). argv-grep / a missing `sessions.json` key give
  false "no agent" readings — scan cwd before concluding anything's dead.
- Before starting/restarting, **read the full task prompt** — some carry a
  ⛔ DO NOT START header (e.g. parked plan-mode migrations). Never auto-start
  those.

## Wedge taxonomy & recovery (all → trash + recreate, no server restart)

The kanban server leaks memory and OOM-restarts ~every 43h; boards survive on
disk and agents re-spawn — so re-check liveness before "salvaging" anything.
Recovery for a genuine wedge is almost always **trash the task + recreate it as a
fresh task id** (verified to clear without a server restart). A server restart
kills every live agent in every workspace — surface that, never do it unattended.

Common wedges:
- **API-400 thinking-block wedge** — last assistant entry is `400 ... thinking
  blocks cannot be modified`; pid alive but idle, unrecoverable in place. Read
  the LAST assistant message to distinguish this from a legitimately done task,
  then trash + recreate.
- **529 Overloaded wedge** — process alive but idle, transcript stale 40+ min,
  last entry is the 529. Recover with a RESUME prompt + kill pid + `task start`.
- **Background-notification wedge** — agent ended a turn "waiting for a bg task
  notification" that never fires; idle, no PR. Diagnose: bg `.output` mtime older
  than transcript + no heavy procs. Trash + recreate.
- **Killed/dead-pid wedge** — stale `lastOutputAt` + dead pid (`exitCode:143`/
  `pid:null`, or `state:running` with a dead pid after a server restart).
  `task start`/`stopTaskSession` are no-ops here; `task trash` clears it.
- **Expired keychain auth hang** — agent 401-hangs at startup reading OAuth from
  the macOS keychain (diverged from the creds file). Do NOT restart/spawn — the
  **user** must run `/login`. Surface this one.

Always check for an **auto-created fix-forward task**: a DIRTY fold PR auto-spawns
one. Don't double-fix — if you already fixed the PR, trash the redundant task.

## Concurrency & resource discipline

- **fold: no fixed <=2 build/test cap.** The stale `cargo test --all-targets`
  deadlock rule was lifted after the split/nextest harness and worktree
  concurrency proof. Scope task tests to the touched crate where possible, but
  do not throttle the whole fold fleet solely because two agents are already
  testing.
- Watch fold disk/load pressure before launching many Rust builds. Modern
  kanban worktrees should use their own `target/` plus shared sccache; older
  kanban/gstack worktrees may still symlink to `~/code/edgevector/fold/target`.
  If disk pressure appears, a `cargo clean` needs quiescing agents first —
  surface it, don't do it unattended.
- The kanban server **auto-pulls the oldest backlog task** when an in-progress
  slot frees. Trashing a fold task can silently start another — account for it.
- Orphaned legacy `folddb_server` processes (deleted worktree, ppid=1) and
  `kanban hooks ingest` procs leak and are safe to sweep — but **never** the
  primary LastDB brain.

## Merge mechanics

- Most EdgeVector repos are merge-queue: `gh pr merge <N> -R <owner>/<repo> --auto` with **no**
  strategy flag. A merge-queue PR shows `autoMergeRequest: null` — that's normal,
  not "auto-merge dropped"; check `isInMergeQueue` via GraphQL.
- **`fold` is now a merge-queue repo too (since 2026-06-17, ruleset
  `default-branch-merge-queue`):** `gh pr merge <N> -R <owner>/<repo> --auto` with **no** strategy flag
  (the queue sets the method to squash; `--squash` errors). Main is protected by
  the org ruleset's `ci-required` check + the queue. A `BLOCKED`/`AWAITING_CHECKS`
  state is the normal in-queue resting state.
- Use `secrets.GH_PAT` for workflow auth, never `PRIVATE_DEPS_TOKEN`.

## Validation method by project type (Phase 7)

The stop condition is *observing the feature work in the running app*. Pick the
exercise path you captured in Phase 1:

- **Rust service / lambda / node:** build the merged code, run it (ephemeral
  node — never the primary LastDB brain), hit the real endpoint/command, assert the
  observable result. The `app-identity-dogfood` skill is a worked example of
  spinning an ephemeral LastDB dev node (`folddb-dev` command) and verifying via `/v1/snapshot`.
- **CLI:** run the command on a real input, check stdout/exit.
- **Web/UI:** use the `browse` / `verify` skills to drive the page and observe.
- **Library:** exercise the public API in a tiny throwaway harness, not just unit
  tests.

Prefer the **`verify`** skill (run app, observe behavior, confirm intent) or
**`run`** skill (launch/drive the app) over hand-rolling. Tests passing is an
intermediate event; the app doing the thing is the gate.

## Hierarchical driver ownership

- `ship-feature` records the approved outcome request on its Brain North Star
  and orchestrates targeted routine passes; it does not write milestones/cards.
- `last-stack-north-star-driver` converts one North Star outcome request into
  one milestone scaffold. It never creates or moves cards.
- `last-stack-milestone-driver` creates/links the milestone's terminal proof and
  bounded PR cards, one generated card per pass. It never implements them.
- Pickup/kanban-agent executes cards. Proof workers record terminal evidence.
- One North Star may have many milestones over time. Default to one milestone
  for one independently provable approved outcome.
- Completion comes only from the CLI's proof-gated milestone transition after
  every implementation child is terminal and the linked validation card stores
  terminal machine-readable PASS evidence; never from PR count or a forced or
  evidence-free complete state.

## When to break silence (contract #3)

Only ping the user mid-loop for:
- An expired-keychain auth hang (only `/login` fixes it).
- The same task failing validation ~3× with no path forward.
- A genuinely unforeseeable decision (a fork that only appeared once a
  dependency's real runtime behavior was observed) — and even then, batch it as
  one `AskUserQuestion` with ELI5 + recommendation, same as Phase 3.
- Anything requiring a kanban **server restart** or a disk `cargo clean` (both
  affect other agents — never unattended).

Otherwise: stay quiet, keep driving, report at the end.
