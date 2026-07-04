---
name: lastdb-ui-design-review
description: |
  Run a live UX/visual design pass on the LastDB desktop UI (the React+Vite
  app in fold/fold_db_node/src/server/static-react) against a fresh isolated
  dev node, dedupe findings against open fkanban cards AND merged PRs, and
  file new `lastdb-ui-*` cards for real issues. Use whenever asked to "review
  the lastdb ui", "do a lastdb design review", "check the lastdb UI for
  visual/UX issues", "run a design pass on lastdb", or when the scheduled
  `lastdb-ui-design-review` routine fires (~09:32 daily). This is
  LastDB-specific — it knows the exact isolated dev-launch recipe, the
  desktop-only scope rule, and the no-emoji enforcement — so prefer it over
  the generic `design-review` skill for this app; that generic skill doesn't
  know this project's launch config or dedupe conventions.
---

# lastdb-ui-design-review

The LastDB UI is a **desktop-only** React+Vite app (IBM Plex Mono / gruvbox-
dark, Heroicons line-art nav) served by the `fold_db_node` Rust binary. Full
background lives in fbrain `lastdb-ui-dev-review-recipe-and-routine` — read it
first; this file is the short version plus the one lesson worth repeating
every time.

## Setup (never touches Tom's primary brain)

1. **Pull latest main first.** `cd fold && git fetch && git checkout main &&
   git pull`. A stale dev build has already produced a real false-positive
   run — 4 onboarding cards filed against bugs a merged PR had already fixed.
   Dedupe against merged PRs, not just currently-open cards.
2. Launch via the Claude_Preview MCP using the `lastdb-ui` config in
   `~/code/edgevector/.claude/launch.json`:
   `cd fold/fold_db_node && FOLDDB_DISABLE_KEYCHAIN=1 FOLDDB_PORT=9101
   VITE_PORT=5173 FOLDDB_HOME=/private/tmp/lastdb-uxreview ./run.sh`.
   This is an isolated tmp node on TCP 9101 — not the folddb_server brain on
   the `~/.folddb` socket. `run.sh` runs node + Vite as one lifecycle (killing
   the Vite child tears down both, via trap), so `preview_stop` cleanly tears
   the whole stack down.
3. If it's a fresh data dir, bootstrap past onboarding:
   `POST :9101/api/setup/bootstrap {"name":"uxreview","master_password":"..."}`.
   A stale data dir returning `KEYCHAIN_RECOVERY_REQUIRED` means wipe
   `/private/tmp/lastdb-uxreview/data` and retry.
4. To review an in-progress worktree's uncommitted frontend changes instead
   of main, run the prebuilt `fold/target/debug/lastdb_server --with-tcp
   --port <p> --data-dir <fresh>` backend plus Vite from that worktree with
   `VITE_API_PORT=<p>` — same isolation principle, different source tree.

## Review

Walk the desktop tabs (sidebar groups: MAIN/DATA/IMPORT/SOCIAL/ADMIN/SYSTEM)
looking for the usual design-review lenses — contrast/accessibility, dead-end
empty states with no CTA, label/copy mismatches, jargon, inconsistent
component patterns, unthemed browser chrome (e.g. bright default scrollbars).
Never file a narrow-width/mobile finding — this app is desktop-only by
decision (see `projects-fold_db_node-ui-desktop-only`), so treat mobile
layout complaints as out of scope, not a bug.

**No-emoji rule (enforced by CI):** the app source must never contain a
Unicode Emoji_Presentation character or `FE0F` (checked by
`src/test/no-emoji.test.ts`; `src/data` mock content and tests are exempt,
monochrome ✓/✕ are fine). If you spot an emoji in product UI, that's a real
finding, not a style nitpick.

## Filing

File real issues as fkanban cards, slug pattern `lastdb-ui-*`, column `todo`,
repo `EdgeVector/fold`. Before filing, check both the open board AND recently
merged PRs — the dedupe-against-merged-not-just-open lesson above is the
single most common way this routine wastes a filing. A typical run surfaces
10-20 cards on a fresh pass, fewer on a repeat run against an already-reviewed
build.

## When NOT to use this

For confirming the app *functions* on real data (not visual quality), use
`lastdb-smoke-test` instead — that's the automated pass/fail regression
check, this is the subjective UX pass. For a generic web app with no
LastDB-specific launch recipe, use the generic `design-review` skill.
