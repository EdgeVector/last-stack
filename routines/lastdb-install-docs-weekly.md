---
name: lastdb-install-docs-weekly
cadence: weekly
description: >
  Weekly: refresh thelastdb.com install/use docs against product reality,
  prove them with an ephemeral fresh-install node, and heal (loop) until GREEN
  within a bounded cycle budget. Never touches primary LastDB.
---

You are running the unattended **weekly** install-docs prove-and-heal routine.

**Objective:** Make sure a brand-new user following the **LastDB website**
(install + how to use — especially https://thelastdb.com/llms.txt and
https://thelastdb.com/start) still ends up with a working stack. Update the
website when instructions lag. Prove with a **fresh ephemeral LastDB node**.
If proof fails, **fix and re-prove in a loop until GREEN** (bounded).

**Shared contract:** at run start fetch and honor
`brain get sop-routine-shared-contract --type sop` — heartbeat LAST always,
primary-brain guardrail, dedupe-before-filing, scheduled-run shell discipline,
papercuts → brain only. This routine is an **authorized heal loop** for the
public install path (website docs + small installer-path fixes); it is **not**
a free license to ship unrelated product. If this prompt conflicts with the
contract on safety/heartbeat/papercuts, the contract wins. On loop budget, this
prompt's explicit max-cycle rule is the intended specialization of §5.

## Automation memory

If the scheduled prompt includes an `Automation memory:` path, use that exact
file. Else
`${ROUTINES_HOME:-$HOME/.routines}/memory/lastdb-install-docs-weekly/memory.md`.

## Setup

```bash
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:$PATH"
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude" 2>/dev/null || true
"$last_stack/bin/last-stack-cli-preflight" git curl brew lastdbd bun 2>/dev/null || true
```

- Cwd workspace is a container of portals — use `./bin/wt start` under
  `fold_db_website` / `last-stack` portals for any ship work.
- Busy node (`service_timeout` / concurrent reads): heartbeat `busy-node` and EXIT.
- Secrets: LastSecrets only.

## Do this (one weekly fire)

1. **Playbook** — read and follow skill **`lastdb-install-docs-weekly`**
   (`$last_stack/skills/lastdb-install-docs-weekly/SKILL.md`). Prefer it over
   improvising steps.

2. **Diff** live website + `fold_db_website` sources vs product install reality.
   Note docs lag vs product breaks.

3. **Update website** when install/use instructions are wrong or incomplete:
   worktree → edit `public/llms.txt` (+ Start/docs install pages as needed) →
   `lastgit cr` on `EdgeVector/fold_db_website` → drive/merge → wait for live
   content when possible. Do not paper over product bugs with fake docs.

4. **Smoke (ephemeral node)** — always isolated:
   ```bash
   bash "$last_stack/skills/llms-txt-install-smoke/run.sh" --json
   ```
   Capture `VERDICT: GREEN|RED` and failing steps. **Never** brew-services or
   real `~/.lastdb`.

5. **Loop until GREEN (budgeted):**
   - Max **3 heal cycles** per fire (diff/fix → smoke → classify).
   - **Docs lag** → ship website fix → re-smoke.
   - **Installer path** → small last-stack fix via worktree+CR when clearly
     in-scope; else one P0/P1 card; re-smoke if a fix landed.
   - **Product break** → file/update one card per failure cluster (dedupe
     first); if you can land a minimal fix this run, do so and re-smoke;
     otherwise stop looping that cluster.
   - Do not sleep-poll for hours; wait only on CRs you opened, within timeout.

6. **Ground truth** — append newest-on-top line to brain reference
   `lastdb-install-docs-weekly-status` (create if missing):
   ```text
   <ISO-UTC> <GREEN|RED> cycles=<N> docs_changed=<yes|no> fails=<short> run=<id>
   ```

7. **Heartbeat LAST (always):**
   ```text
   lastdb-install-docs-weekly <ISO-ts> <ok|error> <GREEN|RED one-line summary>
   ```
   Prefer
   `${LAST_STACK_ROOT:-$HOME/.last-stack}/bin/last-stack-brain-append-heartbeat --line "…"`.

## Safety floor

- Never restart/kill primary `lastdbd` / brew `lastdb`.
- Never point smoke at `~/.lastdb/data/folddb.sock`.
- Never mark GREEN on partial/skipped smoke.
- Optional private apps (lastsecrets) may skip without RED if installer already treats them optional.
- Daily observe-only sibling remains `llms-txt-install-smoke` (paused or active independently).

## Related

- Skill: `lastdb-install-docs-weekly`
- Smoke script: skill `llms-txt-install-smoke`
- Distinct from real-data Mini canary: `lastdb-local-smoke-test`
