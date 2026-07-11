---
name: last-stack-upgrade
version: 0.2.0
description: |
  Upgrade The Last Stack to the latest version and show what changed. Detects
  where the stack is installed (the cloned repo dir), runs `git pull`, re-runs
  `./setup` to re-register the skills into your agent harnesses, and reports the
  version delta. Use when asked to "upgrade the last stack", "update the last
  stack", "get the latest skills", or when a skill preamble reports
  UPGRADE_AVAILABLE from `bin/last-stack-update-check`.
allowed-tools:
  - Bash
  - Read
triggers:
  - upgrade the last stack
  - update the last stack
  - get latest last stack
  - last stack upgrade
---

# last-stack-upgrade

Upgrade The Last Stack in place and re-register the skills.

## Steps

1. **Find the install dir.** The Last Stack lives in the git repo you cloned at
   install time (commonly `~/.last-stack`, or wherever you cloned it). If unsure:
   ```bash
   for d in "$HOME/.last-stack" "$HOME/last-stack" "$PWD/last-stack"; do
     [ -f "$d/VERSION" ] && [ -d "$d/.git" ] && echo "$d" && break
   done
   ```
   If none resolve, ask the user where they cloned it.

2. **Record the current version**, then pull and re-run setup:
   ```bash
   cd <install-dir>
   OLD=$(cat VERSION)
   git pull --ff-only
   NEW=$(cat VERSION)
   ./setup        # re-registers skills into every harness you have
   echo "Upgraded The Last Stack: $OLD -> $NEW"
   ```

3. **Report what changed.** Show the version delta and, if useful, the changelog
   between versions:
   ```bash
   git log --oneline "v$OLD..HEAD" 2>/dev/null || git log --oneline -10
   ```

## Notes

- `git pull --ff-only` keeps it safe — if the local repo has diverged (you edited
  a skill), it stops cleanly instead of creating a merge. Resolve, then re-run.
- Re-running `./setup` is idempotent; it refreshes the SKILL.md links so every
  installed harness picks up the new version.
- This only updates The Last Stack's own skills — it never touches skills you
  added yourself.
- **Run this (or Last Stack `./setup`) AFTER any gstack setup / `/gstack-upgrade`.**
  gstack `./setup` re-symlinks its skills into `~/.claude/skills/<name>` and, when
  a gstack skill shares a name with a Last Stack one (e.g. gstack's mermaid
  `diagram` vs. Last Stack's hand-drawn architectural `/diagram`), silently
  replaces ours. Last Stack `./setup` re-points our links back, and its final step
  runs `bin/last-stack-verify-skill-links` to prove every Last Stack skill still
  resolves into the Last Stack tree. If you upgraded gstack last and don't want a
  full re-setup, just run the guard on its own:
  ```bash
  ~/.last-stack/bin/last-stack-verify-skill-links          # verify + repair drift
  ~/.last-stack/bin/last-stack-verify-skill-links --check  # report only, non-zero on drift
  ```
