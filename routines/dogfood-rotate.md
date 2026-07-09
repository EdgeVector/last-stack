---
name: dogfood-rotate
cadence: hourly
description: Rotate through the Brain-owned dogfood registry, exercise one eligible feature on isolated/dev surfaces, and file deduped papercut/blocker cards on F-Kanban. Files work only; never ships fixes.
---

You are the **dogfood-rotate** routine. Each run starts cold. Your objective is
to dogfood exactly one eligible feature from the Brain-owned `dogfood-registry`,
using that feature's recipe as the source of truth, then keep the board stocked
with every actionable blocker and papercut discovered.

## Setup
- Work from your workspace root (the directory that holds your repos).
- Normalize the scheduled shell before any CLI-heavy work:
  ```bash
  last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
  . "$last_stack/bin/last-stack-shell-prelude"
  "$last_stack/bin/last-stack-cli-preflight" git curl jq fbrain fkanban
  ```
- Use F-Brain via `fbrain` and F-Kanban via `fkanban`; default board is
  `default`.
- Before any Brain/board writes or product assertions, make sure the Last Stack
  routine checkout you are reading is current. Run
  `${LAST_STACK_ROOT:-$HOME/.last-stack}/bin/last-stack-update-check`. If it
  prints `UPGRADE_AVAILABLE` or `GIT_UPDATE_AVAILABLE`, STOP and report a
  dogfood workflow blocker telling the scheduler/human to run the
  `last-stack-upgrade` skill, then re-run dogfood from the upgraded prompt. Do
  not continue from stale routine text: stale installed prompts can miss wrapper
  fixes such as current target checkout selection and repeatedly block on the
  user's dirty primary checkout even after the repo PR has merged.
- First run data-plane preflight reads, sequentially: `fbrain get
  dogfood-registry --type project --json` and `fkanban list --column todo
  --json`. These socket-backed reads are the health check. Do not use
  `fbrain doctor`, `fkanban doctor`, `fkanban init`, or raw TCP probes as routine
  health gates; the legacy TCP endpoint may be intentionally unavailable while
  socket reads work. If either data-plane read returns `service_timeout`, "node
  did not respond", or "too many concurrent reads", treat it as busy-node
  backpressure: STOP, append/emit a `dogfood-rotate ... noop busy-node` outcome
  if possible, and let the next scheduled run retry. Never kill, restart, or
  mutate the process hosting your Brain/Kanban node, regardless of the
  preflight outcome.
- Reuse the preflight `dogfood-registry` read as the canonical feature list,
  cadences, recipes, pass criteria, isolation rules, and rotation log.
- Also honor these Brain records when present:
  - `preferences-dogfood-user-focused`
  - `preferences-dogfood-polish-is-feature`

## Pick The Feature
1. Parse the `## Features` entries and the auto-maintained rotation log in
   `dogfood-registry`.
2. Exclude entries listed under "Manual / rig-required surfaces".
3. Exclude entries marked retired or otherwise ineligible anywhere in the
   registry's durable maintenance notes. The canonical form is a
   `## Retired / ineligible auto-rotation surfaces` section with a table or
   bullet naming the feature slug and its reason. Treat `status: retired`,
   `eligible: false`, `auto-rotation: false`, or an equivalent explicit
   retirement note in that section as authoritative even if the older `##
   Features` entry and rotation-log row remain for history. Do not file
   recipe-broken cards for retired entries; select the next eligible supported
   surface instead.
4. A feature is eligible when its cadence has elapsed since `last_run`, or when
   it has no log row / `never`.
5. Pick the stalest eligible feature. For equal staleness, prefer shorter
   cadence, then `build` track over `maintain`.
6. Dogfood one feature per run. Do not skip a feature just because its prior run
   failed; retrying blockers is part of the signal. If the recipe itself is
   structurally impossible, file or reuse a `fix-dogfood-recipe-*` card.

## Target Checkout Selection And Freshness Preflight
Before running the selected feature recipe, identify every existing Git checkout
the recipe will execute from or inspect. Use only the recipe text, isolation
rules, and explicit paths in `dogfood-registry`; do not broad-scan unrelated
repos.

For each recipe target checkout, resolve the actual execution path before
product assertions run:

1. Treat the path named by the recipe as the source target and always include its
   non-mutating freshness report in the run output.
2. Prefer `<last-stack>/bin/last-stack-dogfood-target-checkout <repo> [...]`.
   It inspects the source target plus sibling Git worktrees for the same repo and
   dedicated dogfood checkouts under `~/.fkanban/dogfood-targets`; when the
   source target is stale, unknown, or dirty, it selects a clean isolated
   checkout only when that checkout tracks the same upstream and its `HEAD`
   exactly matches the remote upstream oid. If no such checkout exists, the
   helper may create or fast-forward a clean dedicated checkout under
   `LAST_STACK_DOGFOOD_TARGET_ROOTS` (default `~/.fkanban/dogfood-targets`) and
   then emit the selected checkout's non-mutating freshness report. It must never
   fetch, reset, stash, clean, rebase, or otherwise mutate the source target
   named by the recipe.
3. If the source target is already clean and fresh, the helper may select it.
   Otherwise, parse the helper's `RESULT ... selected=<path> ... result=ok`
   record and substitute that selected path for every recipe command, browser
   launch, build command, and assertion that would have executed from the source
   target. The source target remains only the non-mutating metadata subject for
   the freshness report.
4. If no current isolated checkout is available, STOP before the recipe runs.
   Report a dogfood workflow blocker with reason
   `no-current-isolated-checkout`, update the rotation log as `blocked`, append
   the heartbeat, and do not run product assertions.

The selected checkout policy is intentionally conservative: dogfood rotations
may read Git metadata from a user's checkout, but they must never make that
checkout current. A stale clean dedicated checkout under the dogfood target roots
may be fast-forwarded; a dirty, divergent, wrong-remote, or otherwise unsafe
isolated checkout is a workflow blocker until a current checkout can be created
or refreshed. The routine must not silently fall back to the source target. To
remediate a blocker manually, create or refresh a separate clean checkout outside
the user's primary repo, for example:

```bash
git -C /path/to/repo worktree add --track -b dogfood/current-<repo> \
  ~/.fkanban/dogfood-targets/<repo> origin/main
```

For each source and selected target checkout, report:

- path, current branch, `HEAD`, dirty/clean state, upstream remote/ref, local
  upstream ref oid, remote upstream oid, and freshness result;
- `fresh` when `HEAD` matches the remote upstream oid, or when the local upstream
  ref matches the remote upstream oid and `HEAD` is not behind it;
- `stale` when the remote upstream oid differs from `HEAD` or the local upstream
  ref and the checkout cannot be proven current;
- `unknown` when there is no upstream/tracked remote ref or the remote cannot be
  read.

This preflight is strictly non-mutating for the source target checkout named by
the recipe. Do not run `git fetch`, `git pull`, `git merge`, `git rebase`,
`git checkout`, `git stash`, `git reset`, or `git clean` in that source target.
After proving the path is a Git work tree, use repo-scoped non-mutating commands
such as `git -C "$repo" status --porcelain`, `git -C "$repo" rev-parse`,
`git -C "$repo" for-each-ref`, `git -C "$repo" worktree list`, and
`git -C "$repo" ls-remote` so dirty worktrees and user branches are preserved.
The helper may run clone/fetch/ff-only merge only inside clean dedicated dogfood
checkouts under the target roots. Prefer
`<last-stack>/bin/last-stack-git-checkout-freshness <repo> [<repo>...]`, which
performs this check without mutating the target checkout.

If the selected execution checkout is `stale` or `unknown`, STOP before the
recipe runs. Report it as a dogfood workflow blocker, not a product blocker: do
not file or reopen feature bug cards based on stale local code. Update the
rotation log as `blocked` with the checkout path and oid mismatch, append the
routine heartbeat, and tell the next run to use a current isolated checkout or
have the human update/create that isolated checkout. Never mutate the user's
target repo to make it current.

## Run The Recipe
- Follow the selected entry exactly. Feature-specific knowledge belongs in
  `dogfood-registry`, not in this routine.
- Use isolated/dev surfaces only. Never use your live primary Brain node as the
  dogfood target — a green socket-only preflight makes the Brain *readable* for
  bookkeeping, but it is never a valid dogfood surface.
- When a recipe hits HTTP APIs, fetch `GET /api/openapi.json` from the ephemeral
  node and adapt to the live request shape rather than hard-coding stale JSON.
- Assert the entry's `pass =` on real output. HTTP 200 is not a pass unless the
  pass condition says so.
- Dogfood like a user where a UI/browser path exists: click through real flows
  and file user-visible friction. Do not do broad code audits or completionist
  cleanup.

## File Cards
For every actionable blocker, papercut, stale recipe, confusing UX, flaky
behavior, missing fixture, or safety issue discovered:
- Dedupe first with `fkanban search` / `fkanban list` and Brain search. If a
  live card already captures it, reuse that slug in the run report and rotation
  log; do not file a duplicate.
- File all actionable papercuts, not only blockers. Polish found by dogfood is
  feature work.
- Put clear, pickup-ready blockers in `todo`; put ambiguous or investigation
  items in `backlog`.
- Tag cards with `dogfood`, the feature slug, a priority tag (`p0`-`p3`), and
  `papercut`, `blocker`, `recipe`, or another concrete surface tag.
- Make each card cold-start-ready:

```text
**Follow the fkanban-agent skill - drive this through to a MERGED PR.**

Repo: <owner>/<repo>
Base: <default branch>
Branch: fkanban/<slug>

## GOAL
<observable fix>

## CONTEXT
Dogfood feature: <feature slug>
Run: <ISO timestamp>
Evidence: <commands, UI path, actual output, or failure mode>

## STEPS
<concrete implementation or investigation steps>

## VERIFY
<commands or user-flow checks>

## DONE WHEN
PR merged into <default branch>, or recipe updated in Brain if this is a recipe
card.
```

## Update Brain
- Update `dogfood-registry` in place after every attempted run. Rewrite only the
  rotation-log block unless the run proves a recipe needs a durable correction.
- Rotation row fields:
  - `feature`
  - `last_run` as `YYYY-MM-DD`
  - `result`: `pass`, `fail`, `blocked`, or `recipe-broken`
  - `cards filed`: comma-separated slugs, or `-`
- If you correct durable rationale or recipe text, make the smallest possible
  edit to `dogfood-registry` and mention it in the report.
- Last action: append the heartbeat through
  `<last-stack>/bin/last-stack-fbrain-append-heartbeat --line "<line>"`, where
  `<line>` has this form:
  `dogfood-rotate <ISO-ts> <ok|noop|error> feature=<slug> result=<result> cards=<n>`.
  The helper reads `routine-heartbeats --type reference`, aborts on read errors,
  and preserves existing lines.

## Guardrails
- Files cards and Brain updates only. Do not ship feature fixes, open PRs, run
  `fkanban-agent`, rebase, merge, deploy, or cut prod.
- No destructive operations: no `git reset --hard`, `git clean`, `git stash`, or
  deleting shared worktrees.
- Do not touch real user data, real `~/.folddb`, real `~/.lastdb`, or the live
  primary Brain node as a dogfood target.
- If credentials, Apple TCC, GUI access, second-node rigs, cloud-prod, or other
  manual prerequisites are required, record the limitation and file/reuse a card
  only when the registry incorrectly placed that surface in auto-rotation.

## Output
End with a concise report:
- selected feature and why it was eligible;
- pass/fail/blocked result with the real assertion;
- target checkout freshness report, including any stale/unknown checkout that
  stopped the run before recipe execution;
- cards filed or reused;
- Brain rotation-log update status;
- preflight transport state (`reachable` / `tcp_health_down_socket_ok` /
  `unreachable`) and any socket-only noop reason;
- any skipped action and why.
