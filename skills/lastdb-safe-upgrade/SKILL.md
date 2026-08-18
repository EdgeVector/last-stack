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
  precondition → 409; LastGit ref/CI CAS depends on it), (4) only
  then venue-aware live install (sidebin+launchd or
  brew services) + post-check + Situations notice. Use when Tom says "upgrade
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

This skill is the **only** allowed path for upgrading that binary on this machine.

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
| **sidebin** (Tom’s default) | LaunchAgent → `~/.lastdb/bin-with-upload-cap/lastdbd` | Atomic install into that dir + `launchctl kickstart -k` |
| **brew** | `brew services` + Cellar formula | `brew upgrade` + `brew services restart` |

The script **detects venue** (LaunchAgent `ProgramArguments`, formula installed,
sidebin present). It must **not** call `brew upgrade` when the formula is not
installed — that was the 2026-07-16 failure mode.

Design: `fold/docs/designs/lastdb-minimal-downtime-cutover.md`.

Env overrides: `LASTDB_SIDEBIN_DIR`, `LASTDB_LAUNCHD_LABEL`, `LASTDB_LAUNCHD_PLIST`.

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
   LaunchAgent plist, else 12288. Before a sidebin kickstart, the script stamps
   the primary plist with that live limit so lastdbd does not boot with a lower
   binary default while the guard enforces the resident ceiling. Incident
   2026-07-22: sled-free cutover sat at ~8.5 GiB while the guard killed at 6 GiB
   -> thrash. Live post-check re-samples primary RSS the same way.
7. **Latency bar (correct-but-slow is RED):** on the same candidate CoW boot,
   time real workloads — keyed Board point read (`/api/query`), the scan-shaped
   `kanban list --column todo` (the op that regressed in 0.23.1), and a real
   `brain put` upsert (writes only ever land on the throwaway copy). Then boot
   the **current live binary** on an identical CoW copy and time the same ops
   as the baseline. Probe nodes boot with the live LaunchAgent's `LASTDB_*`
   tuning env mirrored in (warm budget etc.), and peak RSS is sampled **under
   this load** (an idle Last Store node pages out and reads ~10 MiB). **RED**
   if candidate median > `LASTDB_PROBE_LAT_RATIO` (default 3×) the baseline
   above a `LASTDB_PROBE_LAT_FLOOR_MS` (default **250 ms**; was 1000 ms —
   exclusive CoW scans often sit under 1 s so the ratio never fired), exceeds
   `LASTDB_PROBE_LAT_ABS_MAX_MS` (20 s) **when no baseline is measurable**, or
   is unmeasurable on the candidate while the baseline measured. When candidate
   AND baseline are both over the ceiling that is pre-existing store slowness:
   loud WARN, ratio governs (a bar that REDs on the status quo trains everyone
   to skip it). **Correlated / aggregate term (2026-08-05):** the per-op 3× bar
   alone passed a canary that was slower on **every** op at 1.6–2.4× (point
   58/24, scan 319/184, write 4646/2904) and then tanked multi-writer writes
   on the primary. Alongside per-op, the probe REDs when (a) **all** measurable
   ops regress at ≥ `LASTDB_PROBE_LAT_CORR_RATIO` (default **1.4×**), or
   (b) the **geometric mean** of cand/base ratios across measurable ops exceeds
   `LASTDB_PROBE_LAT_GEO_MEAN_MAX` (default **1.5×**). Need at least
   `LASTDB_PROBE_LAT_CORR_MIN_OPS` (default 2) measurable pairs. Pure helper:
   `scripts/latency-bar-checks.sh`. Incident 2026-07-25/27: the 0.23.1 cutover
   passed the correctness + RSS bars while scans ran 5–20× slower — the live
   primary was the first place anyone noticed. Skipping the whole bar
   (`LASTDB_PROBE_LAT_SKIP=1`) or only the correlated term
   (`LASTDB_PROBE_LAT_CORR_SKIP=1`) requires Tom's explicit clearance. Live
   post-check re-times **point-read and `kanban list` scan** vs the candidate's
   own probe numbers and warns (`LASTDB_LIVE_LAT_ENFORCE=1` makes either RED).
   Incident 2026-08-01: live point stayed ~113 ms while list hit multi-second→60 s.
   Brain: `papercut-safe-upgrade-latency-bar-blind-to-correlated-regression`,
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

## Do this, in order

### A. Prefer the driver script (default)

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

# Full path: probe then upgrade if green (interactive confirm)
bash "$driver"

# Probe only (no live install)
bash "$driver" --probe-only

# Non-interactive after GREEN probe (agents / automation Tom authorized)
bash "$driver" --yes

# Explicit candidate binary (sidebin install on Tom’s machine).
# MUST be a release build with sibling /path/to/release/lastdb beside it —
# never …/target/debug/lastdbd or a -dirty stamp.
bash "$driver" --candidate /path/to/release/lastdbd --yes

# Bottle version via GitHub release tarball then venue-aware live
bash "$driver" --version 0.22.8 --probe-only
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
| **2. Probe** | `BIN=<candidate>` CoW smoke harness (never live home) + **CAS mutation bar** (ephemeral candidate node: false `expected` → 409) + **RSS settle/sample** vs memory-guard limit + **latency bar**: point read / `kanban list` scan / `brain put` write timed on candidate CoW copy vs the current binary on an identical copy |
| Detect venue | sidebin vs brew |
| **3. Live** | sidebin atomic install + kickstart **or** brew upgrade/restart |
| **4. Post-check** | Live `/health`, schemas > 0, Board title, **live peak RSS** vs guard, **live point-read + kanban list latency** vs the candidate's probe numbers (WARN; `LASTDB_LIVE_LAT_ENFORCE=1` → RED); cutover_s + latency in notice |
| **4b. Release** | After GREEN, delete the rollback point and its empty root. GREEN probe-only and operator abort release it too. |
| RED | Exit 1, retain the one rollback point, print its path, TTL, and cleanup owner; primary untouched if class/probe failed |

### B. If the script is missing or fails open

Do **not** hand-roll a weaker path. Fix the script or stop. If the skill is
missing on this harness, run `~/.last-stack/setup --host auto` (clean install
tree only — never dirty `~/.last-stack` by hand).

### C. Report to Tom

Always print:

- Current version → candidate version  
- Venue (sidebin / brew)  
- Rollback path and whether it was released or retained (TTL + cleanup owner)
- Probe GREEN/RED (+ first Board title if green)  
- **Probe peak RSS MiB vs memory-guard limit / fail_at**  
- **Latency: candidate vs baseline point/scan/write medians (ms) + boot seconds**  
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
| `VERDICT: GREEN_PROBE_ONLY` | Probe passed; primary still on old version | Re-run with `--yes` if Tom wants the upgrade |
| `VERDICT: ALREADY_CURRENT` | Already on candidate/stable | Nothing to do |
| `VERDICT: RED` | Candidate fails **class** bar (debug/dirty/size), **or** cannot serve real data, **or** the **CAS mutation** bar (node accepted a false `expected` precondition), **or** peak RSS exceeds memory-guard bar, **or** the latency bar failed (per-op 3×, absolute ceiling, **or correlated** all-ops / geo-mean regression) | **Do not upgrade**; file release-blocker; use the one retained rollback point only if recovery is required. The next safe-upgrade run reclaims it. |

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
- **`brain-doctor`** — if primary is already wedged **before** upgrade; fix health first.
- Design: **`lastdb-minimal-downtime-cutover`** (venue + optional proxy phase).

## Never

- `brew upgrade lastdb` as a one-liner without this skill when the user cares about data.
- Point candidate `--data-dir` at live `~/.lastdb` "just to see".
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
