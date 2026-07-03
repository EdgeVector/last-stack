---
name: fkanban-agent
version: 0.2.0
description: |
  Drive a single fkanban card all the way to a MERGED PR — a card only
  reaches `done` when its code is actually in the repo. Two entry modes:
  WORK (you were pointed at one card slug — implement it, open a PR, then
  DRIVE THE PR TO MERGED and move the card to `done`; only fall back to
  `review` if you hit a genuine human-only blocker) and RECONCILE (a sweep
  routine woke you — go over every in-flight card, push stuck PRs to merge,
  and move merged ones to `done`).
  Triggered when the user or a spawn/wake prompt says "follow the
  fkanban-agent skill", names an fkanban card to work, or says "reconcile
  the fkanban board".
---

# fkanban — agent handbook

fkanban is a kanban over LastDB (CLI + MCP, `bun run src/cli.ts` in the fkanban
repo, board on your LastDB node). It does **not** spawn agents. This skill makes
the agent **own a card through merge**: it implements the card, opens the PR, and
then drives that PR to MERGED before exiting — it does not hand a green-but-
unmerged PR off and walk away. A card reaches `done` only when its PR is verified
merged.

> ⚠️ **ALL NON-PUBLIC repos → the LOCAL FORGE, not GitHub.** Forge-hot:
> `EdgeVector/fold` (since 2026-07-02) plus `exemem-infra`, `exemem-workspace`,
> `lastgit` (since 2026-07-03, Tom's decision after the GitHub Actions billing
> halt). Every `gh -R EdgeVector/<forge-hot-repo> ...` command in this handbook
> must instead be its Forgejo-API equivalent against `http://localhost:3300` —
> their GitHub copies are read-only 24h push-mirrors; `gh` there reads stale
> state and cannot merge. Full command map + auth + the current venue map:
> `fbrain get sop-forge-pr-workflow`. Essentials
> (`TOKEN=$(security find-generic-password -s forgejo-token -w)`,
> `REPO=http://localhost:3300/api/v1/repos/EdgeVector/<repo>`, all calls
> `-H "Authorization: token $TOKEN"`):
> `git push origin <branch>` works as-is (origin already points at the forge);
> create PR = `POST $REPO/pulls` with `{"title","body","head","base":"main"}`;
> arm auto-merge = `POST $REPO/pulls/<n>/merge` with
> `{"Do":"merge","merge_when_checks_succeed":true,"delete_branch_after_merge":true}`
> (native Forgejo auto-merge; NO merge queue; fold's branch protection requires
> the `ci-required` Forgejo Actions check green, admins included — never bypass
> it; exemem-infra/exemem-workspace/lastgit have NO forge gate yet, so arming
> auto-merge merges IMMEDIATELY — be sure the work is done before arming);
> view = `GET $REPO/pulls/<n>` (merged=`.merged`, mergeable=`.mergeable`,
> draft=`.draft`); CI = `GET $REPO/commits/<head-sha>/status`; update a BEHIND
> branch = `POST $REPO/pulls/<n>/update`; comment =
> `POST $REPO/issues/<n>/comments`; close = `PATCH $REPO/pulls/<n>` with
> `{"state":"closed"}`. No rerun-failed API — push an empty commit to re-trigger
> a flaky run. The forge has no checks-watch equivalent of the GitHub CLI: hold
> your turn by polling the head-commit status between forward actions instead.
> All PUBLIC repos (fbrain, fkanban, schema-infra, last-stack, websites, …) keep
> the normal GitHub `gh` flow; Keepside_Desktop is GitHub-primary and hands-off.

> **Drive to merge, but never idle-park or sleep-loop.** The rule that prevents
> wedged/runaway agents is **no `sleep`-to-wait, ever**: you wait for CI/the
> merge process only with a *sleepless* foreground watcher (the `/wait-merge`
> skill, or `gh -R <repo> pr checks <n> --watch`), which returns when state actually
> changes and is bounded by GitHub's check timeout. While waiting you take
> *action* on state changes (re-arm dropped auto-merge, update-branch a BEHIND
> PR, rebase a DIRTY one) rather than spinning. You exit when the PR is **MERGED**
> (move card → `done`) or when you hit a **genuine human-only blocker** (move
> card → `review` with a `BLOCKED:`/`STALLED:` note). You do NOT exit just
> because the PR is open and queued — that fire-and-forget hand-off is exactly
> what lets PRs pile up stranded.
>
> **"Spawn a watcher and come to rest" is NOT "drive to merge."** Do not start a
> background CI-watcher process and then end your turn expecting to be re-woken
> when it finishes — that re-wake is not reliable, and it leaves the PR with
> nobody driving it (it strands exactly as before, one step later). Hold THIS
> turn open with a *foreground* sleepless `--watch` until the PR reaches a
> terminal state. Holding one turn on a foreground watcher is the allowed,
> bounded thing; resting while a detached watcher runs is not.

## Columns

`backlog → todo → doing → review → done`

| Column | Meaning |
|---|---|
| `backlog` / `todo` | not yet picked up |
| `doing` | an agent is implementing, OR is driving its open PR to merge |
| `review` | parked for a human — hit a genuine blocker (`BLOCKED:`/`STALLED:` note explains why) |
| `done` | PR is **merged** AND the card's outcome was validated (terminal) |

### Outcome validation — at the CARD level, not in PR bodies

**PR-body `## Proof` blocks are NOT required** (Tom removed the requirement and
its `proof-block` CI gate 2026-07-03 — the check failed on ~30% of fleet PRs and
silently stalled auto-merge into rerun churn). Do not write them, and never treat
a missing one as a blocker.

Validation lives on the **card** instead: run the card's `VERIFY:` line before
closing, and honor its `## END STATE`. For user-visible/stateful cards (auth,
passwords, settings, data writes, sync, UI), that still means a real-app
acceptance check: run the real binary/node on a **throwaway** data dir
(`mktemp -d`, `FOLDDB_DISABLE_KEYCHAIN=1`) — NEVER `~/.folddb` or the primary
brain/keyring; **cross a process boundary** (restart / re-open) between the write
and the read; include a **negative case**. Anchor it to the user story, not the
diff ("a user can set a password and later unlock with it") — see the SOP
`sop-autonomous-acceptance-gate` (fbrain). A card whose merged PR fails its
VERIFY/END STATE goes to `review` with a `PROOF:` note — not `done`. This is what
stops "password sets but the app won't unlock with it" (incident 2026-06-30) from
reaching a user.

Note: `review` is an **exception** state, not the normal post-PR resting place.
The happy path is `doing` → (drive PR to merge) → `done`. A card only lands in
`review` when an agent genuinely cannot get the PR merged without a human
(ambiguous spec, product-judgment conflict, a human-only required gate).

Use the CLI for all board writes. With the global shim on PATH these run from
anywhere:

```bash
fkanban show <slug> --json        # read a card
fkanban move <slug> doing         # column transition
fkanban list --json               # whole board
```

`show` and `move` do not take a per-command board flag. If you need the default
board, use the forms above; only add a board flag to commands whose help lists
one.

(No shim on PATH — `command not found: fkanban`? Fall back to
`bun run src/cli.ts <cmd>` from the fkanban repo directory; equivalent.)

Codex CLI diagnostics sometimes emit
`WARNING: proceeding, even though we could not update PATH: Operation not permitted (os error 1)`
from sandboxed shells, including `codex app-server --help` and
`codex debug --help`. Treat that warning as benign when the command exits 0 and
prints the requested help/output. Treat a nonzero exit, missing expected output,
or an unrelated error as actionable; do not spend time debugging the PATH warning
alone.

## The card brief (read it as your spec)

The card body is the specification. By convention it carries a header that
tells you **where** to work (there is no `repo` field on the schema):

```
Repo: owner/name               # owner/name, or an absolute local path
Base: main                     # base branch to target
Branch: fkanban/<slug>         # optional; defaults to fkanban/<slug>
PR: <url>                      # written by WORK mode once the PR is open

GOAL: ...
CONTEXT: ...
STEPS: ...
VERIFY: <exact commands that must pass>
DONE WHEN: PR merged into <base>
OUT OF SCOPE: ...
```

If `Repo:`/`Base:` are missing or ambiguous, **do not guess** — move the card
to `review`, append a one-line note explaining what's missing, and exit.

---

## Which mode am I in?

- You were given (or your cwd implies) **one specific card** → **WORK MODE**.
- You were woken to "reconcile" / sweep the board → **RECONCILE MODE**.

---

## WORK MODE — implement one card, open the PR, drive it to merged

1. **Claim it.** `bun run src/cli.ts show <slug> --json`. If it's already in
   `review`/`done`, stop — someone landed it. Otherwise move it to `doing`.
2. **Resolve the target repo, then set up an isolated worktree** (never edit a
   shared checkout in place, and never `stash`/`reset` — sibling agents may
   share these repos). The `Repo:` header must resolve to an explicit local Git
   checkout path before any `git` or `gh` command runs. If it is missing,
   ambiguous, points at the aggregate workspace (for example
   `/Users/tomtang/code/edgevector`), or cannot be resolved to a checkout, move
   the card to `review` with a one-line `BLOCKED:` note instead of probing the
   current directory or workspace root. Treat checkout resolution as a hard
   preflight gate and run Git from the resolved checkout, not from the workspace
   container:
   ```bash
   target_repo="<resolved-target-repo-root>"
   case "$target_repo" in ""|/Users/tomtang/code/edgevector) exit 2 ;; esac
   git -C "$target_repo" rev-parse --show-toplevel
   cd "$target_repo"
   git fetch origin <base>
   git worktree add ~/.fkanban/worktrees/<slug> -b fkanban/<slug> origin/<base>
   cd ~/.fkanban/worktrees/<slug>
   ```
3. **Do the work** described in the brief. Match the repo's contributor docs and
   existing style. Honor OUT OF SCOPE — keep the PR atomic.
4. **Verify locally** — run the brief's exact VERIFY commands. Green tests are
   not sufficient if the brief says to run the app — do that too.
5. **Open the PR + arm auto-merge** (adjust the merge command to your repo — see
   "Merge strategy"):
   ```bash
   git commit -am "<msg>"
   git push -u origin HEAD
   gh -R <repo> pr create --fill --base <base>
   gh -R <repo> pr merge <n> --auto            # if the repo allows auto-merge
   ```
6. **Drive it to MERGED — do not hand off a green-but-unmerged PR.** Arming
   auto-merge is necessary but not always sufficient: a PR can fall out of
   mergeable state (go BEHIND, go DIRTY, or have its auto-merge dropped) and then
   sit forever. You own getting it the rest of the way. The robust mechanism is
   the **`/wait-merge` skill** — invoke it on your PR number; it interprets PR
   *state* (not a watcher's exit code), tolerates merge churn, re-asserts
   auto-merge when a clean PR stalls, and only declares failure on a genuinely
   terminal state. If you drive by hand instead, loop with a **sleepless** watcher
   (`gh -R <repo> pr checks <n> --watch`, NEVER `sleep`) and on each state change act:
   - **MERGED** (`state=MERGED`) → `move <slug> done`. **You are done — exit.**
   - **auto-merge dropped** (`autoMergeRequest` null) while CLEAN/mergeable →
     re-arm: `gh -R <repo> pr merge <n> --auto`. (A merge queue can silently drop it; this
     is a common strand — re-arm and keep watching.)
   - **BEHIND** (and otherwise clean/green) → `gh -R <repo> pr update-branch <n>`
     (lightweight, no worktree). Don't assume the queue self-updates a BEHIND
     branch. Then keep watching; auto-merge fires once it re-greens.
   - **DIRTY / CONFLICTING** → rebase in your worktree (`git fetch origin
     <base>` → rebase onto `origin/<base>` → resolve → re-run VERIFY →
     force-push with lease). If the conflict needs product judgment you can't
     make, stop and treat it as a blocker (below).
   - **CI red** (a real failing required check) → read `gh run view
     --log-failed`, fix in the worktree, re-run VERIFY, push. Keep watching.
   - **BLOCKED / AWAITING_CHECKS** while in a merge queue → this is the *normal*
     in-queue resting state, not a strand. Keep watching; don't thrash.
   Keep going until MERGED or a genuine blocker. A merge queue can take a while
   (CI + a min-wait window); a single bounded `--watch` that returns on merge is
   fine — that is doing work, not idling. **Do NOT** push your fix, spawn a
   detached watcher, and end the turn "to be re-woken" — that re-wake isn't
   reliable and the PR strands. Stay on the foreground watcher in THIS turn
   through to the terminal state.

If you hit a **genuine human-only blocker** (ambiguous spec, a conflict needing
product judgment, a required gate only a human can clear, or a dependency on
unmerged work): leave the branch clean, move the card to `review`, append a
short `BLOCKED: <why>` note to the body, and exit. Don't spin, and don't
force-merge around a failing required gate.

---

## RECONCILE MODE — sweep in-flight cards, advance or fix, then exit

Run once per wake, then exit. Sweep **every card not already in `done`** — not
just `doing`/`review`. (A card can be merged while still sitting in `todo` if a
human or another flow did the work — a merged PR whose card never advanced.)
**But widening the sweep is ONLY to catch cards whose PR already merged — it is
NOT a licence to resolve un-started cards. The DEFAULT action for any swept card
is to LEAVE IT ALONE; you only act when there is concrete PR/branch evidence to
act on (see step 2). When in doubt, do nothing.** Skip a card only if it has no
`Repo:` header (it isn't meant for this flow). For each candidate:

1. **Find its PR.** Prefer an explicit `PR:` line / PR URL in the body — work
   landed outside WORK mode won't use the `fkanban/<slug>` branch convention.
   Fall back to the head-branch lookup only when no PR URL is present:
   ```bash
   # explicit URL in body:
   gh -R <repo> pr view <n> --json number,state,mergedAt,mergeStateStatus,reviewDecision,statusCheckRollup
   # else by convention branch:
   gh -R <repo> pr list --head fkanban/<slug> --state all \
     --json number,state,mergedAt,mergeStateStatus,reviewDecision,statusCheckRollup
   ```
   Do not request `isInMergeQueue` through `gh pr view/list --json`; use GraphQL
   with `gh api graphql -f query='{repository(owner:"<owner>",name:"<repo>"){pullRequest(number:<n>){isInMergeQueue autoMergeRequest{enabledAt}}}}'`.
2. **Decide from PR state:**
   - **Merged** (`state=MERGED` / `mergedAt` set) → `move <slug> done`. Done.
     A card reaches `done` ONLY this way — a verified MERGED PR. If you cannot
     point at a merged PR for the card, it does **not** go to `done`, no matter
     how the card reads.
   - **No PR found AND no `fkanban/<slug>` branch with commits** → the card is
     **un-started** (a fresh `todo`/`backlog` item nobody has picked up yet).
     **LEAVE IT EXACTLY WHERE IT IS — do NOT move it, and NEVER move it to
     `done`.** The reconciler advances *in-flight* work (cards that already
     have a PR, or a branch with commits); it does not start, complete, or
     retire fresh cards. Marking an un-started card `done` silently buries real
     work.
   - **No PR found** but a `fkanban/<slug>` branch with commits exists and the
     card is in `doing` → a worker opened a branch but didn't finish landing
     (or died mid-work). Finish WORK MODE step 5 for it. Don't thrash.
   - **CI red** (a real failing required check in `statusCheckRollup`, not just
     BEHIND) → enter the worktree, read the failing job logs
     (`gh run view --log-failed`), fix, re-run VERIFY, push. HEAVY (see budget).
   - **Auto-merge dropped** (`autoMergeRequest` is null) while the PR is CLEAN /
     mergeable and not merged → **re-arm it: `gh -R <repo> pr merge <n> --auto`.** A merge
     queue can silently drop the auto-merge request when it ejects a PR; once
     dropped nothing re-fires it, so a green-and-ready PR sits forever. Do NOT
     require auto-merge to be ON to consider a PR stuck — a CLEAN PR with
     auto-merge OFF is itself a strand. CHEAP advance (uncapped).
   - **Behind base, otherwise clean + green** (`mergeStateStatus` = BEHIND, NOT
     DIRTY, no red required check) → **`gh -R <repo> pr update-branch <n>`** (lightweight,
     NO worktree/force-push). Don't assume a merge queue self-updates a BEHIND
     branch. Guard: if a `~/.fkanban/worktrees/<slug>` exists, only
     update-branch when it is clean AND fully pushed
     (`git -C <wt> status --porcelain` empty AND
     `git -C <wt> rev-list --count origin/<branch>..HEAD` == 0); if it has
     uncommitted/unpushed work a sibling is mid-edit — SKIP. **Serialization:**
     because one merge re-BEHINDs the others, update-branch the OLDEST few
     clean-green-BEHIND carded PRs each wake (not just one), and ensure each
     still has auto-merge armed. They re-green and advance. CHEAP advance
     (uncapped).
   - **Conflicts / dirty** (`mergeStateStatus` = DIRTY/CONFLICTING) → enter the
     worktree, `git fetch origin <base>`, rebase onto `origin/<base>`, resolve,
     re-verify, force-push with lease. HEAVY. If the conflict needs product
     judgment, don't guess — `gh -R <repo> pr comment` flagging it and leave it.
   - **Changes requested** (`reviewDecision=CHANGES_REQUESTED`) → read the
     review comments, address them, push, reply briefly.
   - **Clean + approved but not merging** → re-assert auto-merge
     (`gh -R <repo> pr merge <n> --auto`); if a required check is stuck, surface it, don't
     force-merge.
   - **Pending** (CI running, awaiting human review) → leave it; it'll be
     re-checked next wake.
3. **Give-up guard:** if a card has been in `review` with no forward progress
   for a long time (several days of wakes, or a hard human-only blocker), append
   `STALLED: <why>` to the body and leave it in `review` for a human — never
   silently loop forever and never auto-merge around a failing gate.

**Action budget per wake (cheap vs heavy).** Don't throttle the cheap advances —
that's what lets a burst of BEHIND PRs rot. Each wake:
- Do EVERY CHEAP advance (uncapped): move every merged card to `done`; re-arm
  auto-merge on every clean-but-unarmed/stuck PR (including ones whose auto-merge
  was *dropped*); `gh -R <repo> pr update-branch` the oldest few clean-green-BEHIND carded
  PRs (not just one).
- Do at most ONE HEAVY unit: a worktree CI-fix OR a conflict rebase. Pick the
  highest-value one, then exit.

Heavy fixes happen inside `~/.fkanban/worktrees/<slug>` on branch
`fkanban/<slug>` — reuse the existing worktree if present; create it (WORK MODE
step 2) if not. A `gh -R <repo> pr update-branch` needs NO worktree at all.

---

## Merge strategy (per repo)

Repositories differ in how they merge. Match your repo's policy:

- **Plain auto-merge:** `gh -R <repo> pr merge <n> --auto --squash` (or `--merge` /
  `--rebase` to match the repo's preferred method).
- **Merge-queue repos:** enable auto-merge with bare **`gh -R <repo> pr merge <n>
  --auto`** — do **not** pass a strategy flag, because the queue's ruleset sets
  the method (passing `--squash` errors `The merge strategy for main is set by
  the merge queue`). A `BLOCKED`/`AWAITING_CHECKS` state is the normal in-queue
  resting state, not a dropped auto-merge.
- **Auto-merge disabled:** some repos disallow `--auto` entirely (it errors
  "Auto merge is not allowed"). There, the flow is: push →
  `gh -R <repo> pr create` → `gh -R <repo> pr checks <n> --watch` (block
  sleeplessly until CI is green) → `gh -R <repo> pr merge <n> --squash` to land
  it manually.

Check the repo's contributor docs (`CONTRIBUTING.md` / `AGENTS.md` /
`CLAUDE.md`) for which applies.

## Guardrails

- **Dev, not prod.** If the work touches a prod-facing surface or the design is
  still in flight, do it on a dev/staging surface and leave the prod cutover for
  a human.
- **Never kill a LastDB node you didn't start**; don't `clean`/`reset`/`stash` a
  shared repo — use `git worktree add`.
- **Never probe the workspace root as a repo.** A container such as
  `/Users/tomtang/code/edgevector` may only hold child repos. Resolve the card's
  `Repo:` header to a concrete checkout, `cd` there (or use `git -C "$repo"`),
  and use `gh -R <owner>/<repo>` before all Git/GitHub operations. If the repo
  path is not explicit and resolvable, block the card in `review`.
- **Avoid zsh's read-only `status` parameter.** Shell snippets and one-liners
  may run under `zsh`; use names like `git_status`, `repo_status`, or `st` for
  temporary command output instead of assigning to `status`.
- **Avoid zsh/macOS-only shell traps.** Do not use Bash-only `mapfile` /
  `readarray` in snippets that may run under `zsh` or macOS Bash 3.2; use
  portable `while IFS= read -r ...` loops or Python for list processing. For
  Markdown/F-Brain/fkanban/PR bodies, always use a body file with a
  single-quoted heredoc delimiter such as `<<'EOF'` (or stdin), never an
  unquoted heredoc or shell-expanded string.
- **Never chain `sleep` to wait — but DO drive your PR to merge.** **WORK mode**
  owns its PR to merge and waits with a *sleepless* foreground watcher
  (`/wait-merge`, or `gh -R <repo> pr checks <n> --watch`, or `gh run watch <run-id>`) that
  returns on real state change — acting on each change (re-arm/update-branch/
  rebase) until MERGED or a genuine blocker. **RECONCILE mode** does one sweep
  of unit-work and exits; the next wake re-checks. What is forbidden in BOTH is
  `sleep N && <poll>` — a blocked sleep can cancel queued sibling tool calls. A
  sleepless `--watch` that blocks one turn until merge is fine and is the
  intended mechanism; an idle `sleep`-loop or a turn parked doing nothing is the
  wedge to avoid.
- Keep PRs atomic; honor OUT OF SCOPE; don't spawn sibling agents — if work
  splits, describe the split and let a human add cards.

## The watcher that re-enters this skill

The reconcile pass is meant to be driven by a **scheduled routine** that simply
runs RECONCILE MODE and exits on each fire — inline worktree → fix → push →
exit, NO spawned agents. A cadence of every 10–20 min is plenty (CI + human
review move on that scale).
