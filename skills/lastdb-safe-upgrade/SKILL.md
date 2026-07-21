---
name: lastdb-safe-upgrade
description: |
  REQUIRED path for ANY primary LastDB Mini version change. Safely upgrade
  Tom's primary lastdbd so the live brain is never the first place a bad binary
  fails. ALWAYS: (1) durable offline copy of ~/.lastdb, (2) boot the NEW binary
  only against an ephemeral/CoW copy (never live home first), (3) require GREEN
  real-data reads, (4) only then venue-aware live install (sidebin+launchd or
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
2. **Always** create a **durable** backup under `~/.lastdb-backups/` first
   (kept after success; not deleted by the harness).
3. **Never** restart/upgrade on a RED probe.
4. **Never** kill the primary unattended outside this skill's live step; if live
   post-check fails after upgrade, **stop and restore** (binary bak and/or data
   backup) — do not improvise.
5. Probe bar = smoke bar: identity decrypts, `/api/schemas` > 0, `Board` query
   returns real **title values** (counts alone are not proof).
6. Do not claim “primary stopped” unless this script actually stopped the
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

# Explicit candidate binary (sidebin install on Tom’s machine)
bash "$driver" --candidate /path/to/lastdbd --yes

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
| **1. Backup** | `cp -cR` (APFS) or `cp -a` → `~/.lastdb-backups/pre-<new>-from-<old>-<ts>/` |
| **2. Probe** | `BIN=<candidate>` CoW smoke harness (never live home) |
| Detect venue | sidebin vs brew |
| **3. Live** | sidebin atomic install + kickstart **or** brew upgrade/restart |
| **4. Post-check** | Live `/health`, schemas > 0, Board title; cutover_s in notice |
| RED | Exit 1, **keep backup**, primary untouched if probe failed |

### B. If the script is missing or fails open

Do **not** hand-roll a weaker path. Fix the script or stop. If the skill is
missing on this harness, run `~/.last-stack/setup --host auto` (clean install
tree only — never dirty `~/.last-stack` by hand).

### C. Report to Tom

Always print:

- Current version → candidate version  
- Venue (sidebin / brew)  
- Backup path  
- Probe GREEN/RED (+ first Board title if green)  
- Whether live upgrade ran + cutover seconds  
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
| `VERDICT: RED` | Candidate cannot serve real data | **Do not upgrade**; file release-blocker; keep backup |

## Rollback

**Binary only (sidebin — preferred first try):**

```bash
cp -a ~/.lastdb/bin-with-upload-cap/lastdbd.bak-pre-<ver>-<ts> \
      ~/.lastdb/bin-with-upload-cap/lastdbd
launchctl kickstart -k gui/$(id -u)/com.tomtang.lastdbd-primary-506
kanban list
```

**Data (only if home corrupted):**

```bash
# stop primary supervisor, then:
mv ~/.lastdb ~/.lastdb.broken-$(date +%Y%m%dT%H%M%S)
cp -a ~/.lastdb-backups/pre-<ver>-from-<old>-<ts> ~/.lastdb
# restart supervisor (kickstart or brew services start)
kanban list   # must show real cards
```

## Related skills / harnesses

- **`lastdb-smoke-test`** — probe-only CoW canary (no backup, no live install).  
  Safe-upgrade **calls** its harness for step 2.
- **`brain-doctor`** — if primary is already wedged **before** upgrade; fix health first.
- Design: **`lastdb-minimal-downtime-cutover`** (venue + optional proxy phase).

## Never

- `brew upgrade lastdb` as a one-liner without this skill when the user cares about data.
- Point candidate `--data-dir` at live `~/.lastdb` "just to see".
- Delete `~/.lastdb-backups/*` as part of a successful upgrade (Tom prunes later).
- Restart/kill primary on RED.
- Call `brew upgrade` when formula is not installed and primary is sidebin.
- Assume the skill lives only under `~/.claude/skills` — Codex/Grok/Factory use their own skills dirs; last-stack setup keeps them in sync.

## Background

Incidents: 2026-07-13 wrong-key / 0.22.6 decrypt brick; 2026-07-16 brew upgrade
failed because primary is sidebin+launchd not brew services; 2026-07-21 Codex
could not find this skill because it was Claude-only (not in last-stack).
