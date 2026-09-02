---
name: lastdb-safe-upgrade
description: |
  REQUIRED path for ANY primary LastDB Mini version change. Safely upgrade
  Tom's primary lastdbd so the live brain is never the first place a bad binary
  fails. ALWAYS: (1) one ephemeral CoW rollback point outside $HOME, (2) boot the NEW binary
  only against an ephemeral/CoW copy (never live home first), (3) require GREEN
  real-data reads AND RSS under the memory-guard AND the latency bar (real
  workloads timed vs the current binary — correct-but-slow is RED) AND the
  CAS mutation bar (candidate enforces `/api/mutation` `expected` — false
  precondition → 409; LastGit ref/CI CAS depends on it), AND a GREEN
  **DEV photograph stamp** (ephemeral/CoW of real data uploads the
  photograph to DEV — not the primary's production backup home — and
  CAS-flips backup/latest; never live `~/.lastdb` first), (4) only
  then venue-aware live install (sidebin+launchd or
  brew services) + post-check + Situations notice, with the **durability
  canary** bracketing the restart (sentinels must return a durable receipt
  before cutover and read back after it — a stale nonce is RED; no skip flag). Use when Tom says "upgrade
  lastdb", "brew upgrade lastdb", "safe upgrade", "update my brain/database
  binary", "can I upgrade to 0.22.x", "don't brick my data", "new bottle/release",
  or whenever an agent would otherwise brew-upgrade or point a candidate lastdbd
  at ~/.lastdb. Standing rule: preference-lastdb-upgrade-ephemeral-probe-first.
  Distinct from lastdb-smoke-test (probe-only, no upgrade). Design:
  fold/docs/designs/lastdb-minimal-downtime-cutover.md
---

# lastdb-safe-upgrade — never brick the primary; never take it down first

Tom's primary brain is `~/.lastdb` (~multi-GB). Past upgrades have bricked real
data. **Standing rule (Tom, 2026-07-14):** every version change uses this skill so
Tom does **not** experience primary-brain downtime as the first feedback that a
release is broken — fail on the ephemeral copy; keep live on last known-good until
GREEN. Brain: `preference-lastdb-upgrade-ephemeral-probe-first`,
`sop-lastdb-safe-upgrade`.

This skill and its Loom `lastdb-safe-upgrade` graph are the **only** allowed
path for a live binary change on this machine. The shell driver remains the
probe and cutover implementation. It refuses a live cutover outside Loom.

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

Primary may be supervised in either of two ways:

| Venue | How primary runs | Live install |
|-------|------------------|--------------|
| **sidebin** (Tom’s default) | LaunchAgent → `~/.lastdb/bin-with-upload-cap/lastdbd` | Atomic install into that dir + `launchctl bootout` / `bootstrap` job reload |
| **brew** | `brew services` + Cellar formula | `brew upgrade` + `brew services restart` |

The script **detects venue** (LaunchAgent `ProgramArguments`, formula installed,
sidebin present). It must **not** call `brew upgrade` when the formula is not
installed — that was the 2026-07-16 failure mode.

Design: `fold/docs/designs/lastdb-minimal-downtime-cutover.md`.

Env overrides: `LASTDB_SIDEBIN_DIR`, `LASTDB_LAUNCHD_LABEL`, `LASTDB_LAUNCHD_PLIST`.
The sidebin path reloads the LaunchAgent job definition so plist environment
edits take effect; `kickstart` alone only restarts the cached definition. The
live post-check names configured keys absent from the new process, and
`LASTDB_LIVE_CONFIG_ENFORCE=1` makes any such drift RED.

**Hot swap:** a single-process image swap always needs a brief restart. “Seamless”
here means **prepared cutover after GREEN CoW**, not zero downtime. A socket
proxy is optional later for near-zero client impact.

## Hard rules (never skip)

1. **Never** run a candidate `lastdbd` with `--data-dir` pointing at the **live**
   `~/.lastdb` until a probe against a **copy** is GREEN.
2. **Always** create exactly one ephemeral CoW rollback point under the system
   temp directory. Release it on GREEN (including GREEN probe-only or operator
   abort); on RED retain it for the printed TTL, owned by the next safe-upgrade
   run, which reclaims it before creating another. Never write rollback copies
   under `$HOME`.
3. **Never** restart/upgrade on a RED probe.
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
   either RED). Brain:
   `papercut-safe-upgrade-latency-bar-blind-to-correlated-regression`,
   `papercut-safe-upgrade-point-read-bar-cold-first-boot-vs-subfloor-baseline`,
   `lastdb-canary-cutover-rolled-the-primary-back-four-days-20260805`.
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
   `incident-20260801-debug-worktree-lastdbd-primary-cutover-latency`,
   `preference-lastdb-promote-origin-main-not-feature-branch`.
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
    driver reads the exact nonce back. A queued, missing, malformed, or failed
    receipt is RED before any live change. After the cutover it re-reads each
    nonce on the new daemon. A sentinel that reads back with the PREVIOUS
    run's nonce is **RED**: the old daemon acknowledged a write the new daemon
    does not have — the exact loss shape of
    `papercut-lastdb-acked-write-lost-loom-terminal-status-regressed`
    (2026-08-18: two read-back-confirmed loom terminal-status writes vanished
    across a restart whose shutdown "did not complete its clean drain").
    Before the first daemon stop, the driver also writes
    `restart-intent.json` with the prior session PID and `cause: upgrade`.
    It removes the marker if no start request succeeds. A successful start
    leaves the marker for the new daemon's durable boot-ledger append.
    Unreadable sentinels after `LASTDB_DURABILITY_READ_WAIT_S` (default 120s)
    are also RED — durability UNPROVEN. Rolling back the binary does not
    recover lost writes; a RED here means audit recent writes across apps
    before trusting the store. **There is deliberately no skip flag.**
    Tunables: `LASTDB_DURABILITY_CANARY_N`, `LASTDB_DURABILITY_READ_WAIT_S`.
13. **DEV photograph stamp (required before live cutover — Tom 2026-08-19,
    this is the SOP for all upgrades):** after the other probe bars, live
    install is **refused** unless an **ephemeral/CoW copy of real data**
    (never live `~/.lastdb`) uploaded a cloud-backup **photograph** to
    **DEV** (Exemem `https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com`,
    not the primary's production backup home
    `jdsx4ixk2i.execute-api.us-east-1.amazonaws.com`) and CAS-flipped
    `backup/latest` (committed snapshot counter ≥ 1). A mock object store is
    not DEV. Strip prod `cloud_sync.json` on the CoW, connect `--env dev`
    with a DEV-only invite, then `lastdb cloud snapshot`. Record a GREEN
    receipt; `scripts/dev-photograph-stamp-gate.sh` / `--check-dev-stamp`
    refuse live when the receipt is missing, RED, aimed at production, or
    used the live home. Skip (`LASTDB_PROBE_DEV_STAMP_SKIP=1`) is Tom
    clearance only. Brain: `preference-lastdb-upgrade-ephemeral-probe-first`,
    `sop-lastdb-safe-upgrade`.
14. **LaunchAgent config parity:** sidebin cutover uses `bootout` then
    `bootstrap` so the plist job definition is re-read. It falls back to
    `kickstart -k` only when those launchctl verbs are unavailable. After the
    new daemon is serving, compare plist `EnvironmentVariables` key names with
    the running process environment (never print values). Missing keys are a
    loud WARN; `LASTDB_LIVE_CONFIG_ENFORCE=1` makes them RED.
15. **Bootstrap retries — an EIO is a race, not a verdict.** A `bootstrap`
    right after a successful `bootout` can fail with
    `Bootstrap failed: 5: Input/output error`. Treating that as terminal left
    the primary UNLOADED three times; the third, unattended, ran 4h34m and
    took brain, board, Situations, LastGit CI and every routine down with it
    (`papercut-lastdb-safe-upgrade-bootout-bootstrap-left-primary-unloaded`).
    So the driver retries `bootstrap` with backoff — `2 5 15 30 30 30`
    seconds, override with `LASTDB_LAUNCHD_BOOTSTRAP_RETRY_DELAYS`.

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

16. **Leftover socket is not up.** After `bootout`, a leftover `folddb.sock`
    inode still passes `[ -S sock ]` with no listener. Waiting only for the
    inode reports `socket up after 0s`, then the live `/health` poll spends
    its whole budget on a dead file (2026-08-26: bootstrap EIO, leftover sock
    from hours earlier, `VERDICT: RED`). The driver unlinks that leftover
    **only when no process holds it**, then waits until a listener pid **and**
    `/health` are ok. Helper: `scripts/live-socket-health.sh`. Brain:
    `papercut-lastdb-safe-upgrade-stale-socket-health-after-bootout`.
17. **A nohup start is not GREEN.** After bootout, if `launchctl print` cannot
    find the primary job, the driver retries `bootstrap` so KeepAlive owns
    lastdbd (unattended bootstrap of an unloaded primary is allowed:
    `decision-2026-08-23-unattended-lastdbd-bootstrap-self-heal`). A leftover
    listener plus `nohup lastdbd --data-dir ~/.lastdb` may restore `/health`,
    but `VERDICT: GREEN` is refused until print succeeds and the live pid is
    that job. `LIVE_CONFIG_DRIFT` still names missing plist env keys. Brain:
    `papercut-lastdb-safe-upgrade-fallback-start-leaves-launchd-unloaded`.

## Do this, in order

### A. Use Loom for every live cutover

Start the graph with an explicit release candidate. The launcher reads the
candidate source commit, creates one execution key for that commit, and checks
Git ancestry before the probe and immediately before the cutover.

```bash
last-stack-safe-upgrade-loom \
  --candidate /path/to/release/lastdbd \
  --source-git-oid <full-fold-commit>
```

The sibling `lastdb` binary and the bundle manifest must be next to `lastdbd`.
An equal candidate finishes as a no-op. An older, divergent, or unknown source
commit fails closed. Do not resume an execution for a different source commit.

The nightly path uses the parent graph:

```bash
last-stack-canary-loom --start --oid <full-fold-main-commit>
```

The parent graph builds the candidate and calls `lastdb-safe-upgrade` as a Loom
child. Do not call the cutover driver from a routine or an agent.

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

# Refuse/allow live based only on the DEV photograph stamp receipt
bash "$driver" --check-dev-stamp
```

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
| **2. Probe** | `BIN=<candidate>` CoW smoke harness (never live home) + **CAS mutation bar** (ephemeral candidate node: false `expected` → 409) + **RSS settle/sample** vs memory-guard limit + **latency bar**: cold then hot Board point-read / scan (like-to-like vs baseline CoW); hot `brain put` write; geo-mean on the hot triple only |
| Detect venue | sidebin vs brew |
| **2b. DEV photograph stamp** | Live cutover **refused** without a GREEN receipt: ephemeral/CoW (never `~/.lastdb`) uploaded the photograph to **DEV** (not the primary's production backup home) and CAS-flipped `backup/latest`. `--check-dev-stamp` exercises this gate alone. |
| **3. Live** | **durability canary armed** (N run-unique sentinels returned `durable` + read back on the old daemon, before any live change), boot-ledger restart intent armed, then sidebin atomic install + LaunchAgent job-definition reload **or** brew upgrade/restart |
| **4. Post-check** | Live `/health`, schemas > 0, Board title, **LaunchAgent config parity** (missing process env keys WARN; `LASTDB_LIVE_CONFIG_ENFORCE=1` → RED), **LaunchAgent loaded + live pid is that job** (a nohup `--data-dir` start is RED), **durability canary read-back** (stale nonce → RED, no skip flag), **live peak RSS** vs guard, **live point-read + kanban list latency** vs the candidate's probe numbers (WARN; `LASTDB_LIVE_LAT_ENFORCE=1` → RED); cutover_s + latency + durability in notice |
| **4b. Release** | After GREEN, delete the rollback point and its empty root. GREEN probe-only and operator abort release it too. |
| RED | Exit 1, retain the one rollback point, print its path, TTL, and cleanup owner; primary untouched if class/probe failed |

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
- Whether live upgrade ran + cutover seconds + live peak RSS + live point-read ms  
- Rollback commands (script prints them)

Optional: append a one-liner to brain reference `lastdb-safe-upgrade-log` via
`brain append` (non-secret metadata only).

After a GREEN **live** upgrade the script posts a Situations **notice** so other
agents can attribute socket blips to the upgrade instead of opening a false
incident.

## Reading results

| Output | Meaning | Action |
|--------|---------|--------|
| `VERDICT: GREEN` | Probe + live cutover + live post-check passed | Done |
| `VERDICT: GREEN_PROBE_ONLY` | Probe passed; primary still on old version | Start `last-stack-safe-upgrade-loom` with the candidate and source commit if Tom wants the upgrade |
| `VERDICT: ALREADY_CURRENT` | Already on candidate/stable | Nothing to do |
| `VERDICT: RED` | Candidate fails **class** bar (debug/dirty/size), **or** cannot serve real data, **or** the **CAS mutation** bar (node accepted a false `expected` precondition), **or** peak RSS exceeds memory-guard bar, **or** the latency bar failed (per-op 3×, absolute ceiling, **or correlated** all-ops / geo-mean regression), **or** the **DEV photograph stamp** is missing/RED (no ephemeral/CoW upload to DEV, or the receipt names production / live `~/.lastdb`), **or** the **durability canary** cannot obtain an exact durable receipt before cutover, **or** its post-cutover read is stale/unreadable, **or** the primary LaunchAgent is unloaded / is not the live pid after a nohup `--data-dir` start | **Do not upgrade**; file release-blocker; use the one retained rollback point only if recovery is required. The next safe-upgrade run reclaims it. A durability RED after cutover additionally means: audit recent writes across apps — rollback does not recover lost writes. An unloaded LaunchAgent additionally means: `launchctl bootstrap gui/$(id -u) <plist>` then `launchctl print` must show state=running and this pid. |

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
> Papercut: `papercut-lastdb-safe-upgrade-rollback-cp-a-trips-codesigning`.

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
- Start a second safe-upgrade while another probe or cutover owns the host-wide
  safety lock. Wait for the first owner to exit. The lock covers rollback
  cleanup, the real-data probe, and the live cutover.
- Point candidate `--data-dir` at live `~/.lastdb` "just to see".
- Upload a CoW/ephemeral photograph into the primary's **production** backup
  home, or treat a mock object-store "stamp" as the DEV photograph gate.
- Live cutover without a GREEN DEV photograph stamp (CAS `latest` on DEV
  from an ephemeral/CoW copy of real data).
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
Brain: `lastdb-canary-cutover-rolled-the-primary-back-four-days-20260805`,
`papercut-safe-upgrade-latency-bar-blind-to-correlated-regression`.
