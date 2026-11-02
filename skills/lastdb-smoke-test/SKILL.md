---
name: lastdb-smoke-test
description: |
  Run the recurring, unattended LastDB local smoke test: a fast check that a
  pre-built `lastdbd` still boots and serves keyed reads on SYNTHETIC data,
  on an isolated port, never touching the primary brain. It never copies
  the primary database (Tom, 2026-10-12). Use this whenever asked to "run the
  lastdb smoke test", "do a lastdb local smoke test", "smoke-test lastdb
  main", "check if lastdb main still works", or when the scheduled
  `lastdb-local-smoke-test` routine fires. This is the CHEAP, FREQUENT
  regression check. It is distinct from the real-machine release gate (which
  needs a signed build and a human witness before a version reaches
  stable/Latest).
---

# lastdb-smoke-test

NEVER COPY THE PRIMARY DATABASE (Tom, 2026-10-12): "I don't want anything to
run copies of my database, it will kill my disk space and run super slow,
always use synthetic data for safe upgrades, testing cloud backup, etc." This
smoke test uses the synthetic seed of the `lastdb-safe-upgrade` skill. It does
not clone `~/.lastdb`, with or without `cp -cR`. Brain:
`decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data`.

An earlier version of this skill ran against a copy-on-write clone of the real
home and pointed at a "living SOP" that has no locator
(`papercut-lastdb-smoke-skill-omits-sop-locator-20261007`). Both are gone. This
file is the whole procedure.

## Do this, in order

1. Resolve a pre-built `lastdbd`. Do not build.

   ```bash
   last-stack-canary-resolve-lastdbd --json --allow-newest --allow-current --allow-daemon-only
   ```

   If the status is `need_build`, stamp `noop reason=no-staged-lastdbd` and stop.
   `lastdb-canary-candidate-set` is the builder.
2. Run the driver in probe-only mode. It builds or reuses the synthetic seed,
   boots the candidate on a copy of the seed, and checks keyed reads, row
   counts, memory size and read latency. It changes nothing live.

   ```bash
   bash ~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh \
     --candidate /path/to/lastdbd --probe-only
   ```

   The driver needs the `lastdb` CLI of the same build next to the `lastdbd`. If
   the stage holds a daemon only, stamp `noop reason=no-candidate-pair` and stop.
3. Read the `VERDICT:` line. `GREEN_PROBE_ONLY` is GREEN. `RED` is RED. Keep the
   `REASON:` line.
4. Classify every finding. A papercut gets a brain record ONLY: slug
   `papercut-<short-topic>`, dedupe against existing ones first and bump
   "last seen" rather than duplicating. Do NOT file a kanban card for it. A
   release BLOCKER is not a papercut and needs a `release-blocker` kanban card.
   A finding that you only describe in your summary has accomplished nothing.
5. Tear down: confirm the primary socket `~/.lastdb/data/folddb.sock` is still
   alive (`kanban ping`) and that the driver left no trial home in
   `${TMPDIR}/lastdb-safe-upgrade-rollback-<uid>/`. Release a retained one with
   `scripts/cleanup-retained-upgrade-copy.sh`.
6. Write the brain closeout (close-out skill).

## Never

- Copy `~/.lastdb` (also with `cp -cR`), or boot a node on a copy of it.
- `cargo build` / `cargo test` in this scheduled canary.
- Touch `~/.lastdb` directly, or kill/restart the primary LastDB brain.
- Build in the shared `~/code/edgevector/lastdb` checkout in place.
- Treat a green smoke run as sufficient to promote a build to stable.

## When NOT to use this

There is no UI review path any more. The LastDB desktop app was deprecated on
2026-08-26. The `lastdb-ui-design-review` skill was retired with it; the
new-user path is the CLI/llms.txt install (skill `llms-txt-install-smoke`).
For the pre-release human-witnessed gate, that's a separate, heavier SOP
(`north-star-lastdb-release-works-on-real-machine`) — don't treat a green smoke
run as sufficient to promote a build to stable.
