---
name: lastdb-safe-upgrade
description: |
  Required path for a primary LastDB Mini version change. The driver boots
  the exact candidate on a copy of a small synthetic seed. It never copies the
  primary database and never runs a node on a copy of it (Tom, 2026-10-12). It
  requires keyed reads, read latency, memory and persist status checks, and a
  source-free restore of an exact DEV snapshot of the seed before a live
  cutover. It then requires a current cloud backup (the recovery point), a
  strict stopped flush receipt, supervised live health, and a cloud frontier
  check. It makes no copy of the primary at any step. It does not run tests.
---

# lastdb-safe-upgrade — never brick the primary; never take it down first

Tom's primary brain is `~/.lastdb` (~multi-GB). Past upgrades have bricked real
data. **Standing rule (Tom, 2026-07-14):** every version change uses this skill so
Tom does **not** experience primary-brain downtime as the first feedback that a
release is broken — fail on the ephemeral copy; keep live on last known-good until
GREEN. The candidate must pass on an ephemeral copy before the primary changes.

**NEVER COPY THE PRIMARY DATABASE (Tom, 2026-10-12):** "I don't want anything
to run copies of my database, it will kill my disk space and run super slow,
always use synthetic data for safe upgrades, testing cloud backup, etc." No
probe copies `~/.lastdb`. No node boots on a copy of it. There is no real-data
mode and no `--data real`. Every probe, and the DEV photograph (cloud backup and
restore proof), runs on SYNTHETIC data. Brain:
`decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data`.

**Candidate data:** each run prepares a trial home from a small synthetic seed.
The candidate boots a separate copy of that trial home. See
[Candidate data: the synthetic seed](#candidate-data-the-synthetic-seed).

This skill and its Loom `lastdb-safe-upgrade` graph are the **only** allowed
path for a live binary change on this machine. The shell driver remains the
probe and cutover implementation. It refuses a live cutover outside Loom.

`last-stack-safe-upgrade-loom` always runs the graph on Loom local recovery.
Loom uses the trusted local graph bundle and a protected journal outside
LastDB. The launcher reconciles that journal into LastDB after a successful
run. A slow or down primary cannot stop the upgrade that replaces it. Other
Loom graphs do not use this mode. Decision:
`decision-2026-10-04-safe-upgrade-always-local-journal`.

## Install location (all harnesses)

Shipped in **last-stack** (`skills/lastdb-safe-upgrade/`). After
`~/.last-stack/setup --host auto` (or `claude` / `codex` / `factory` /
`opencode`), the skill is registered for every harness:

| Harness | Path |
|---------|------|
| Canonical | `~/.last-stack/skills/lastdb-safe-upgrade/` |
| Claude | `~/.claude/skills/lastdb-safe-upgrade/` (symlink into last-stack) |
| Codex | `~/.codex/skills/lastdb-safe-upgrade/` |
| Factory | `~/.factory/skills/lastdb-safe-upgrade/` |
| OpenCode | `~/.config/opencode/skills/lastdb-safe-upgrade/` |

Prefer the **driver script** path below; do not hard-code a single harness dir.

To install an accepted LastStack repair without a change to unrelated services:

```bash
LAST_STACK_SETUP_PRESERVE_SERVICES=1 host-track refresh last-stack
```

The opt-in flag accepts only 0 or 1. The default remains 0.
It skips the routines CLI installer, refresh agent, other LaunchAgent installers,
all routine registry seeders, and the self-upgrade agent installer or uninstaller.
It also refuses the broad setup uninstaller. Nested setup inherits the flag.
Artifact provenance, probes, command and skill links, compatibility layout,
and instruction updates retain the normal path.

## Recovery point: the cloud backup, never a copy (Tom, 2026-10-12)

The live cutover makes no copy of the primary home. Not a rollback copy, not a
stopped copy, not a copy for a first backup. The recovery point is:

- the primary's own cloud backup, which must be CURRENT before the old daemon
  stops (Cloud Sync on and state `Idle`, `Dirty`, or `Syncing`, no failures,
  the mutation log published
  through the local frontier, no upload backlog, recovery point age at most 300 s;
  `LASTDB_CLOUD_RECOVERY_MAX_AGE_SECS` changes the unsigned limit). A bounded
  exact-integer decoder requires the published frontier to cover both the
  compatibility frontier and the separate local durable frontier in that sample.
  The sample does not cover later writes or writes that still wait for local flush.
  The strict stop remains a separate gate. If any sample requirement is
  false the driver exits RED and the primary is not stopped.
- the saved binary pair `lastdbd.bak-pre-*` and `lastdb.bak-pre-*`.

`Idle`, `Dirty`, and `Syncing` are normal native phases. Each phase must pass
the same coverage and health checks. `Offline`, `Paused`, and unknown states
fail the gate.

A bad cutover recovers the binary first (see Rollback). It recovers data with
`lastdb restore --into <fresh home>` from the latest cloud backup. That restore is
slow (a past restore needed about 43 minutes to republish its cloud frontier).
This is weaker than a byte-exact local copy. Tom chose it because a copy of the
primary fills the disk and slows the machine.

The older one-off flow that stopped the daemon, made an APFS copy and ran
`cloud backup-while-off` on it (`stopped-home-copy.sh`, `cleanup-stopped-copy.py`)
is removed. The primary syncs to the cloud now; use that backup.

## Live venue (important — 2026-07-16)

Primary can use either supervisor, but exact-candidate live cutover supports
only sidebin:

| Venue | How primary runs | Live install |
|-------|------------------|--------------|
| **sidebin** (Tom’s default) | LaunchAgent → `~/.lastdb/bin-with-upload-cap/lastdbd` | Atomic install into that dir + `launchctl bootout` / `bootstrap` job reload |
| **brew** | `brew services` + Cellar formula | Refused before a live mutation; move the primary to sidebin first |

The script **detects venue** from the LaunchAgent, the formula, and sidebin. It
refuses a brew live cutover before a service stop.

Design: `fold/docs/designs/lastdb-minimal-downtime-cutover.md`.

Env overrides: `LASTDB_SIDEBIN_DIR`, `LASTDB_LAUNCHD_LABEL`, `LASTDB_LAUNCHD_PLIST`.
The sidebin path reloads the LaunchAgent job definition so plist environment
edits take effect; `kickstart` alone only restarts the cached definition. The
driver caps `LASTDB_HASH_GROUP_WARM_BYTES` at `4294967296` bytes before the
reload. A lower configured value remains unchanged. This keeps the full-heap
warm-cache contract within the feature-flow proof limit. The
driver verifies both staged files before either rename. It verifies the
installed hashes before the reload and during the post-install gate. A hash
failure after a rename restores both pre-cutover files before exit. The live
post-check names configured keys absent from the new process, and
`LASTDB_LIVE_CONFIG_ENFORCE=1` makes any such drift RED.

**Hot swap:** a single-process image swap still needs a worker handoff. For
near-zero client impact, run the `lastdb-proxy` from Fold PR #2091. It owns the
stable public sockets while `lastdbd` uses private worker sockets. The proxy
does not open the LastDB home, and it never permits two workers to own one
home. Dogfood and service-manager wiring remain required before deployment.

Use these worker flags when the proxy owns the public paths:

```text
lastdbd --data-dir <home> --socket-path <run>/worker.sock \
  --full-socket-path <run>/worker-full.sock
```

The cutover must stop the old worker, start the new worker, run the full
health checks, and then issue `lastdb-proxy set-target`. The proxy returns a
bounded 503 during a worker gap. The safe-upgrade receipt remains mandatory.

## Candidate data: the synthetic seed

The driver accepts `--data synthetic` or `LASTDB_SAFE_UPGRADE_DATA=synthetic`
and nothing else. `--data real` exits 2. No code path copies the primary home.

The seed is a small home that the BASELINE daemon (the binary the primary runs)
writes on a fresh empty home (`scripts/build-synthetic-home.sh`). The candidate
must read what the installed daemon wrote, so the baseline writes the seed. The
builder copies only `identity.key` and `.bootstrap_done` from the primary (two
small files, never printed), so the DEV photograph registers the same identity.
It registers the kanban and brain schemas through the apps' own `init`.
It collects all record and membership keys before one durable native batch.
The default seed has one milestone, 10 cards and 8 brain records.
The builder stops and reaps the baseline, then reboots it.
One query batch verifies every known key and every requested field.
Both stops require the exact native clean session and shutdown flush receipt.
The completion marker receives a file flush and a directory flush.
The kanban and brain CLIs use a seed-owned `HOME` (`cli-home`), because the seed
pins different schema hashes than the primary.

The seed is cached per key under `/tmp/lastdb-safe-upgrade-synthetic-<uid>/`
(override: `LASTDB_SYNTHETIC_SEED_ROOT`). The key covers the baseline bytes, the
identity hash, the live tuning flags, the kanban and brain versions, the data
sizes, and the generator version. A cache hit builds nothing. A new baseline
builds a new seed. An existing incomplete or foreign seed path refuses.
The driver never sweeps or replaces cache siblings. Counts are bounded to 64
cards and 64 Brain records for the single complete batch.
The build needs the network (schema service).

CAUTION: Keep the exact seed through every PROBE, CUTOVER and recovery consumer.
The operator closes their current and future uses before seed cleanup.
This also applies to failed builds. A failed or forced stop gives no completion proof.
The builder retains a fixed public closeout outside the owned container.
Raw app and daemon logs stay private. Each tail is limited to 64 KiB and 200 lines.
The private reason file is limited to 4 KiB.

After consumer closure, preserve that closeout and bind the exact current
container path, owner UID, mode, device and inode from its owner marker.
Use a fresh unique `LASTDB_DEV_HOME` and `LASTDB_DEV_STATE` for the cleanup tool.
Run the normal exact-container preview, then the real change:

```bash
lastdb-dev reclaim --home "$owned_seed_container" --exact-home --dry-run
lastdb-dev reclaim --home "$owned_seed_container" --exact-home
```

The opt-in route requires the native synthetic seed or trial owner marker and refuses the
primary, its descendants, or a container that contains it.
It requires the creator PID to be absent with a complete process check.
It checks canonical and macOS alias daemon arguments and complete descendant
open-file use. It refuses an incomplete process or file-use check.
It deletes only the named container and confirms its absence.
It never selects `.clone-*`, `.old-*`, other seeds or other builds.
Preserve the preview, execution and final absence result outside the container.
The file-use check is current evidence; the explicit consumer closure protects future use.
An unknown deletion result stops the sequence for review.

Each run then clones the seed into a fresh trial home under
`${TMPDIR}/lastdb-safe-upgrade-rollback-<uid>/trial-<new>-from-<old>-<ts>/` and
writes a `kind=trial` completion marker. The driver refuses an existing target
path. A clone error is RED and the error stays in an owner-only, bounded file
under the rollback root. The trial has an exact owner marker for this driver.
It stays until all Loom, proof, and recovery consumers close.
The operator then uses the same exact-container cleanup route.
The driver never selects or deletes a stale sibling by its source prefix.

The candidate boots on a separate copy of this trial home.
The candidate never boots on the live primary home. The driver checks:

- The candidate loads schemas and serves the keyed `Board` title.
- The candidate serves a read of `BoardCards` under the default board and todo column.
- The candidate memory size stays below the memory-guard limit.
- The live primary process stays the same during the candidate check.

The `BoardCards` result must contain at least one card. The `Board` title
check requires a non-empty title.

The DEV proof also clones the same trial home. It publishes one snapshot
with the exact candidate pair. The candidate CLI restores that manifest into
a new home that contains no local database data. The proof requires a complete
Cloud Off restore report before it writes the receipt. This is the cloud backup
test: it runs on the synthetic seed.

What the seed leaves out: real-data history and scale. That covers older schema
pins, re-key leftovers, unreadable schema state rows, scale-dependent behavior
(warm-set thrash, flush-lock waits, scan cost), and a crash-consistent clone of a
running node. These meet real data for the first time on the live cutover. The
cutover keeps the durability canary, the stopped flush receipt, the
live post-check and the soak. Tom accepted this trade on 2026-10-09 and again
on 2026-10-12.

The live cutover has no rollback copy of the primary. See
[Recovery point](#recovery-point-the-cloud-backup-never-a-copy-tom-2026-10-12).

## Hard rules (never skip)

0. **Never copy the primary home and never boot a node on a copy of it** (Tom,
   2026-10-12). Not for a probe, not for the DEV photograph, not for a cloud
   backup test, not for a rollback point, not with `cp -cR`. There is no
   exception. Use the synthetic seed and the cloud backup.
1. **Never** run a candidate `lastdbd` with `--data-dir` pointing at the **live**
   `~/.lastdb` until the candidate passes on a copy of the synthetic seed.
2. **Always** prepare a fresh trial home from the seed under the system temp
   directory before the candidate check. This rule also applies to a probe-only
   run. The trial home is not a rollback point; no rollback copy of the primary
   exists. For a live cutover, require a current cloud backup first, then strictly
   stop and flush the old primary.
3. **Never** restart/upgrade on a RED probe.
3b. **A read that answers fast with ZERO rows is RED, not GREEN.** The
   **row-count bar** counts the rows the Board point-read and the `kanban list
   --column todo` scan return on the candidate and on the baseline, over the
   same seed data. Baseline > 0 with candidate == 0 is a read-path regression
   and fails the probe. There is **no skip flag**, and `LASTDB_PROBE_LAT_SKIP=1`
   does not buy a pass — this is a correctness bar, not a speed bar. Added
   2026-09-03 after lastdbd 0.23.3-1535 served every kanban BoardCards read
   empty on the primary for an hour; every latency bar passed it GREEN, because
   an empty answer is the fastest possible answer.
4. **Never** kill the primary unattended outside this skill's live step; if live
   post-check fails after upgrade, **stop and restore** (binary bak, then
   `lastdb restore` of the cloud backup if the data is damaged) — do not improvise.
5. **Deployment check on the seed:** the candidate loads schemas, serves a keyed
   `Board` title, and serves a keyed `BoardCards` list on its own copy of the
   seed. The title and list must be non-empty. The primary process must not change.
6. **RSS bar (memory-guard):** settle (~45s) and sample candidate memory size
   on the copy. **RED** if peak RSS ≥
   `LASTDBD_RSS_LIMIT_MB` minus headroom (default 10%). Limit is read from
   env, then the memory-guard LaunchAgent plist, then the primary lastdbd
   LaunchAgent plist, else 16384. Before a sidebin kickstart, the script stamps
   the primary plist with that live limit so lastdbd does not boot with a lower
   binary default while the guard enforces the resident ceiling. Incident
   2026-07-22: sled-free cutover sat at ~8.5 GiB while the guard killed at 6 GiB
   -> thrash. Live post-check re-samples primary RSS the same way.
7. **Latency bar (correct-but-slow is RED):** clone **two** CoWs and boot
   candidate and baseline to identity-ready **before** any timed query.
   **Cold** = the first Board point read and the first column list after
   that daemon reaches identity-ready. **Hot** = a later sample of that
   same operation after it has already finished, and only when the sample
   opens no file. A sample that opens a file is `nothot` and the pair is
   dropped. The hot read is one HashRangeKeys batch of the keys that the
   column list returned. The first batch is not hot. The driver measures six
   candidate and baseline samples in adjacent pairs. It alternates which
   daemon runs first and records each sample in the probe log. Compare
   **like with like only**: cold vs cold, hot vs hot. A mixed pair (cold
   candidate vs hot baseline, including the 2026-08-26 354 ms vs 50 ms
   shape) must not RED. Pairs where both times are under
   `LASTDB_PROBE_LAT_FLOOR_MS` (default **250 ms**) are noise, not a ratio.
   **RED** if a like-to-like candidate time > `LASTDB_PROBE_LAT_RATIO`
   (default 3×) **max(same-thermal baseline, floor)** — a sub-floor
   baseline is noise-level and never a raw denominator (2026-08-31 cold
   point 549 ms vs 168 ms is 2.2× floored, GREEN) — or exceeds
   `LASTDB_PROBE_LAT_ABS_MAX_MS` (20 s) **when no baseline is measurable**,
   or is unmeasurable on the candidate while the baseline measured.
   **Correlated / aggregate term (2026-08-05) uses the two hot reads:**
   RED when (a) **all** measurable hot ops regress at ≥
   `LASTDB_PROBE_LAT_CORR_RATIO` (default **1.4×**), or (b) the **geometric
   mean** of hot cand/base ratios exceeds `LASTDB_PROBE_LAT_GEO_MEAN_MAX`
   (default **1.5×**). Need at least `LASTDB_PROBE_LAT_CORR_MIN_OPS`
   (default 2) measurable pairs. Pure helper: `scripts/latency-bar-checks.sh`.
   Probe nodes boot with the live LaunchAgent's `LASTDB_*` tuning; peak RSS
   is sampled under the hot load. Skipping the whole bar
   (`LASTDB_PROBE_LAT_SKIP=1`) or only the correlated term
   (`LASTDB_PROBE_LAT_CORR_SKIP=1`) requires Tom's explicit clearance. Live
   post-check re-times **hot point-read and the hot batch read** vs the
   candidate's own hot probe numbers (`LASTDB_LIVE_LAT_ENFORCE=1` makes
   either RED). The bar also checks correlated hot-operation regressions and
   avoids a cold sub-floor baseline as a raw ratio denominator.
7c. **Candidate persist status:** the candidate serves `/api/status` on
   the real copy. The driver requires both persist failure gauges to exist
   and equal zero. This check reads status. It does not write a scratch card.
   The memory guard and live status checks remain required.
8. **Candidate-class bar (no debug / dirty / oversized):** before backup or
   probe, refuse candidates that look like a Cargo **debug** build
   (`…/target/debug/…`), a **-dirty** version stamp (uncommitted tree at
   build), or a binary **>1.5×** the incumbent size (debug/unstripped).
   Incident 2026-08-01: primary was cut over to
   `…/fold-kanban-mhr-delete/target/debug/lastdbd` (`0.23.2-258-…-dirty`);
   exclusive CoW latency looked GREEN while live contended lists collapsed.
   Prefer `cargo build --release` (or a release artifact) from **origin/main**
   / a soaked canary SHA — never a feature-worktree debug binary. Tom-only
   overrides: `LASTDB_ALLOW_DEBUG_CANDIDATE=1`,
   `LASTDB_ALLOW_DIRTY_CANDIDATE=1`, `LASTDB_ALLOW_LARGE_CANDIDATE=1`,
   `LASTDB_CANDIDATE_SIZE_RATIO` (default 1.5). Brain:
   `incident-20260801-debug-worktree-lastdbd-primary-cutover-latency`. Promote
   from `origin/main`, never from a feature branch.
9. **No primary mutation check:** the candidate reads the baseline-written
   synthetic seed. The primary remains unchanged during the candidate checks.
   The driver does not create false CAS writes or scratch records on the primary.
10. **Binary-pair bar (lastdb + lastdbd):** before backup/probe, require a
    sibling `lastdb` CLI next to the candidate `lastdbd` and require both
    binaries to report the same version. Sidebin live install copies both
    binaries from that same artifact and the post-check fails RED if the
    installed live CLI/daemon pair is skewed.
11. Do not claim “primary stopped” unless this script actually stopped the
   supervisor for that venue.
12. **Cloud recovery point and stopped flush:** before the old daemon stops, the
    driver requires a current cloud backup (see Recovery point) and writes
    `restart-intent.json` for the exact old session. The daemon must stop
    without a forced kill and write its exact flush receipt. The driver checks
    that receipt and the clean session. It makes no copy of the primary. The
    driver does not write a canary record.
13. **Exact-candidate DEV photograph (required before live cutover — Tom
    2026-08-19):** the CUTOVER pass clones the fresh trial copy from step 1.
    It does not clone live `~/.lastdb` again. The versioned execution-key digest covers the source
    OID, canonical paths, binary hashes, and binary versions. The child graph
    checks the tuple before PROBE and CUTOVER.

    The proof removes both sockets, `current-session.json`, the copied device
    ID, `laststore_backup_known_present.json`,
    `laststore_backup_manifest.json`, every `cloud_sync.json*` file, hidden
    `.cloud_sync.json.tmp*` residue, and the `.cloud_resume_required`,
    `.cloud_resume_requested`, and `.cloud_resume_ready` markers. It does this
    before DEV connect. It unsets
    `LASTDB_HOME`, `FOLDDB_HOME`, and `FOLD_SYNC_DEVICE_ID` for connect, daemon
    start, and snapshot.

    The candidate deployment check reads a separate copy of the same trial
    copy. It checks the real primary process before and after the read.

    The proof reads `lastdb-restore-probe-invite-dev-20260720` from
    LastSecrets. It pipes the value directly to the paired CLI through stdin.
    The CLI uses `--env dev --invite-code-stdin --use-existing-identity`.
    It does not accept an API URL. After connect, the proof requires one
    owner-only active config for the exact compiled DEV URL. No
    `cloud_sync.json*` backup can remain.

    The exact daemon then starts on the CoW. The exact CLI runs a bounded
    `cloud snapshot --json` command. Only that command's report can prove the
    manual CAS update. The response must use the sealed top-level `report`,
    `user_hash`, and `manifest_cache` fields. The manifest-cache path must name
    the new isolated cache. The report must contain a positive counter, an
    equal CAS counter, and a manifest SHA-256. The proof reads the copied
    `laststore_high_water.json` store UUID. It derives the 64-hex
    `cloud_db_hash` as SHA-256 of `laststore-db:<store_uuid>`. Both report keys
    must use that scope:
    `<cloud_db_hash>/backup/manifests/<manifest_sha256>` and
    `<cloud_db_hash>/backup/latest`. The top-level 32-hex `user_hash` proves
    the envelope identity only. The proof checks the fresh DEV device ID again
    after the snapshot. Each snapshot attempt has
    a 900-second command deadline by default
    (`LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_TIMEOUT_SECS`).

    The Loom step starts each safe-upgrade driver in its own process group. It
    reserves 45 seconds for owned cleanup, at least 900 seconds for CUTOVER recovery,
    and 15 seconds for the outer Loom deadline. It forwards external signals
    to the group and always reaps an abnormal driver tree. On a CUTOVER stop,
    a separate process group reads the private recovery state. It waits up to
    330 seconds by default for the exact old process to exit. The allowed
    maximum is 360 seconds. It does not kill or bootout
    that process during its flush drain. A loaded job with no PID receives a
    plain kickstart. An unloaded old job restarts with the saved pair. A failed
    live swap restores that pair before the reload. Recovery
    requires socket health and the supervised listener PID before it returns.
    A failed recovery retains the mode-600 state for exact manual recovery.
    The 900-second default covers the 360-second old-process wait, a
    180-second bootout wait, 112 seconds of default bootstrap retry delays,
    45 seconds of socket health, 180 seconds for binary checks, and 10 seconds
    for the wrapper's TERM/KILL reserve. These parts total 887 seconds. The
    wrapper increases the default when custom wait or grace values need more
    time. It refuses an explicit reserve below that sum before cutover starts.

    The exact CLI then restores this DEV manifest into a new home with no local
    database data. The restore must report `replay_tail`, exact manifest and
    database hashes, verified source scope, remote read-only access, and Cloud
    Off. The target must hold the paused cloud config and resume-required marker.

    The owner-only v4 receipt belongs to one Loom execution and expires after
    one hour. It records the exact source, pair paths, pair hashes, pair
    versions, DEV URL, CoW path, primary path, fresh trial copy path, snapshot report, snapshot user
    hash, cloud DB hash, manifest object key, exact manifest-cache path,
    source-free restore proof, and isolation facts. The proof retains a bounded
    owner-only restore report with a digest in the receipt. The gate reads that
    report again before it accepts the receipt.

    The normal driver requires `--retain-for-cloud-cleanup`. The helper keeps
    its exact owned home under `${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/dev-photo/`.
    The short home path preserves the native socket cap. Before GREEN, the helper
    stops and reaps its exact candidate. It writes an immutable, private
    `${receipt}.cloud-cleanup.json` handoff with root and credential-file metadata.
    The metadata helper never reads the credential, seed, or device bytes.
    A failure after the first DEV connect attempt also keeps the home. Its
    private RED handoff has unknown cloud scope. A failed handoff keeps the
    home and cannot authorize cleanup. A failure before cloud access deletes
    the owned home as before. The standalone helper defaults to no retention;
    the normal cutover gate rejects that receipt.

    The handoff stays pending until the exact cloud cleanup consumer closes.
    The consumer sends a bounded FIFO attestation to:
    `python3 -I <skill>/scripts/dev-photograph-cleanup-handoff.py release --receipt <receipt>`.
    The strict attestation contains `schema`, `consumer_closed`,
    `expected_handoff_sha256`, and `server_closure_refs`. The schema is
    `lastdb.dev-photograph.cloud-cleanup-consumer-closed.v1`. Each of 1–16
    references names an exact protected proof file and its SHA256.
    The consumer attests that all current and future access-home uses close.
    The helper checks the references; it does not infer provider closure.
    It creates a closed record and a truthful `synthetic-photograph` marker.
    An incomplete release stays pending and requires review; it has no retry.
    The operator then uses `lastdb-dev reclaim --home <photo-parent> --exact-home --dry-run`,
    followed by the same command without `--dry-run`. Both checks require
    unchanged private handoff and file metadata, exact released proof references,
    no creator process, no open descendant files, and no primary overlap.
    A normal home reclaim or a TTL sweep cannot delete a retained photograph.
    The gate rejects missing, duplicate, or unknown fields. It also
    rejects a legacy receipt, a stale time, a future time, another candidate,
    a production URL, or an overlapping home. Skip
    (`LASTDB_PROBE_DEV_STAMP_SKIP=1`) needs Tom's clearance. The standing rule is
    to probe an ephemeral copy first, never live `~/.lastdb`.

    On RED, the helper writes an owner-only evidence bundle under
    `~/.local/state/last-stack/lastdb-safe-upgrade/dev-photograph-failures/`.
    The bundle states the control-flow phase, attempt, timeout, and snapshot
    exit code. It records manifest-cache presence as an observation, never as
    proof that the current attempt passed CAS. It also stores a bounded,
    sanitized daemon tail and the final snapshot-attempt stderr tail. Daemon
    text can include continuous-publisher or earlier-attempt events, so it does
    not change the reported phase. The helper removes raw logs with the CoW.
    Before cleanup, it also reduces restore stdout into `restore.error.json`.
    This file contains only the validated `lastdb.restore.error.v1` stage,
    code, and optional numeric and closed replay diagnosis fields. The reducer
    rejects duplicate or unknown fields, unsupported enums, and changed files.
    An absent, invalid, or unavailable report produces a fixed `UNKNOWN` record.
    The helper never copies raw restore stdout or private error detail.
    It never stores the raw snapshot envelope, credentials, device IDs, user
    hashes, object digests, or full CoW paths. The driver prints the helper's
    sanitized failure output before its final RED verdict.
14. **LaunchAgent config parity:** sidebin cutover uses `bootout` then
    `bootstrap` so the plist job definition is re-read. It falls back to
    `kickstart -k` only when those launchctl verbs are unavailable. Before the
    reload, the cutover caps the full-heap warm-cache setting at
    `4294967296` bytes. After the
    new daemon is serving, compare plist `EnvironmentVariables` key names with
    the running process environment (never print values). Missing keys are a
    loud WARN; `LASTDB_LIVE_CONFIG_ENFORCE=1` makes them RED.
15. **Bootstrap retries — an EIO is a race, not a verdict.** A `bootstrap`
    right after a successful `bootout` can fail with
    `Bootstrap failed: 5: Input/output error`. Treating that as terminal left
    the primary UNLOADED three times; the third, unattended, ran 4h34m and
    took brain, board, Situations, LastGit CI and every routine down with it.
    So the driver retries `bootstrap` with backoff — `2 5 15 30 30 30`
    seconds, override with `LASTDB_LAUNCHD_BOOTSTRAP_RETRY_DELAYS`.

    After `bootout`, the helper waits until the old service disappears before
    it calls `bootstrap`. The wait has a 30-second default bound. A loaded
    service during this interval still belongs to the old job. It cannot prove
    a successful reload. An incomplete removal fails before a new bootstrap.

    CAUTION: launchd returns that SAME EIO for a job that is *already*
    bootstrapped. The exit code cannot tell recovery from outage. Success is
    decided by `launchctl print <domain>/<label>`, never by the exit status.

    Two more consequences, both load-bearing:
    - A `bootout` that fails while the job is **already unloaded** is not an
      error — that is the state a repair run starts from, so the driver logs
      `LASTDB_LAUNCHD_BOOTOUT=already-unloaded` and continues. A `bootout`
      that fails while the job is still loaded stays fatal.
    - When every retry is exhausted the driver prints
      `LASTDB_LAUNCHD_RECOVERY=<the exact launchctl bootstrap command>`,
      releases `.cutover.lock`, and pages through `ra notify --priority high`
      before it dies. An unloaded primary is a total factory outage, not a log
      line.

15b. **Strict old-primary stop.** The driver moves the old program path aside
    so KeepAlive cannot respawn. It sends `launchctl kill SIGTERM` and waits up
    to 300 seconds (`LASTDB_PRIMARY_GRACEFUL_STOP_WAIT_SECS`). A timeout fails
    the cutover without a forced kill. The driver requires a matching flush
    receipt and clean session before it replaces the binary pair. It makes no
    copy of the stopped primary. The reload
    then bootstraps the new definition. Log key: `LASTDB_LAUNCHD_PRESTOP`.
    Brain: `papercut-lastdbd-primary-launchagent-exit-timeout-5s-sigkills-shutdown-drain-20260924`.

16. **Leftover socket is not up.** After `bootout`, a leftover `folddb.sock`
    inode still passes `[ -S sock ]` with no listener. Waiting only for the
    inode reports `socket up after 0s`, then the live `/health` poll spends
    its whole budget on a dead file (2026-08-26: bootstrap EIO, leftover sock
    from hours earlier, `VERDICT: RED`). The driver unlinks that leftover
    **only when no process holds it**, then waits until a listener pid **and**
    `/health` are ok. Helper: `scripts/live-socket-health.sh`. A socket inode
    without a listener is not proof of service health.
17. **A nohup start is not GREEN.** After bootout, if `launchctl print` cannot
    find the primary job, the driver retries `bootstrap` so KeepAlive owns
    lastdbd. An unattended bootstrap of an unloaded primary is allowed when
    `launchctl print` verifies the job. A leftover
    listener plus `nohup lastdbd --data-dir ~/.lastdb` may restore `/health`,
    but `VERDICT: GREEN` is refused until print succeeds and the live pid is
    that job. `LIVE_CONFIG_DRIFT` still names missing plist env keys.

## Do this, in order

### A. Use Loom for every live cutover

Start the graph with an explicit release candidate. The launcher reads the
full candidate source commit. It hashes the sibling `lastdbd` and `lastdb`
files. The default fixed-length `safe-upgrade-v7-<digest>` key includes the gate
protocol version. Its digest covers the source OID, both canonical paths, both
binary hashes, and both versions. The graph checks the complete tuple before
PROBE and CUTOVER.

```bash
last-stack-safe-upgrade-loom \
  --candidate /path/to/release/lastdbd \
  --source-git-oid <full-lastdb-commit>
```

For the one-client rescue, Tom approved the explicit `--zero-live-soak` option.
Add it to this command only for that cutover. The option removes the 300-second
minimum after the live cutover. The driver still requires a
fresh GREEN status sample before it ends.
The option uses a separate Loom execution key. The default remains 300 seconds.

The sibling `lastdb` binary and the bundle manifest must be next to `lastdbd`.
An equal candidate finishes as a no-op. An older, divergent, or unknown source
commit fails closed. A byte change needs a new execution key. Do not reuse an
execution for another pair.

The launcher does not write to LastDB before or during the run. The local
journal path defaults to
`~/.local/state/last-stack/loom/recovery/executions.jsonl`; set
`LAST_STACK_LOOM_LOCAL_RECOVERY_DIR` for a different state directory.

An exact-candidate live cutover requires the sidebin venue. The driver refuses
the brew venue before a durable write or a service stop. Brew can resolve an
artifact whose bytes differ from the photographed pair.

The nightly path uses the parent graph:

```bash
last-stack-canary-loom --start --oid <full-lastdb-main-commit>
```

The parent graph builds the candidate and calls `lastdb-safe-upgrade` as a Loom
child. Do not call the cutover driver from a routine or an agent.

`last-stack-canary-loom --recover` accepts only a complete protocol-v7 child
receipt. Recovery rechecks both canonical paths, versions, hashes, the tuple
digest, the successful nodes, and the installed live pair. A legacy receipt
cannot record the dogfood ledger.

### B. Use the driver only for probe-only work

Resolve the skill root (first hit wins), then run the script:

```bash
skill_root=""
for c in \
  "${LASTDB_SAFE_UPGRADE_ROOT:-}" \
  "$HOME/.last-stack/skills/lastdb-safe-upgrade" \
  "$HOME/.codex/skills/lastdb-safe-upgrade" \
  "$HOME/.claude/skills/lastdb-safe-upgrade" \
  "$HOME/.grok/skills/lastdb-safe-upgrade" \
  "$HOME/.factory/skills/lastdb-safe-upgrade" \
  "$HOME/.config/opencode/skills/lastdb-safe-upgrade"
do
  [ -n "$c" ] && [ -f "$c/scripts/safe-upgrade-lastdb.sh" ] && skill_root=$c && break
done
[ -n "$skill_root" ] || { echo "lastdb-safe-upgrade skill not installed; run ~/.last-stack/setup --host auto" >&2; exit 1; }
driver="$skill_root/scripts/safe-upgrade-lastdb.sh"

# Probe on the synthetic seed. Do not install on the primary.
bash "$driver" --probe-only

# Explicit candidate probe.
# MUST be a release build with sibling /path/to/release/lastdb beside it —
# never …/target/debug/lastdbd or a -dirty stamp.
bash "$driver" --candidate /path/to/release/lastdbd --probe-only

# Bottle version probe only
bash "$driver" --version 0.22.8 --probe-only

```

`--check-dev-stamp` is an internal diagnostic. It fails without the complete
Loom tuple, execution ID, and `LASTDB_SAFE_UPGRADE_EXPECTED_CLONE_SOURCE` path.
Do not use a copied receipt as a manual approval.

Or, after last-stack is installed:

```bash
bash ~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh --probe-only
```

The script:

| Step | What |
|------|------|
| Preflight | Primary home exists, identity.key present, live `/health` ok (if socket up) |
| Resolve candidate | `brew update` / `--version` tarball / `--candidate` |
| **1. Trial home** | Every run clones the cached synthetic seed (never the primary) under `${TMPDIR}/lastdb-safe-upgrade-rollback-<uid>/trial-<new>-from-<old>-<ts>/`. A clone error is RED. The trial home is not a rollback point. |
| **0. Class** | Refuse `target/debug`, `-dirty` version, size ≫ incumbent (before any probe) |
| **0b. Candidate data** | Build or reuse the synthetic seed (baseline writes it); candidate copies come from the trial home. |
| **2. Candidate check** | Boot the exact candidate on a copy of the synthetic seed. Require schemas, the keyed Board title, a keyed BoardCards response, stable primary PID, and memory size below the guard. The driver checks candidate persist status, read latency, and record counts on synthetic seed copies. |
| Detect venue | sidebin vs brew |
| **2c. DEV photograph proof** | The exact pair clones the trial copy, scrubs production state, connects the copied identity to DEV, and publishes a snapshot. The exact CLI restores that manifest from DEV into a source-free home. The fresh v3 receipt must match this Loom execution, this run's trial copy, and the retained restore report. |
| **2d. Meter restart bar** | Read live status before restart. Refuse a `keep_small` plane above 1.5 GiB or a failed persist lane. The 2 GiB cold-group cap can prevent both new and old binaries from booting. |
| **3. Live** | Refuse brew. For sidebin, write the boot-ledger restart intent. Stage and check both candidate files. Require a current cloud backup. Stop the old daemon without a forced kill. Require its exact flush receipt and clean session. No copy of the primary is made. Then replace the saved binary pair and reload the LaunchAgent job. |
| **4. Post-check** | Exact installed pair hashes, live `/health`, schemas > 0, Board title, **LaunchAgent config parity** (missing process env keys WARN; `LASTDB_LIVE_CONFIG_ENFORCE=1` → RED), **LaunchAgent loaded + live pid is that job** (a nohup `--data-dir` start is RED), **live peak RSS** vs guard, **live point-read + batch-read latency** vs the candidate's probe numbers (WARN; `LASTDB_LIVE_LAT_ENFORCE=1` → RED); cutover_s + latency in notice |
| **4a. Live soak** | Keep checking for at least five minutes by default. `--zero-live-soak` removes only that minimum. At least one fresh GREEN status sample remains required. Check persist failures, write access, and meter size on each status sample. If Cloud Sync was on before cutover, require the cloud frontier to stay at or beyond its pre-live value. A failed or stale bar is RED. |
| **4b. Release** | The exact owned seed and trial stay through all Loom, proof, and recovery consumers. After consumer closure and driver exit, the operator preserves the public proof and uses the exact-container cleanup route. No sibling sweep runs. |
| RED | Exit 1. No copy of the primary exists; recovery is the saved binary pair, then `lastdb restore` of the cloud backup. A class, probe or cloud-recovery-point failure leaves the primary unchanged. |

### Search receipts in a probe copy (history)

This section records why the clone helper skips one path: `apps/search/inbox/done`.
The synthetic seed has no such path, so the skip does nothing today. It stays
for any caller that clones a home that holds it. The path holds the Search
app's processed batches (217,761 files on 2026-10-08). The daemon only writes
the Search inbox. It never reads `done/`, and a probe never runs the Search app.
The papercut measured about 13 minutes for one clone and about 8 minutes for
one removal. On 2026-10-08 one filtered clone of the live home took 125
seconds and its removal took 34 seconds. An earlier run of an equal filter took
263 and 207 seconds, so expect a wide range. I did not time a full clone in
those runs.

### Release a retained copy of the primary from an older flow

Older runs of this skill could leave a trial home or a `pre-*` rollback point that
is a COPY OF THE PRIMARY. The driver refuses to start while one remains, and it
never makes one now. Release it with the supported helper after the primary is
healthy. The helper requires a supervised socket listener and an exact current
session. It checks one direct child of the rollback root. The default does not
delete. `--execute` removes that one copy with a 600-second limit. A timeout can
leave a partial copy. Run the same command again after the primary check.

```bash
export LASTDB_ROLLBACK_ROOT=/path/to/lastdb-safe-upgrade-rollback-UID
helper="$HOME/.last-stack/skills/lastdb-safe-upgrade/scripts/cleanup-retained-upgrade-copy.sh"
bash "$helper" --copy "$LASTDB_ROLLBACK_ROOT/trial-CANDIDATE-from-CURRENT-YYYYMMDDTHHMMSSZ" \
  --expect-primary-pid PID --expect-primary-start-ts START_TS \
  --launchd-label LABEL
# After READY, repeat the command with --execute.
```

Read the current PID and start time from `~/.lastdb/current-session.json`. This
helper refuses published rollback points; use `scripts/cleanup-retained-rollback.sh`
for a `pre-*` point from the former live-copy flow (same READY check, then
`--execute`). A release can free less physical disk than `du` reports because APFS
clones can share blocks.

### C. If the graph or script is missing or fails open

Do **not** hand-roll a weaker path. Fix the graph or script, or stop. If the
skill is missing on this harness, run `~/.last-stack/setup --host auto` (clean
install tree only — never dirty `~/.last-stack` by hand).

### D. Report to Tom

Always print:

- Current version → candidate version  
- Venue (sidebin / brew)  
- Candidate data: `PROBE_DATA: synthetic`, a copy of the cached seed (never the primary)
- Recovery point: cloud `published_through` before the stop (no copy of the primary exists)
- Probe GREEN/RED (+ first Board title if green)  
- **Probe peak RSS MiB vs memory-guard limit / fail_at**  
- **Latency: cold Board/column reads and hot Board/batch reads, candidate vs baseline (ms) + boot seconds.** The hot batch uses the receipt key `lat_hot_scan_ms`. A `nothot` pair is dropped.
- Whether live upgrade ran + cutover seconds + live peak RSS + live point-read ms  
- Recovery commands (the script prints them): binary pair, then `lastdb restore`

Optional: append a one-liner to brain reference `lastdb-safe-upgrade-log` via
`brain append` (non-secret metadata only).

After a GREEN **live** upgrade the script posts a Situations **notice** so other
agents can attribute socket blips to the upgrade instead of opening a false
incident.

This driver does not create host-track registry rows. App installs may wait for the separate registry process.

## Reading results

| Output | Meaning | Action |
|--------|---------|--------|
| `VERDICT: GREEN` | Probe + live cutover + live post-check passed | Done |
| `VERDICT: GREEN_PROBE_ONLY` | Probe passed; primary still on old version | Start `last-stack-safe-upgrade-loom` with the candidate and source commit if Tom wants the upgrade |
| `VERDICT: ALREADY_CURRENT` | Already on candidate/stable | Nothing to do |
| `VERDICT: RED` | A candidate, DEV restore, cloud recovery point, stopped flush, live health, or cloud check failed. | Stop the upgrade. Recover with the saved binary pair, then `lastdb restore` if the data is damaged. |


## Rollback

**Binary only (sidebin — preferred first try):**

Copy to a temp path in the same dir, ad-hoc re-sign, clear quarantine, assert
the binary actually runs, and only then **atomically rename** it into place:

```bash
B=~/.lastdb/bin-with-upload-cap
cp -a $B/lastdbd.bak-pre-<ver>-<ts> $B/.lastdbd.rollback.tmp
codesign --force --sign - $B/.lastdbd.rollback.tmp
xattr -c $B/.lastdbd.rollback.tmp
$B/.lastdbd.rollback.tmp --version    # MUST print a version before proceeding
mv -f $B/.lastdbd.rollback.tmp $B/lastdbd
launchctl kickstart -k gui/$(id -u)/com.REPLACE.lastdbd-primary-506
kanban list
```

> **Never `cp -a` straight onto the live `lastdbd` path.** An in-place copy keeps
> the destination **inode**, macOS still has the cached code signature for that
> inode from the binary that was just running, the new bytes do not match it, and
> the kernel kills every exec with `OS_REASON_CODESIGNING` — launchd sits in
> `state = spawn scheduled` and never runs.
>
> This failure is silent in the obvious check: `lastdbd --version` prints
> **nothing** and returns no visible error, while `shasum -a 256` on the
> installed file **matches the backup exactly**. Correct bytes + healthy sha +
> silent exec is the signature. It cost several minutes of primary downtime on
> 2026-07-27.
>
> The `--version` line above is the assertion that catches it — run it on the
> temp path, before the rename, and never trust sha alone. The forward install
> in `safe-upgrade-lastdb.sh` was always safe because it writes a new file and
> renames; only this hand-run rollback used the in-place form, which is exactly
> backwards from where you want the sharp edge.
>
> The rollback must copy to a new inode. In-place replacement can preserve a
> cached code signature and make launchd kill every exec.

**Data (only if the home is corrupted and the run is RED).** No copy of the
primary exists. Restore the latest cloud backup into a fresh home, check it, then
swap the homes. Keep the broken home until the restored node serves real cards.

```bash
# stop the primary supervisor first
lastdb restore --into ~/.lastdb.restored-$(date +%Y%m%dT%H%M%S) --env prod --json
# check the restored home with a node pointed at it (never the live path), then:
mv ~/.lastdb ~/.lastdb.broken-$(date +%Y%m%dT%H%M%S)
mv ~/.lastdb.restored-<ts> ~/.lastdb
# restart supervisor (kickstart or brew services start)
kanban list   # must show real cards
```

## Related skills / harnesses

- **`brain-doctor`** — if primary is already wedged **before** upgrade; fix health first.
- Design: **`lastdb-minimal-downtime-cutover`** (venue + optional proxy phase).

## Never

- `brew upgrade lastdb` as a one-liner without this skill when the user cares about data.
- Run `safe-upgrade-lastdb.sh` without `--probe-only` outside a Loom execution.
- Use the brew venue for an exact-candidate live cutover. Use sidebin so the
  installed files equal the photographed pair.
- Start a second safe-upgrade while another probe or cutover owns the host-wide
  safety lock. Wait for the first owner to exit. The lock covers rollback
  cleanup, the synthetic probe, and the live cutover.
- Point candidate `--data-dir` at live `~/.lastdb` "just to see".
- Copy `~/.lastdb` (also with `cp -cR`) or boot a node on a copy of it, for any probe,
  cloud backup test, smoke test or bar (Tom, 2026-10-12). Use the synthetic seed.
- Set `LASTDB_BUILD_CONFLICT_STAMP_ON_COPY` on the primary LaunchAgent, or copy the ephemeral copy's conflict stamp onto the primary home.
- Read a probe's fast, empty query result as a pass. Count the rows.
- Upload a CoW/ephemeral photograph into the primary's **production** backup
  home, or treat a mock object-store "stamp" as the DEV photograph gate.
- Reuse a DEV photograph receipt from another execution, source, daemon, or
  CLI. A matching version does not prove matching bytes.
- Use `LASTDB_PROBE_DEV_STAMP_SKIP=1` to skip the final binary-binding check.
  The flag skips only the DEV receipt.
- Keep `current-session.json`, either LastStore backup cache, a copied device
  ID, or any `cloud_sync.json*` residue in the DEV CoW.
- Put an invite, API key, identity seed, or recovery phrase in output, logs,
  receipts, or files outside the one new CoW credential file.
- Pass `--candidate …/target/debug/lastdbd` or any `-dirty` build to "get a feature SHA on primary" — rebuild `--release` from origin/main (or a soaked canary) instead (incident 2026-08-01).
- Put a rollback or probe copy under `$HOME` (`~/.lastdb-backups`,
  `~/.lastdb-test-copies`, sibling `.bak` homes). Existing legacy trees are a
  separate human-owned cleanup decision; the driver neither uses nor sweeps
  them.
- Restart/kill primary on RED.
- Call `brew upgrade` when formula is not installed and primary is sidebin.
- Assume the skill lives only under `~/.claude/skills` — Codex/Grok/Factory use their own skills dirs; last-stack setup keeps them in sync.

## Background

Incidents: 2026-07-13 wrong-key / 0.22.6 decrypt brick; 2026-07-16 brew upgrade
failed because primary is sidebin+launchd not brew services; 2026-07-21 Codex
could not find this skill because it was Claude-only (not in last-stack);
2026-07-22 post-cutover RSS ~8.5 GiB vs memory-guard 6 GiB thrash (RSS bar added);
2026-07-25/27 the 0.23.1 cutover passed correctness + RSS while scan reads ran
5-20x slower (HashGroup warm-set thrash) and the read path amplified writes --
the live primary was the first place anyone noticed (latency bar added). Brain:
`lastdb-0231-hashgroup-scan-warmset-thrash-read-regression`.
2026-08-01 primary cut over to a feature-worktree **Cargo debug** binary
(`…/target/debug/lastdbd`, `…-dirty`); exclusive CoW probe GREEN, live lists
multi-second→60s until bak rollback (candidate-class bar + live scan post-check
+ lower latency floor). Brain:
`incident-20260801-debug-worktree-lastdbd-primary-cutover-latency`.
2026-08-05 canary `0.23.3-canary.20260801` passed per-op 3× while slower on
every axis (1.6–2.4×) — a 4-day git rollback promoted as a semver "upgrade";
The correlated latency term and source ancestry checks address the read regression and source error.
