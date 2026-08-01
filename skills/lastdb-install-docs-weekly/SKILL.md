---
name: lastdb-install-docs-weekly
description: |
  Weekly prove-and-heal loop for the public LastDB install/use path:
  refresh thelastdb.com install + how-to-use docs against product reality,
  then dogfood a fresh install on an ephemeral isolated node until GREEN.
  Use when asked to "prove install docs", "weekly install smoke + docs",
  "heal thelastdb.com install instructions", or when the scheduled
  `lastdb-install-docs-weekly` routine fires.
---

# lastdb-install-docs-weekly

**Prove that following the public website still installs and works.**
Once a week: update install/use docs if they lag product reality, then run a
**throwaway empty** LastDB node smoke (never Tom's primary `~/.lastdb`). On
RED, fix what this routine is allowed to ship (website docs first; small
installer-path fixes second), re-smoke, and **loop until GREEN** within a
bounded budget.

This is **not** the daily canary (`llms-txt-install-smoke`) which only
observes and files cards. This is the weekly **heal** loop.

## Surfaces

| Surface | Repo / path | Role |
|---------|-------------|------|
| Agent install map | https://thelastdb.com/llms.txt → `fold_db_website` `public/llms.txt` | Canonical agent install steps |
| Install / use pages | `fold_db_website` `src/pages/Start.jsx`, Docs install pages, home install section | Human install + daily loop |
| Fresh-install canary | skill `llms-txt-install-smoke` / `run.sh` | Ephemeral HOME + `LASTDB_HOME` + manual `lastdbd` |

## Hard rules

1. **Never** start/stop/restart primary `brew services lastdb` / `lastdbd` on
   `~/.lastdb`. Smoke always uses isolated `HOME` + `LASTDB_HOME`.
2. **Never** write to real `~/.brain`, `~/.kanban`, `~/.situations` during smoke.
3. Product code only in **DEV worktrees** (`./bin/wt start` / portal wt). Never
   edit portals, `~/.last-stack` install tree, or host-track `current`.
4. Venue: `fold_db_website` and `last-stack` are **lastgit** — `lastgit cr`, never
   GitHub PRs on read-only mirrors.
5. Honor `brain get sop-routine-shared-contract --type sop` (heartbeat LAST;
   papercuts → brain only; real blockers may card).
6. **Bounded loop** — not infinite. Default: **max 3 heal cycles** per weekly
   fire, wall-clock under the routine timeout. SOP §5 "do not loop forever"
   still applies; the budget *is* the loop.

## Preferred path each weekly fire

### 0. Orient

```bash
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
situations list --json || true
brain get sop-routine-shared-contract --type sop
```

Busy-node / situations blocked: heartbeat and exit (do not heal under load).

### 1. Diff product reality vs website

Read live + source of truth:

- Live: `curl -fsSL https://thelastdb.com/llms.txt`
- Source: portal worktree for `fold_db_website` → `public/llms.txt`,
  `src/pages/Start.jsx`, install docs pages, home install section
- Product: current public install path (`last-stack` setup / install-apps,
  brew formula name, socket path `/health`, `brain`/`kanban`/`situations`
  first-run verbs, lastsecrets policy)

Mark each gap as **docs lag** | **installer lag** | **product break**.

### 2. Refresh website when docs lag (authorized ship)

If install/use instructions are wrong or incomplete relative to a working
product path:

1. `cd ~/code/edgevector/fold_db_website && ./bin/wt start lastdb-install-docs-weekly-<date>`
2. Update `public/llms.txt` and human pages so they match a path that the
   ephemeral smoke can pass (same steps the smoke asserts).
3. Bump any "Last reviewed" stamps.
4. `lastgit cr create` with a full body; drive to merge (or leave auto-merge
   armed and wait within budget).
5. After merge, wait until **live** `https://thelastdb.com/llms.txt` reflects
   the change (or until deploy timeout → note and continue smoke on product
   path; re-check live content next cycle).

Do **not** invent workarounds that hide product breaks (e.g. "skip kanban
init") just to paint docs GREEN.

### 3. Ephemeral fresh-install smoke

Always use the isolated canary — never primary:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude"
bash "$last_stack/skills/llms-txt-install-smoke/run.sh" --json
# VERDICT: GREEN|RED; exit 0/1
```

Capture failing step names + short log excerpts.

### 4. On GREEN

- Append ground-truth line (newest on top) to brain
  `lastdb-install-docs-weekly-status` (type `reference`):
  ```text
  <ISO-UTC> GREEN cycles=<N> docs_changed=<yes|no> smoke=pass run=<RUN_ID>
  ```
- Heartbeat ok GREEN and exit. No cards required.

### 5. On RED — classify and heal (loop)

| Class | Action this cycle | Re-smoke? |
|-------|-------------------|-----------|
| **Docs lag** | Ship `fold_db_website` fix (step 2) | Yes after live (or local source) updated |
| **Installer / last-stack path** | Small fix in last-stack worktree + lastgit CR; or P0 card if large | Yes after merge when possible |
| **App/product break** (brain/kanban/situations/daemon) | File/update **one** P0/P1 card per cluster with evidence; optional minimal fix if you can land it this run | Yes only if a fix landed |
| **Infra / mirror stale** | Card the mirror/deploy owner; do not thrash | No spin-wait; next cycle |

Then **go back to step 3** until:

- `VERDICT: GREEN`, or
- **max 3 heal cycles** exhausted, or
- remaining failures are all product/human gates that cannot ship in-run

If still RED after budget: leave open cards, write RED ground-truth line,
heartbeat `error RED after N cycles …`, exit non-zero conceptually (report
error outcome).

### 6. Cards (when filing)

Dedupe first: `kanban list --column todo --json`, `kanban list --column doing
--json`, `kanban search "llms-txt|first-run|install docs" --json`.

Pickup-ready body: Repo bare `owner/name`, Base, Branch, North Star or
`## END STATE`, GOAL/CONTEXT/STEPS/VERIFY/DONE WHEN. Tags:
`first-run`, `install-docs-weekly`, subsystem.

Papercuts (stale wording, polish) → brain `papercut-…` only, not board.

## Never

- Primary brain restart / kill / brew services toggle for "health"
- Point smoke at `~/.lastdb/data/folddb.sock`
- Infinite sleep-poll across hours; one bounded weekly fire
- Mark GREEN on partial/skipped smoke
- Ship desktop/DMG/fold_db_node work (deprecated fence)

## Related

- Daily observe-only canary: skill + routine `llms-txt-install-smoke`
- Real-data Mini canary: `lastdb-smoke-test` / `lastdb-local-smoke-test`
- Public map: https://thelastdb.com/llms.txt · https://thelastdb.com/start
- Shared contract: `sop-routine-shared-contract`
