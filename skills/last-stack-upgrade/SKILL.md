---
name: last-stack-upgrade
version: 0.3.0
description: |
  Upgrade The Last Stack to the latest version and show what changed. Detects
  where the stack is installed (the cloned repo dir), runs the clean-only
  `last-stack-self-upgrade` helper (managed install mirror repair + setup), and reports
  the version delta. Use when asked to "upgrade the last stack", "update the
  last stack", "get the latest skills", or when a skill preamble / routine
  reports UPGRADE_AVAILABLE or LAST_STACK_ROUTINE_STALE.
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

2. **Prefer the safe helper** (refuses dirty trees; never force-resets):
   ```bash
   OLD_HEAD=$(git -C <install-dir> rev-parse --short HEAD)
   OLD=$(cat <install-dir>/VERSION)
   <install-dir>/bin/last-stack-self-upgrade --repair-dirty --reason=skill
   NEW_HEAD=$(git -C <install-dir> rev-parse --short HEAD)
   NEW=$(cat <install-dir>/VERSION)
   echo "Upgraded The Last Stack: $OLD ($OLD_HEAD) -> $NEW ($NEW_HEAD)"
   ```
   If the helper is missing (very old install), fall back to:
   ```bash
   cd <install-dir>
   # only when git status --porcelain is empty
   git pull --ff-only && ./setup
   ```

3. **Report what changed.** Show the version/head delta and, if useful, the
   changelog between versions:
   ```bash
   git -C <install-dir> log --oneline "$OLD_HEAD..HEAD" 2>/dev/null || \
     git -C <install-dir> log --oneline -10
   ```

## Notes

- **Install dir is product, not a dev checkout.** Feature work belongs in a
  separate clone. Local edits in `~/.last-stack` make `error-dirty` and block
  every scheduled routine that depends on freshness.
- `last-stack-self-upgrade` is clean-only by default. The explicit
  `--repair-dirty` install-mirror mode first writes a recovery bundle and
  binary patches outside the install, then resets the disposable install to
  verified venue `main`. It never force-pushes or rewrites a development clone.
- `last-stack-routine-read` already calls the helper on staleness; this skill is
  the interactive/manual path and the recovery when auto-heal cannot run.
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
