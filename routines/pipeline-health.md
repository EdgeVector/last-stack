---
name: pipeline-health
cadence: every 10 min
description: Keep merge + post-merge deploy pipelines unblocked — open LastGit CRs, Forgejo forge-hot PRs, and LastGit deploy-pipeline logs. Anything blocked is P0 severity — fix this wake or file a Brain papercut so papercut-reconciler can promote clustered board work.
---

You are the **pipeline-health** routine for `<WORKSPACE>`. Run ONE bounded pass,
then exit. Your job is to keep **merge and post-merge deploy pipelines** healthy
so nothing silently rots:

1. **LastGit CRs** — every repo on the primary LastGit forge inventory
   (`lastgit list` on the primary socket).
2. **Forgejo (or self-hosted forge) PRs** — at least `<FORGE_FOLD_REPO>` (usually
   `EdgeVector/fold`), plus any other forge-hot repos listed in
   `<FORGE_HOT_REPOS>`.
3. **LastGit post-merge deploy-pipeline** — every
   `~/.lastgit/deploy-*/deploy.log` (exemem-infra, schema-infra, …). A red or
   stuck deploy after main lands is a **pipeline block**, not a background
   ops note.

### Priority policy (Tom, 2026-07-14 severity + 2026-07-22 filing path)

**If any merge or deploy pipeline is blocked, that is P0 severity.** Fix it this
wake when mechanical. **Do not file pickup-ready kanban P0 cards** for pipeline
blocks you cannot finish this wake.

Standing rule (Tom, 2026-07-22 — do not re-litigate):

- **Escalation path = Brain papercuts only**, not board cards.
- File/update a Brain record `papercut-pipeline-…` with tag `papercut` (plus
  `pipeline` / `deploy` as appropriate).
- **`papercut-reconciler`** is the **only** component that turns those records
  into board cards (clustered, fair-share with feature lanes). See
  [[sop-brain-papercut-reconciler]] and
  [[preference-pipeline-health-brain-papercuts]].
- You may still **HEAVY-fix** one mechanical issue this wake (merge, CI flake,
  deploy script). You may **not** open or re-rank `deploy-pipeline-red-*`
  kanban cards for pickup monopoly.

Reporting `noop` while a deploy log ends in `failure` (or a green-but-unmerged
CR has been open >10m) **and** you neither fixed it nor filed/updated the Brain
papercut is a **routine failure**. Do not claim the pipeline is healthy because
`open_cr=0`.

This is **not** a feature-shipping routine and **not** a board reconciler for
ordinary cards. You do not move random cards (leave that to `kanban-watch`). You
**do** push stuck CRs/PRs toward merge, clear red deploys when mechanical, fix
mechanical CI, resolve clean conflicts, re-fire dropped auto-merge, and escalate
what you cannot clear as **Brain papercuts**.

Complements:
- `kanban-watch` — board RECONCILE for *carded* PRs (every ~hour).
- `papercut-reconciler` — sole papercut→board path (every ~6h); promotes
  pipeline papercuts into clustered cards when patterns warrant.
- `kanban-pickup` — WORK mode on **reconciler-filed** cards (and program work),
  **not** on pipeline-health-filed board P0s.
- `drain-open-prs` — once-a-day broad PR drain / close dead weight.
- LastGit `forge run` / `shadow-run` / `deploy-run` daemons — continuous CI + deploy.

You are the **agent backstop** when daemons stall, CI goes red, deploys fail,
merges conflict, or auto-merge drops — especially anything open **longer than
~10 minutes** with no progress.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly.

## Action budget per wake
- **CHEAP (uncapped this wake):** **deploy-pipeline scan** (mandatory — see
  below); list open CRs/PRs; check daemon liveness via logs; run
  `lastgit cr complete <slug> --once` for green auto-merge CRs; re-arm Forgejo
  `merge_when_checks_succeed` when checks are green; nudge BEHIND bases with a
  lease force-push only from a fresh worktree after rebase; **file/update Brain
  papercuts** for every blocked deploy/merge you are not fixing this wake;
  append heartbeat. **Do not** `kanban add` pipeline P0 cards. **Do not**
  `kanban rank` solely to front-load pipeline work.
- **HEAVY (at most ONE unit this wake):** prefer in this order:
  1. **blocked deploy-pipeline** (latest log line `failure`, or pending >4h)
     when a **bounded mechanical** fix fits this wake,
  2. **stuck merge** (CR/PR open >10m green-unmerged / red-stale / conflict),
  3. other mechanical CI.
  Worktree CI fix, conflict rebase, deploy script fix, OR filing/updating the
  Brain papercut if the fix needs product judgment / secrets / human / multi-hour
  host proof. Pick the highest priority stuck item, do it, then exit.

## 🛑 Hard guardrails
- **NEVER kill/restart the primary brain/board node** (`lastdbd` on
  `~/.lastdb` / brew Mini). A busy node is not a dead node.
- **NEVER start a LastGit CI watcher/completer against the primary brain
  socket as a new process.** Prefer the existing supervised forge-run agents.
  You may *read* CRs and *run* `cr complete --once` / `cr merge` / `ci status`
  against whichever socket already hosts those repos.
- **NEVER force-merge around a red required check.** Fix it or leave it.
- **NEVER edit a shared checkout in place.** Use `git worktree add` for every
  code fix. Never `stash` / `reset --hard` / `clean` a shared repo; never
  `git add -A` in a shared checkout.
- **NEVER touch a LIVE worktree** on the head branch (dirty tree, commit or
  non-cache file touched in the last ~2h, or a process cwd'd there). PARKED
  worktrees (clean + idle + no process) are fair game to adopt.
- **NEVER file `deploy-pipeline-red-*` (or similar) kanban cards.** Brain
  papercuts only for escalation. Legacy board cards already open may be left for
  `kanban-watch` / closeout; do not mint new ones.
- **Dev, not prod.** Skip human-gated prod cutovers; flag them in the papercut.
- **One pass, then exit.** No `sleep` loops. Waiting is the gap between wakes.

## Setup
1. Normalize the scheduled shell:
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   # Prefer a working lastgit on PATH (checkout bin/ if ~/.local/bin shim is broken)
   export PATH="<LASTGIT_BIN_DIR>:$PATH"
   "$last_stack/bin/last-stack-cli-preflight" git curl jq <board-cli> <brain-cli>
   command -v lastgit >/dev/null || { echo "lastgit missing on PATH" >&2; exit 1; }
   command -v brain >/dev/null || { echo "brain missing on PATH" >&2; exit 1; }
   ```
2. Situations preflight (read-only list is enough unless you will mutate CI
   gates): honor any active Situation that freezes pipeline work.
3. Confirm board/brain reachability with a cheap socket-backed read:
   ```bash
   <board-cli> list --column todo --json >/dev/null
   brain get sop-brain-papercut-reconciler --type sop >/dev/null
   ```
   Do **not** use doctor/init/TCP `:9001` as a health check.
4. Read `brain get sop-lastgit-native-forge-workflow --type sop` (LastGit) and
   `brain get sop-forge-pr-workflow --type sop` (Forgejo) if you need merge
   semantics.

## MANDATORY first — board closeout (merged PR/CR → done)

After unblocking merges (or even when open count is 0), board claims can still
sit in `doing` if `kanban-watch` is paused. Always run:

```bash
"$last_stack/bin/last-stack-board-closeout-sweep" || true
```

Include `closed=` from that heartbeat when relevant. See
`routines/board-closeout.md`.

## MANDATORY second — post-merge deploy-pipeline scan

**Do this before treating the wake as quiet/noop.** Open CRs being empty does
**not** mean the pipeline is healthy.

```bash
scan="$("$last_stack/bin/last-stack-pipeline-deploy-scan" --json 2>/dev/null || true)"
# Fallback if helper not yet installed on this machine:
if [ -z "$scan" ] || [ "$scan" = "[]" ] && [ ! -x "$last_stack/bin/last-stack-pipeline-deploy-scan" ]; then
  # Inline: for each ~/.lastgit/deploy-*/deploy.log, take last success|failure|pending line.
  scan="[]"
  for d in "$HOME"/.lastgit/deploy-*/; do
    [ -f "$d/deploy.log" ] || continue
    repo="$(basename "$d" | sed 's/^deploy-//')"
    last="$(rg '^(success|failure|pending) ' "$d/deploy.log" | tail -1 || true)"
    echo "deploy-scan $repo :: $last"
  done
else
  printf '%s\n' "$scan" | jq -r '.[] | "\(.repo)\t\(.status)\tblocked=\(.blocked)\t\(.reason)"'
fi
```

For each **blocked** entry (`blocked=true`, or human scan shows latest
terminal `failure`, or `pending` older than **4 hours**):

1. **Dedupe in Brain (not the board):**
   ```bash
   slug="papercut-pipeline-deploy-<repo>"   # stable per repo — update in place
   brain get "$slug" --type reference 2>/dev/null || true
   brain ask "papercut pipeline deploy <repo>" 2>/dev/null || true
   ```
   If an OPEN record exists, **append** a dated evidence line (sha, log path,
   status, reason) via `brain append` (never get→edit→put a large body).
   If FIXED/RECONCILED but the deploy is red again, reopen with a new
   `Status: OPEN` append + fresh evidence (same slug preferred).

2. **No open papercut** → **FILE a Brain papercut** immediately (CHEAP).
   Use `brain put` with YAML frontmatter on stdin (search first so you reuse
   the stable slug):

```yaml
---
type: reference
slug: papercut-pipeline-deploy-<repo>
title: "Pipeline: <repo> deploy-pipeline red/stuck"
tags: [papercut, pipeline, deploy, p0]
---

Status: OPEN
Severity: P0
Source: pipeline-health
Repo: EdgeVector/<repo>
Owner-hint: last-stack / schema-infra deploy path as appropriate

## Symptom
LastGit post-merge deploy-pipeline for <repo> is failure or stuck pending.
- sha: <sha>
- status: <failure|pending>
- reason: <reason from scan>
- log: ~/.lastgit/deploy-<repo>/deploy.log
- checked_at: <ISO-UTC>

## Why this is a papercut (not a board P0)
Pipeline recovery often needs multi-hour host deploy proof and/or unsandboxed
launchd ops. Filing direct kanban P0s monopolizes pickup without finishing.
Brain + papercut-reconciler owns promotion to board work.

## Suggested fix shape
1. Read deploy log tail + scratch under ~/.lastgit/deploy-<repo>/scratch.
2. Mechanical code/config fix in isolated worktree if needed; merge via venue.
3. Ensure deploy watcher LaunchAgent is healthy (unsandboxed host if required).
4. Confirm deploy log shows `success <new-sha> deploy-pipeline`.

## Never-again coverage
- Failure invariant: a red/stuck post-merge deploy must not silently starve
  feature pickup via perpetual P0 board monopoly, and must not leave main
  undeployed without a durable OPEN papercut.
- Current guard/test: NONE (pipeline-health brain-papercut path)
- Prevention: MISSING until a compound probe exists for deploy-green + no thrash

## Evidence
- pipeline-health wake <ISO-UTC>
- scan JSON / log excerpt …
```

3. Prefer spending the **heavy** unit on the oldest blocked deploy **only if**
   a mechanical fix fits this wake. Otherwise file/update the papercut and exit.
4. **Do not** create `deploy-pipeline-red-*` kanban cards. **Do not** re-rank
   todo to force pipeline work ahead of feature lanes.

Record in automation memory: `deploy_blocked=<repo:sha:…>` and
`filed_papercut=<slug[,…]>` / `updated_papercut=<slug[,…]>`; clear
`deploy_blocked` when scan shows unblocked. When a deploy goes green, append
`Status: FIXED (<ISO>)` to the papercut if you confirmed success this wake
(or leave it for reconciler if unsure).

**Do not heartbeat `noop` if any deploy is blocked** unless you already
filed/updated the Brain papercut (or fixed) every blocked entry this wake
(then heartbeat `ok` with `deploy_blocked=… filed_papercut=…`).

## LastGit socket / inventory
Use the primary LastGit socket by default. The old non-primary code forge socket
is retired; do not require it or treat its absence as a pipeline outage. Only
scan an additional LastGit socket when an explicit live inventory setting names
one for this routine.

```bash
export LASTGIT_SCHEMA_MAP="${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}"
export LASTGIT_SOCKET="${LASTGIT_PRIMARY_SOCKET:-$HOME/.lastdb/data/folddb.sock}"
lastgit list --json
```

If an explicitly configured extra socket errors with `wrong_node` (no lastgit
schemas), skip that extra socket. Prefer fleet open-CR inventory below; only
use `lastgit list --json` when you need the home list for non-CR checks
(deploy watchers, mirrors), not for open-CR enumeration.

## Open CRs (fleet — one query, not N× `cr list`)

**Do not** fan out `lastgit cr list <slug>` over every home. That was a top
LastDB ChangeRequest storm (2026-07-18). Prefer:

```bash
export LASTGIT_SOCKET="<socket>"
# Preferred: structured stuck classification (uses LastgitOpenCrIndex).
lastgit stuck --json --min-age-min 10
# Fleet open membership (thin; one OpenCrIndex read):
lastgit cr list --all-open --json
```

Only for CRs that look stuck (or need CI detail), point-read:

```bash
lastgit ci status <head_oid> --repo <slug> --json
# also try the CR's require_status context if different from the default
lastgit cr view <slug> <cr_id> --json
lastgit cr events <slug> <cr_id> --json
```

**Age / stuck rule:** treat a CR as STUCK when it has been `open` for **> 10
minutes** (from open event `created`/first event time, or from automation
memory's first-seen timestamp if events lack times) **and** any of:
- required CI is `success` / green but state is still `open` (completer lag);
- required CI is `failure` / red and no new head oid since failure;
- required CI is missing/pending with no update for >10 minutes;
- `forge run` / completer logs show repeated `merge_conflict` or
  `status_not_green` for this CR;
- `auto_merge` is not true while the CR was opened with auto-merge intent
  (card/PR body says so, or memory says it was).

Younger than 10 minutes with CI still running → leave it (normal lag).

**Stuck merges → Brain papercut (not board P0):** any STUCK CR is
pipeline-critical. If you cannot clear it this wake (heavy budget spent or
needs human), file/update:

- slug: `papercut-pipeline-stuck-cr-<repo>-<cr-id-short>` (or append to a
  stable `papercut-pipeline-stuck-merges-<repo>` if many)
- tags: `papercut,pipeline,p0`
- body: CR id, head oid, CI excerpt, first-seen age, why still open

Do not leave stuck merges only in the heartbeat with no Brain record.

### LastGit actions
1. **Green + auto_merge** →
   ```bash
   lastgit cr complete <slug> --once --json
   ```
   If still open, inspect completer/forge-run logs under
   `<LASTGIT_FORGE_LOG_DIRS>`; try once:
   ```bash
   lastgit cr merge <slug> <cr_id> --require-status <context> --json
   ```
   only when CI is green for the **current** head oid.
2. **Green but auto_merge false** → if policy allows unattended merge for this
   fleet (default yes for agent-driven kanban/* heads), merge with
   `--require-status`. Otherwise re-open is not available; leave a comment via
   memory/heartbeat that auto_merge is off.
3. **Red CI** → ALWAYS read `log_excerpt` / CI logs. Branch:
   - **Infra flake** (timeout, lost runner, cancelled with tests passing) →
     push an empty commit from a worktree to re-trigger the watcher, or re-push
     the head ref; do not "fix" product code.
   - **Mechanical** (fmt, lint, typecheck, snapshot) → fix in a fresh worktree
     off the head branch, verify locally with the repo's `.lastgit/ci.sh` or the
     narrowest command, push with lease, leave auto_merge on.
   - **Optional/environment tests** failing only because the CI scratch tree
     sees a host path (e.g. optional fold checkout tests) → fix the test gate
     to skip cleanly when the dependency is absent, or mark the suite optional
     in `.lastgit/ci.sh` if that is already the project convention; do not
     weaken real required tests.
   - **Real product failure / needs judgment** → do not guess. File or update a
     **Brain papercut** (not a board card) describing the failure + CR id, and
     leave the CR open.
4. **Merge conflict** → worktree at head, merge/rebase base, resolve only
   mechanical conflicts; if product conflict, flag via papercut and leave.
5. **Daemon unhealthy** (no forge-run log lines for many minutes while CRs are
   pending, or launchd job not running for the **non-primary** forge agent) →
   report in heartbeat; you may `launchctl kickstart -k gui/$(id -u)/<label>`
   **only** for explicitly listed non-primary labels in
   `<LASTGIT_SAFE_LAUNCHD_LABELS>`. NEVER kickstart/restart the primary brain
   node label. If you cannot fix launchd from this sandbox, file
   `papercut-pipeline-deploy-<repo>` or a host-ops papercut with
   `needs_human` in the body.

## Forgejo / fold (and other forge-hot)
For each repo in `<FORGE_HOT_REPOS>` (must include fold):

```bash
"$last_stack/bin/last-stack-forge-api" \
  "repos/<owner>/<repo>/pulls?state=open&limit=50" \
  --jq '.[] | {number,title,draft,mergeable,merged,updated_at,head:.head.ref,sha:.head.sha,mwcs:.merge_when_checks_succeed}'
```

Use `"$last_stack/bin/last-stack-forge-json-jq"` when piping raw bodies.

For each non-draft open PR, load checks / status via the forge API (see
`sop-forge-pr-workflow`). Apply the same >10 minute stuck rule.

### Forgejo actions
1. **Mergeable + required `Forge CI / ci-required` green + auto-merge off/null** →
   re-arm:
   ```bash
   "$last_stack/bin/last-stack-forge-api" --method POST \
     --data '{"Do":"merge","merge_when_checks_succeed":true,"delete_branch_after_merge":true}' \
     "repos/<owner>/<repo>/pulls/<n>/merge"
   ```
2. **BEHIND / conflict** → worktree rebase onto base, push with lease, re-arm.
3. **Red required CI** → same flake / mechanical / real split as LastGit; use
   `"$last_stack/bin/last-stack-forge-ci-log"` when available for logs.
4. **405 merge / stuck status-check** while green → empty-commit push from
   worktree (known Forgejo papercut; see brain
   `papercut-forge-merge-405-stuck-status-check`).
5. **Human-gated prod cutover** (title/body say so) → leave + papercut only.

Never use `gh` for forge-hot source-of-truth PRs. Never push the read-only
GitHub mirror of a forge-hosted repo.

## Venue resolution
Before acting on a local checkout, resolve:

```bash
repo="$("$last_stack/bin/last-stack-repo-op-guard" "<checkout>" "<WORKSPACE>")"
"$last_stack/bin/last-stack-pr-venue" --json <owner/repo> "$repo"
```

If `.venue == "lastgit"`, drive `lastgit cr` (not Forgejo/GitHub). If
`forgejo`, use the forge helper. If `github`, only touch it when that repo is
explicitly in `<GITHUB_PIPELINE_REPOS>` (default: empty — this routine focuses
on LastGit + Forgejo; public GitHub is covered by kanban-watch / drain-open-prs).

## Memory
Track first-seen timestamps and last action per `venue/repo/id` in automation
memory so age is computable even when APIs omit created_at. Prune entries for
CRs/PRs no longer open.

## Heartbeat (always)
```bash
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
"$last_stack/bin/last-stack-brain-append-heartbeat" --line \
  "pipeline-health $ts <ok|noop|error> open_cr=<n> open_forge=<n> deploy_blocked=<n|repo:sha,…> merged=<…> fixed=<…> stuck=<…> filed_papercut=<…> flagged=<…>"
```

Rules:
- Use **`noop` only** when open_cr=0, open_forge=0, **and** deploy_blocked=0
  (or every blocked deploy already has an OPEN Brain papercut you confirmed this
  wake without new action — still prefer
  `ok deploy_blocked=… already-papercut=…`).
- Use **`ok`** when you fixed, merged, filed/updated a papercut, or re-armed
  anything.
- Use **`error`** for tool/auth failures that prevented the deploy scan or the
  stuck-merge scan entirely.
- Prefer `filed_papercut=` over legacy `filed_p0=` (the latter meant board cards;
  do not reintroduce board P0 filing).

If brain is busy, write the same line into automation memory and continue; do
not retry-loop. For papercut writes under load, retry only idempotent slug
upserts in a bounded way.

## Report
End with a short report: open CR count per LastGit socket, open forge PR count,
**deploy-pipeline blocked list**, what you merged/fixed/nudged, which
**Brain papercuts** you filed/updated, what is still stuck and why, any daemon
concerns. Then exit.
