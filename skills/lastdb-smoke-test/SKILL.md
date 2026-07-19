---
name: lastdb-smoke-test
description: |
  Run the recurring, unattended LastDB local real-data smoke test — a fast
  (~minutes) regression check that current `origin/main` still works against
  a fresh copy-on-write copy of Tom's REAL LastDB data, on an isolated port,
  never touching the primary brain. Use this whenever asked to "run the
  lastdb smoke test", "do a lastdb local smoke test", "smoke-test lastdb
  main", "check if lastdb main still works", or when the scheduled
  `lastdb-local-smoke-test` routine fires (every 6h). This is the CHEAP,
  FREQUENT regression check — distinct from `onboarding-preview` (drives the
  first-run setup wizard UI) and the real-machine release gate (which needs a
  signed build + human witness before a version reaches stable/Latest). Make
  sure to reach for this instead of hand-deriving the smoke steps from
  scratch — the full procedure, with every hard-won gotcha, lives in a living
  brain SOP that this skill always reads fresh before running.
---

# lastdb-smoke-test

This wraps a procedure that has already bitten hard on nearly every axis —
stale binaries, stub builds, clobbered launch configs, wrong build dirs — and
the fixes are all recorded as a **living SOP in brain**, not baked into this
file. Read it fresh every run; it gets a new dated "Change log" entry (and
sometimes a new numbered step) each time a run discovers something new, so a
stale copy here would silently regress the procedure.

## Do this, in order

1. `brain_get slug:sop-lastdb-local-smoke-test` (paginate with `body_offset`
   until `bodyNextOffset` is null — it's long). Read the **Hard rules** and
   **Procedure** sections in full before touching anything; skimming has
   caused real repeat failures (stub binaries, stale checkouts).
2. Note the last run number in the SOP's "Change log" — you're run N+1.
3. Follow the numbered procedure exactly, including every pre-flight check
   (stale orphan node on port 8902, the shared `launch.json` getting
   clobbered by another session, the build.rs-stub check after any rebuild).
   The SOP's Hard rules section explains **why** each check exists — read
   those, don't just execute steps blind, because the "why" is what lets you
   correctly judge a borderline case (e.g. whether a stale binary is an
   acceptable deviation this run).
4. Classify every finding per the SOP's **Filing rule** (tightened by Tom
   2026-07-19, brain `preference-always-file-papercuts-in-brain`): a
   papercut gets a brain record ONLY — slug `papercut-<short-topic>`,
   dedupe against existing ones first and bump "last seen" rather than
   duplicating; do NOT file a kanban card for it (a dedicated triage
   routine cards brain papercuts). A release BLOCKER is not a papercut and
   still needs a `release-blocker` + `subsystem-fold_db_node` kanban card,
   possibly linked into the release-gate epic. A run that finds something and
   only describes it in your final summary, without filing it, has
   accomplished nothing — the finding evaporates with the session.
5. Tear down cleanly (stop the preview server, remove any rebuild worktree,
   confirm the primary brain socket `~/.lastdb/data/folddb.sock` is still
   alive and the shared `fold` checkout's tracked files are untouched).
6. Append a dated "Change log" entry to the SOP (`brain_put` on
   `sop-lastdb-local-smoke-test`, appending — never silently rewriting past
   entries) recording: run number, binary/commit built from (or the
   acceptable-stale justification), GREEN/RED result per tab, and anything
   filed. If you hit a new gotcha, add a numbered procedure step too — the
   next run (and the next agent) should inherit the improvement, not
   rediscover it.

## Never

- Touch `~/.lastdb` or `~/.folddb` directly, or kill/restart the primary
  LastDB brain. This test always runs against a throwaway COW copy on an isolated
  port — see the SOP's Hard rules for the exact recipe.
- Build in the shared `~/code/edgevector/fold` checkout in place — it's
  frequently behind `origin/main`. Rebuild from a disposable worktree at
  `origin/main` (recipe in the SOP), never `git reset`/`checkout` the shared
  checkout.
- Trust a fresh binary mtime as proof the build is good — a `cargo build`
  that ran before `npm run build` silently embeds a blank stub UI. The SOP's
  step 1b curl check catches this; always run it after any rebuild.

## When NOT to use this

For the daily UX/visual review of the LastDB UI, use `lastdb-ui-design-review`
instead — this skill only checks that the app functions on real data, it does
not judge visual/UX quality. For the pre-release human-witnessed gate, that's
a separate, heavier SOP (`north-star-lastdb-release-works-on-real-machine`) —
don't treat a green smoke run as sufficient to promote a build to stable.
