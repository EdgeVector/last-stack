# Routine Fleet Portability

This guide bootstraps the shared routine fleet for a new project that runs
Brain, Kanban, and a PR/CR venue such as GitHub, Forgejo, or LastGit. The goal is
to make routine prompts and engine skills generic: project facts live in
records, not in copied prompt text.

## Architecture

The fleet has three layers:

1. **Generic engine skills** live in Last Stack. They know how to rotate a
   registry, mine sessions, reconcile PRs, groom a board, or run probes, but
   they do not know project-specific paths, repos, tokens, or venues.
2. **Project records** hold the constants and registries. The bootstrap kit
   includes templates for `workspace-config`, `repo-venue-map`, `tag-repo-map`,
   `signal-sources`, and `probe-registry`.
3. **Shared routine contract** is the project SOP named
   `sop-routine-shared-contract`. Routines cite it for heartbeat, dedupe,
   guardrails, shell discipline, and validation rules.

When the project has a dedicated config app, store config-class records there
and keep the brain copies as pointers. The bootstrap shape stays the same:
engines read named records through the configured source instead of editing
engine skills or routine prompts.

## Bootstrap Order

1. Install Last Stack and the LastDB app stack.

   ```bash
   git clone https://github.com/EdgeVector/last-stack ~/.last-stack
   ~/.last-stack/setup
   ~/.last-stack/bin/last-stack-install-apps
   ```

2. Initialize Brain and Kanban for the project.

   ```bash
   fbrain init --grant-consent
   fkanban init
   ```

3. Copy the templates to a scratch directory and replace every placeholder.

   ```bash
   mkdir -p /tmp/routine-fleet-bootstrap
   cp ~/.last-stack/templates/routine-fleet/*.md /tmp/routine-fleet-bootstrap/
   rg '<[A-Z0-9_]+>' /tmp/routine-fleet-bootstrap
   ```

4. Seed the records.

   ```bash
   for file in /tmp/routine-fleet-bootstrap/*.md; do
     fbrain put < "$file"
   done
   ```

5. Verify the records can be read by slug.

   ```bash
   fbrain get workspace-config
   fbrain get repo-venue-map
   fbrain get tag-repo-map
   fbrain get signal-sources
   fbrain get probe-registry
   fbrain get sop-routine-shared-contract
   ```

6. Register scheduled routines only after the records are valid. Routine prompts
   should cite the engine skill, the relevant record slug, and
   `sop-routine-shared-contract`; they should not copy project paths or repo
   venue tables inline.

## Template Responsibilities

| Template | Purpose |
|---|---|
| `workspace-config.md` | Workspace root, owner, CLI names, data-plane endpoints, worktree dirs, guardrails, and PATH prefix. |
| `repo-venue-map.md` | Repo to review venue routing, required check names, merge mechanism, and hands-off repos. |
| `tag-repo-map.md` | Conservative tag to `Repo:` mapping for groom and program-driver routines. |
| `signal-sources.md` | Error, usage, and alert feeds with secret locators, triage thresholds, repo routing, and dedupe ledgers. |
| `probe-registry.md` | Continuous sentinel recipes, pass assertions, isolation rules, verdict records, and card targets. |
| `sop-routine-shared-contract.md` | Shared heartbeat, dedupe, guardrail, shell, verification, block-ownership, verdict, and human-gate rules. |

## Dry-Run Checklist

Before scheduling any routine, use a hypothetical project and confirm:

- every placeholder in `templates/routine-fleet/*.md` can be filled without
  editing an engine skill;
- every repo in `tag-repo-map` also appears in `repo-venue-map`;
- every secret is a locator such as `lastsecrets://...`, never a raw value;
- every probe names an isolation surface and pass assertion;
- every routine prompt can say "use engine skill X with record Y and
  `sop-routine-shared-contract`" without embedding project constants;
- Kanban cards filed by routines have a valid `Repo:`, `Base:`, `Branch:`,
  `GOAL`, `STEPS`, `VERIFY`, and `DONE WHEN`.

If any step requires editing a routine prompt to change paths, venues, tokens,
or repo mappings, move that value into one of the records first.
