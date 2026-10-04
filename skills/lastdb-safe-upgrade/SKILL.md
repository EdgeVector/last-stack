---
name: lastdb-safe-upgrade
description: |
  REQUIRED path for ANY primary LastDB Mini version change. Safely upgrade
  Tom's primary lastdbd so the live brain is never the first place a bad binary
  fails. ALWAYS: (1) one ephemeral CoW rollback point outside $HOME, (2) boot the NEW binary
  only against an ephemeral/CoW copy (never live home first), (3) require GREEN
  real-data reads AND RSS under the memory-guard AND the latency bar (real
  workloads timed vs the current binary — correct-but-slow is RED) AND the
  key-cap bar (under LASTDB_RESIDENT_KEY_CAP=100 the logical resident set
  keeps its key count within budget and purges; eviction is measured in keys,
  so there is no byte footprint bar) AND the
  CAS mutation bar (candidate enforces `/api/mutation` `expected` — false
  precondition → 409; LastGit ref/CI CAS depends on it), AND a GREEN
  **DEV photograph stamp** for the exact Loom source, daemon bytes, and CLI
  bytes (a new ephemeral/CoW copy uploads the photograph to DEV and CAS-flips
  backup/latest; never use the production backup home or live `~/.lastdb`), (4) only
  then an exact sidebin+launchd live install + post-check + Situations notice.
  The driver rejects brew before a live mutation because brew can install
  unphotographed bytes. The **durability
  canary** bracketing the restart (sentinels must return a durable receipt
  before cutover, or arm `queued+readback` when the old daemon rejects the
  durable field with HTTP 400; post-cutover nonce read-back is still
  mandatory — a stale nonce is RED; no skip flag). Use when Tom says "upgrade
  lastdb", "brew upgrade lastdb", "safe upgrade", "update my brain/database
  binary", "can I upgrade to 0.22.x", "don't brick my data", "new bottle/release",
  or whenever an agent would otherwise brew-upgrade or point a candidate lastdbd
  at ~/.lastdb. Standing rule: probe an ephemeral copy first, never live ~/.lastdb.
  Distinct from lastdb-smoke-test (probe-only, no upgrade). Design:
  fold/docs/designs/lastdb-minimal-downtime-cutover.md
---

# lastdb-safe-upgrade — never brick the primary; never take it down first

Tom's primary brain is `~/.lastdb` (~multi-GB). Past upgrades have bricked real
data. **Standing rule (Tom, 2026-07-14):** every version change uses this skill so
Tom does **not** experience primary-brain downtime as the first feedback that a
release is broken — fail on the ephemeral copy; keep live on last known-good until
GREEN. The candidate must pass on an ephemeral copy before the primary changes.

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

## Live venue (important — 2026-07-16)

Primary can use either supervisor, but exact-candidate live cutover supports
only sidebin:

| Venue | How primary runs | Live install |
|-------|------------------|--------------|
| **sidebin** (Tom’s default) | LaunchAgent → `~/.lastdb/bin-with-upload-cap/lastdbd` | Atomic install into that dir + `launchctl bootout` / `bootstrap` job reload |
| **brew** | `brew services` + Cellar formula | Refused before a live mutation; move the primary to sidebin first |

The script **detects venue** from the LaunchAgent, the formula, and sidebin. It
refuses a brew live cutover before the durability canary or a service stop.

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

## Hard rules (never skip)

1. **Never** run a candidate `lastdbd` with `--data-dir` pointing at the **live**
   `~/.lastdb` until a probe against a **copy** is GREEN.
2. **Always** create exactly one ephemeral CoW rollback point under the system
   temp directory. Release it on GREEN (including GREEN probe-only or operator
   abort); on RED retain it for the printed TTL, owned by the next safe-upgrade
   run, which reclaims it before creating another. A separate cleanup-only
   helper can release one named RED point after it proves the primary never
   restarted or changed build. Never write rollback copies under `$HOME`.
3. **Never** restart/upgrade on a RED probe.
3b. **A read that answers fast with ZERO rows is RED, not GREEN.** The
   **row-count bar** counts the rows the Board point-read and the `kanban list
   --column todo` scan return on the candidate and on the baseline, over the
   same CoW data. Baseline > 0 with candidate == 0 is a read-path regression
   and fails the probe. There is **no skip flag**, and `LASTDB_PROBE_LAT_SKIP=1`
   does not buy a pass — this is a correctness bar, not a speed bar. Added
   2026-09-03 after lastdbd 0.23.3-1535 served every kanban BoardCards read
   empty on the primary for an hour; every latency bar passed it GREEN, because
   an empty answer is the fastest possible answer.
4. **Never** kill the primary unattended outside this skill's live step; if live
   post-check fails after upgrade, **stop and restore** (binary bak and/or data
   retained rollback point) — do not improvise.
5. Probe bar = smoke bar: identity decrypts, `/api/schemas` > 0, `Board` query
   returns real **title values** (counts alone are not proof).
6. **RSS bar (memory-guard):** after data-plane GREEN, boot candidate again on a
   CoW copy, settle (~45s), sample peak RSS. **RED** if peak RSS ≥
   `LASTDBD_RSS_LIMIT_MB` minus headroom (default 10%). Limit is read from
   env, then the memory-guard LaunchAgent plist, then the primary lastdbd
   LaunchAgent plist, else 16384. Before a sidebin kickstart, the script stamps
   the primary plist with that live limit so lastdbd does not boot with a lower
   binary default while the guard enforces the resident ceiling. Incident
   2026-07-22: sled-free cutover sat at ~8.5 GiB while the guard killed at 6 GiB
   -> thrash. Live post-check re-samples primary RSS the same way.
7. **Latency bar (correct-but-slow is RED):** clone **two** CoWs and boot
   candidate and baseline to identity-ready **before** any timed query.
   **Cold** = first Board point-read (and scan, if measured) after that
   daemon reaches identity-ready. **Hot** = median after settle plus one
   discarded warmup sample on that same daemon. Write is hot-only. Compare
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
   **Correlated / aggregate term (2026-08-05) uses the HOT triple only:**
   RED when (a) **all** measurable hot ops regress at ≥
   `LASTDB_PROBE_LAT_CORR_RATIO` (default **1.4×**), or (b) the **geometric
   mean** of hot cand/base ratios exceeds `LASTDB_PROBE_LAT_GEO_MEAN_MAX`
   (default **1.5×**). Need at least `LASTDB_PROBE_LAT_CORR_MIN_OPS`
   (default 2) measurable pairs. Pure helper: `scripts/latency-bar-checks.sh`.
   Probe nodes boot with the live LaunchAgent's `LASTDB_*` tuning; peak RSS
   is sampled under the hot load. Skipping the whole bar
   (`LASTDB_PROBE_LAT_SKIP=1`) or only the correlated term
   (`LASTDB_PROBE_LAT_CORR_SKIP=1`) requires Tom's explicit clearance. Live
   post-check re-times **hot point-read and `kanban list` scan** vs the
   candidate's own hot probe numbers (`LASTDB_LIVE_LAT_ENFORCE=1` makes
   either RED). The bar also checks correlated hot-operation regressions and
   avoids a cold sub-floor baseline as a raw ratio denominator.
7c. **Key-cap bar (the logical resident set must purge).** The cap is a
   count of fetched records (`RESIDENT_KEY_CAP = 10000`), not bytes. The
   driver boots the candidate on its own CoW copy with
   `LASTDB_RESIDENT_KEY_CAP=100` (`KEY_CAP_BAR_CAP`), drives point reads
   and a scan for 120 seconds (`KEY_CAP_BAR_SECS`), and samples
   `/api/status`. Every sample must report `resident.resident_key_budget`
   equal to the cap, `resident_key_count` at or under it, and
   `resident_purged_keys` must rise above 0. Absent gauges are RED. There
   is no skip, so a binary without the logical resident set fails.
   There is no byte footprint bar. Eviction is measured in keys, and a GiB
   line does not measure it (Tom, 2026-10-04). The RSS bar against the
   memory-guard limit stays: it is the crash limit, not an eviction rule.
   The driver sets `LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1` on the
   ephemeral candidate copy only, never on the primary home. Helpers:
   `scripts/key-cap-bar-checks.sh`, `scripts/probe-copy-guards.sh`.
   Receipt line: `KEYCAP:`.
7d. **Hard-delete bar (the purge lane must not fail).** On the candidate's
   latency copy, after every timed read, the driver writes a scratch kanban
   card (`lastdb-safe-upgrade-hard-delete-probe-<pid>`, column `backlog`) and
   hard-deletes it with `kanban rm`. The CLI reaches the copy through
   `FOLDDB_SOCKET_PATH=<copy>/data/folddb.sock`. The driver then samples
   `/api/status` every 10 s for at most 150 s
   (`LASTDB_PROBE_HARD_DELETE_SECS`). The window covers the keep_small
   persist interval (30 s) and one keep_small compaction probe (120 s). It
   ends early (GREEN path) after 40 s when the keep_small
   `last_compacted_at_unix_s` stamp passes the delete, and early (RED path)
   on the first failure. Every sample must report
   `status.resident.persist_lane_failures == 0` and
   `status.resident.deferred_persist_failed == 0`. A failed write, a failed
   delete, a card still readable after the delete, or an absent field is
   RED. There is no skip. Incident 2026-10-04: fold f362b8e72 passed every
   other copy bar, then failed live with `persist-lane-failure` from a card
   delete ("hard-erase meter intent changed before commit"). Helper:
   `scripts/hard-delete-bar-checks.sh`. Receipt line: `HARDDELETE:`.
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
9. **CAS mutation bar (LastGit compound):** after data-plane GREEN, run
   `scripts/cas-mutation-probe.sh --lastdbd <candidate>` against an
   **ephemeral throwaway node** of the candidate only (never live primary).
   A node that ignores a false `expected` precondition and applies the write
   is **RED** — promotion is blocked with an actionable failure that names the
   candidate binary. Reuses LastGit's `test/cas-expected-node-enforced.sh`
   when present; otherwise a self-contained discriminator with the same
   true→200 / false→409 / refused-did-not-land sequence. Skipping
   (`LASTDB_PROBE_CAS_SKIP=1`) requires Tom clearance. Not a routine health
   check and not a live-primary mutation path.
10. **Binary-pair bar (lastdb + lastdbd):** before backup/probe, require a
    sibling `lastdb` CLI next to the candidate `lastdbd` and require both
    binaries to report the same version. Sidebin live install copies both
    binaries from that same artifact and the post-check fails RED if the
    installed live CLI/daemon pair is skewed.
11. Do not claim “primary stopped” unless this script actually stopped the
   supervisor for that venue.
12. **Durability canary (acked writes survive the restart):** immediately
    before any live change, the driver upserts
    `lastdb-safe-upgrade-durability-canary-1..N` (default N=4) through the
    `brain put --durable --json` path on the **live primary**, each carrying a
    run-unique nonce. Every write must return `durability: durable`, then the
    driver reads the exact nonce back. **Exception — queued+readback:** if
    `--durable` returns HTTP 400 (old daemon predates the durable-receipt
    API and `deny_unknown_fields` rejects the `durability` field), a queued
    put of the same sentinel that succeeds **and** a read-back of this run's
    nonce on the old daemon arms the canary in declared `queued+readback`
    mode (logged with the old build string and recorded on the Situations
    notice). A queued, missing, malformed, or failed receipt that is **not**
    HTTP 400 is still RED before any live change. After the cutover it
    re-reads each nonce on the new daemon. A sentinel that reads back with the PREVIOUS
    run's nonce is **RED**: the old daemon acknowledged a write the new daemon
    does not have. On 2026-08-18, two read-back-confirmed loom terminal-status
    writes vanished
    across a restart whose shutdown "did not complete its clean drain").
    Before the first daemon stop, the driver also writes
    `restart-intent.json` with the prior session PID and `cause: upgrade`.
    It removes the marker if no start request succeeds. A successful start
    leaves the marker for the new daemon's durable boot-ledger append.
    A slow old daemon is not a durability verdict. The arm retries the same
    upsert up to `LASTDB_DURABILITY_ARM_ATTEMPTS` (default 6) times with the
    `LASTDB_DURABILITY_ARM_BACKOFF_S` backoff (default `5 15 30 60 60`). It
    polls the pre-cutover read-back for `LASTDB_DURABILITY_ARM_READ_WAIT_S`
    (default 300s) with a `LASTDB_DURABILITY_ARM_READ_OP_S` (default 90s)
    per-read limit. The proof does not change.
    Unreadable sentinels after `LASTDB_DURABILITY_READ_WAIT_S` (default 120s)
    are also RED — durability UNPROVEN. Rolling back the binary does not
    recover lost writes; a RED here means audit recent writes across apps
    before trusting the store. **There is deliberately no skip flag.**
    Tunables: `LASTDB_DURABILITY_CANARY_N`, `LASTDB_DURABILITY_READ_WAIT_S`.
13. **Exact-candidate DEV photograph (required before live cutover — Tom
    2026-08-19):** the CUTOVER pass clones the rollback point that step 1
    selects in the same safe-upgrade sequence. It does not clone live
    `~/.lastdb` again. The versioned execution-key digest covers the source
    OID, canonical paths, binary hashes, and binary versions. The child graph
    checks the tuple before PROBE and CUTOVER.

    The proof removes both sockets, `current-session.json`, the copied device
    ID, `laststore_backup_known_present.json`,
    `laststore_backup_manifest.json`, every `cloud_sync.json*` file, and hidden
    `.cloud_sync.json.tmp*` residue. It does this before DEV connect. It unsets
    `LASTDB_HOME`, `FOLDDB_HOME`, and `FOLD_SYNC_DEVICE_ID` for connect, daemon
    start, and snapshot.

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
    reserves 45 seconds for owned cleanup, 180 seconds for CUTOVER recovery,
    and 15 seconds for the outer Loom deadline. It forwards external signals
    to the group and always reaps an abnormal driver tree. On a CUTOVER stop,
    a separate process group reads the private recovery state. If a live swap
    began, it restores the exact saved pair and reloads the LaunchAgent. It
    requires socket health and the supervised listener PID before it returns.
    A failed recovery retains the mode-600 state for exact manual recovery.

    The owner-only v2 receipt belongs to one Loom execution and expires after
    one hour. It records the exact source, pair paths, pair hashes, pair
    versions, DEV URL, CoW path, primary path, snapshot report, snapshot user
    hash, cloud DB hash, manifest object key, exact manifest-cache path, and
    isolation facts.
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

15b. **Graceful pre-stop under a short loaded exit timeout.** Only a job
    reload loads the stamped `ExitTimeOut` (150 s), and the reload is the stop.
    So when the LOADED job still has a shorter window, the driver stops the old
    daemon first: it moves the program path aside so KeepAlive cannot respawn,
    sends `launchctl kill SIGTERM`, waits up to `PRIMARY_EXIT_TIMEOUT_SECS`
    (`LASTDB_PRIMARY_GRACEFUL_STOP_WAIT_SECS`), SIGKILLs only after that wait,
    boots the job out with no process, and puts the program back. The reload
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
files. The fixed-length `safe-upgrade-v6-<digest>` key includes the gate
protocol version. Its digest covers the source OID, both canonical paths, both
binary hashes, and both versions. The graph checks the complete tuple before
PROBE and CUTOVER.

```bash
last-stack-safe-upgrade-loom \
  --candidate /path/to/release/lastdbd \
  --source-git-oid <full-fold-commit>
```

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
last-stack-canary-loom --start --oid <full-fold-main-commit>
```

The parent graph builds the candidate and calls `lastdb-safe-upgrade` as a Loom
child. Do not call the cutover driver from a routine or an agent.

`last-stack-canary-loom --recover` accepts only a complete protocol-v6 child
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

# Probe only (no live install)
bash "$driver" --probe-only

# Explicit candidate probe.
# MUST be a release build with sibling /path/to/release/lastdb beside it —
# never …/target/debug/lastdbd or a -dirty stamp.
bash "$driver" --candidate /path/to/release/lastdbd --probe-only

# Bottle version probe only
bash "$driver" --version 0.22.8 --probe-only

```

`--check-dev-stamp` is an internal diagnostic. It fails without the complete
Loom tuple and execution ID. Do not use a copied receipt as a manual approval.

Or, after last-stack is installed:

```bash
bash ~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh --probe-only
```

The script:

| Step | What |
|------|------|
| Preflight | Primary home exists, identity.key present, live `/health` ok (if socket up) |
| Resolve candidate | `brew update` / `--version` tarball / `--candidate` |
| **1. Rollback point** | `cp -cR` (APFS only; no full-copy fallback) → `${TMPDIR}/lastdb-safe-upgrade-rollback-<uid>/pre-<new>-from-<old>-<ts>/`; reclaim the prior retained point first |
| **0. Class** | Refuse `target/debug`, `-dirty` version, size ≫ incumbent (before multi-GB backup) |
| **2. Probe** | `BIN=<candidate>` CoW smoke harness (never live home) + **CAS mutation bar** (ephemeral candidate node: false `expected` → 409) + **RSS settle/sample** vs memory-guard limit + **latency bar**: cold then hot Board point-read / scan (like-to-like vs baseline CoW); hot `brain put` write; geo-mean on the hot triple only + **row-count bar**: candidate must not return 0 rows where the baseline returns rows (no skip flag) + **key-cap bar**: candidate on its own CoW with `LASTDB_RESIDENT_KEY_CAP=100`; count within budget, purge ran; no skip + **hard-delete bar**: scratch card `kanban rm` on the candidate copy, then `persist_lane_failures` and `deferred_persist_failed` stay 0 for a bounded window; no skip |
| Detect venue | sidebin vs brew |
| **2c. DEV photograph proof** | After all normal bars pass, the exact pair clones the static rollback point from step 1. It scrubs production state, connects the copied identity to compiled DEV, and runs the manual snapshot CAS. The fresh v2 receipt must match this Loom execution. |
| **2d. Meter restart bar** | Read live status before restart. Refuse a `keep_small` plane above 1.5 GiB or a failed persist lane. The 2 GiB cold-group cap can prevent both new and old binaries from booting. |
| **3. Live** | Refuse brew. For sidebin, arm the **durability canary** (N run-unique sentinels returned `durable` + read back on the old daemon, **or** `queued+readback` after HTTP 400 on `--durable` plus a queued put and matching nonce read-back; before any live change), arm the boot-ledger restart intent, verify both `.new` hashes before either rename, verify both installed hashes before reload, then reload the LaunchAgent job definition. A post-rename hash failure restores the saved pair before exit. |
| **4. Post-check** | Exact installed pair hashes, live `/health`, schemas > 0, Board title, **LaunchAgent config parity** (missing process env keys WARN; `LASTDB_LIVE_CONFIG_ENFORCE=1` → RED), **LaunchAgent loaded + live pid is that job** (a nohup `--data-dir` start is RED), **durability canary read-back** (stale nonce → RED, no skip flag), **live peak RSS** vs guard, **live point-read + kanban list latency** vs the candidate's probe numbers (WARN; `LASTDB_LIVE_LAT_ENFORCE=1` → RED); cutover_s + latency + durability in notice |
| **4a. Live soak** | Write and read four new durable canaries on the candidate. Keep the rollback point for at least five minutes. Check persist failures, write access, and meter size on each status sample. If Cloud Sync was on before cutover, require its confirmed frontier beyond the canary time. A failed or stale bar is RED. |
| **4b. Release** | After GREEN, delete the rollback point and its empty root. GREEN probe-only and operator abort release it too. |
| RED | Exit 1, retain the one rollback point, print its path, TTL, and cleanup owner; primary untouched if class/probe failed |

### Release one retained RED point without a new probe

Use `scripts/cleanup-retained-rollback.sh` only when the failed run ended
before a live cutover. The helper checks the exact point name and retention
marker, the host owner lock, the primary process start time and build, the
installed daemon build, and active probe processes. It fails closed if the
primary status over the Unix socket is unavailable. The default does not
delete data. `--execute` deletes only the named rollback point. It does not
start a candidate, create a copy, install a binary, or restart the primary.

```bash
export LASTDB_ROLLBACK_ROOT=/path/to/lastdb-safe-upgrade-rollback-UID
helper="$HOME/.last-stack/skills/lastdb-safe-upgrade/scripts/cleanup-retained-rollback.sh"
point="$LASTDB_ROLLBACK_ROOT/pre-CANDIDATE-from-CURRENT-YYYYMMDDTHHMMSSZ"
bash "$helper" --point "$point" --expect-primary-pid PID \
  --expect-retained-at YYYY-MM-DDTHH:MM:SSZ
# After the check reports READY, run the same command with --execute.
```

Use the PID and `retained_at` from the failed probe record. Check the current
primary with `lastdb status` first. Do not use this helper after any live
cutover attempt or when the rollback point may be needed for recovery. A
release can free less physical disk than `du` reports because APFS clones can
share blocks.

### C. If the graph or script is missing or fails open

Do **not** hand-roll a weaker path. Fix the graph or script, or stop. If the
skill is missing on this harness, run `~/.last-stack/setup --host auto` (clean
install tree only — never dirty `~/.last-stack` by hand).

### D. Report to Tom

Always print:

- Current version → candidate version  
- Venue (sidebin / brew)  
- Rollback path and whether it was released or retained (TTL + cleanup owner)
- Probe GREEN/RED (+ first Board title if green)  
- **Probe peak RSS MiB vs memory-guard limit / fail_at**  
- **Latency: cold point/scan and hot point/scan/write, candidate vs baseline (ms) + boot seconds**  
- **Key-cap receipt:** `KEYCAP:` with `cap=100`, the sample count, `max_count` at or under the cap, and `purged_keys` above 0.
- **Hard-delete receipt:** `HARDDELETE:` with the scratch slug, the sample count, `waited_s`, and `persist_lane_failures=0 deferred_persist_failed=0`.
- Whether live upgrade ran + cutover seconds + live peak RSS + live point-read ms  
- Rollback commands (script prints them)

Optional: append a one-liner to brain reference `lastdb-safe-upgrade-log` via
`brain append` (non-secret metadata only).

After a GREEN **live** upgrade the script posts a Situations **notice** so other
agents can attribute socket blips to the upgrade instead of opening a false
incident.

Then it starts `last-stack-canary-candidate-gate --primary-rows-only --detach`.
Host-track installs an app only from a registry `next` row proved with the
build the primary runs, and a cutover on this path wrote no rows. The step is
a noop when rows exist. Otherwise it proves the app set against the new build
in an isolated smoke on the primary's own `lastdbd` and publishes the rows.
It never builds and never cuts over. The hourly reconcile gate re-runs it if
this call is missed. `LASTDB_SAFE_UPGRADE_PRIMARY_ROWS=0` turns it off.

## Reading results

| Output | Meaning | Action |
|--------|---------|--------|
| `VERDICT: GREEN` | Probe + live cutover + live post-check passed | Done |
| `VERDICT: GREEN_PROBE_ONLY` | Probe passed; primary still on old version | Start `last-stack-safe-upgrade-loom` with the candidate and source commit if Tom wants the upgrade |
| `VERDICT: ALREADY_CURRENT` | Already on candidate/stable | Nothing to do |
| `VERDICT: RED` | Candidate fails **class** bar (debug/dirty/size), **or** cannot serve real data, **or** the **CAS mutation** bar (node accepted a false `expected` precondition), **or** peak RSS exceeds memory-guard bar, **or** the latency bar failed (per-op 3×, absolute ceiling, **or correlated** all-ops / geo-mean regression), **or** the **row-count bar** failed (a real read returned 0 rows where the baseline returned rows), **or** the **key-cap bar** failed (budget not the requested cap, count above budget, or no purge), **or** the **hard-delete bar** failed (a card hard delete on the copy raised a persist-lane or deferred-persist failure, or the write or delete did not happen), **or** the exact-candidate DEV proof failed, **or** its v2 receipt is stale or mismatched, **or** the **durability canary** lacks an exact durable receipt before cutover, **or** its post-cutover read is stale, **or** the primary LaunchAgent does not own the live process, **or** a meter, persist-lane, supervision, or cloud-frontier bar failed | **Do not upgrade**. File a release blocker. Use the retained rollback point only when recovery needs it. The next safe-upgrade run reclaims it. A durability RED after cutover means you must audit recent writes. A binary rollback cannot recover lost writes. |

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

**Data (only if home corrupted and the run is RED):**

```bash
# stop primary supervisor, then:
mv ~/.lastdb ~/.lastdb.broken-$(date +%Y%m%dT%H%M%S)
cp -a <printed-ephemeral-rollback-path> ~/.lastdb
# restart supervisor (kickstart or brew services start)
kanban list   # must show real cards
```

## Related skills / harnesses

- **`lastdb-smoke-test`** — probe-only CoW canary (no persistent backup, no live install).
  Safe-upgrade **calls** its harness for step 2.
- **Write-path CoW probe (Table 5 / T0 ack):** `scripts/write-path-cow-probe.sh`
  clones the live home with `cp -cR` into `${TMPDIR}` (never `--data-dir ~/.lastdb`),
  reuses `live_lastdb_env_pairs()`, strips prod `cloud_sync.json`, and classifies
  a warm BoardCards mutation. Incumbent-shaped samples (seconds-scale ack,
  persist/T2 on the request, Purge in the batch) are **RED**. Table 5 GREEN is
  persist spawn-only, `sync_capture` encode-only, `purge_barrier` ≈ 0, warm
  p50 < 50 ms / p95 < 100 ms. This probe does not replace safe-upgrade; it is
  the extra write-path bar. `LASTDB_RESIDENT_MAX_DEFERRED_BYTES` on the live
  plist stays 0 until full GREEN plus Tom.
- **`brain-doctor`** — if primary is already wedged **before** upgrade; fix health first.
- Design: **`lastdb-minimal-downtime-cutover`** (venue + optional proxy phase).

## Never

- `brew upgrade lastdb` as a one-liner without this skill when the user cares about data.
- Run `safe-upgrade-lastdb.sh` without `--probe-only` outside a Loom execution.
- Use the brew venue for an exact-candidate live cutover. Use sidebin so the
  installed files equal the photographed pair.
- Start a second safe-upgrade while another probe or cutover owns the host-wide
  safety lock. Wait for the first owner to exit. The lock covers rollback
  cleanup, the real-data probe, and the live cutover.
- Point candidate `--data-dir` at live `~/.lastdb` "just to see".
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
correlated latency term + canary ancestry/soak-write gates close the hole.
