---
name: lastdb-safe-upgrade
description: |
  Required path for a version change of the primary LastDB Mini (native home,
  format 15 and newer). The driver binds the exact candidate pair to its
  attested release and passing CI, opens a generated home across the upgrade,
  proves backup and restore on the DEV relay with a throwaway identity, requires
  the signed-log backup recovery point in the old build's status, stops the old
  daemon with a flush receipt, switches the program folder, and soaks: health,
  memory, then acked following head and one snapshot. No step copies the primary
  database, reads its recovery phrase, or runs tests.
---

# lastdb-safe-upgrade: never brick the primary; never take it down first

Tom's primary is `~/.lastdb`. Every version change uses this skill, so Tom does
not learn that a release is broken from primary downtime. Fail on generated data
first; keep the live node on the last known-good build until every gate is GREEN.

**Never copy the primary database (Tom, 2026-10-12).** No trial copies `~/.lastdb`
or boots a node on a copy of it. Trials use generated homes. Brain:
`decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data`.

**Never read the primary's recovery phrase.** A restore of the primary's data is
run by Tom himself (see Rollback). The restore proof below uses a throwaway identity.

This skill and its Loom `lastdb-safe-upgrade` graph are the only allowed path for
a live binary change. The shell driver is the implementation; it refuses a live
cutover outside Loom. `last-stack-safe-upgrade-loom` runs the graph on Loom local
recovery (protected journal outside LastDB), so a slow or down primary cannot stop
the upgrade that replaces it. Decision: `decision-2026-10-04-safe-upgrade-always-local-journal`.

## Install location

Shipped in last-stack (`skills/lastdb-safe-upgrade/`). `~/.last-stack/setup --host auto`
registers it for every harness; the canonical copy is
`~/.last-stack/skills/lastdb-safe-upgrade/`. Prefer the driver path
`~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh`.

To install an accepted last-stack repair without touching unrelated services:

```bash
LAST_STACK_APPS_OFF=1 lastdb app upgrade last-stack
```

## The route

Only native homes (marker `data/laststore-pack-node-v1` with `format=15` or newer)
are supported. The candidate must have the same disk format and record profile as
the running build. A format change is refused ("one-time logical export and import
into a fresh home required"); Tom does that by hand, there is no migration code.

| Step | What runs | Fails when |
|------|-----------|------------|
| 1. Qualify | `native-upgrade-release.py`: the exact `lastdb` + `lastdbd` pair equals the attested Mac release of the full source commit, and `ci-required` and `benchmark-complete` passed for that commit. No local build or benchmark. | Any hash, attestation or check differs |
| 2. Class | Refuse `target/debug`, `-dirty` versions, a daemon over 1.5x the incumbent size; sibling `lastdb` of the same version; `codesign --verify --strict` | Any of these |
| 3. Generated home | `native-primary-probe.py`: old build writes, candidate reads and writes (keyed reads), old build reads again. Memory below the memory-guard limit minus 10%. | A read differs, memory too high, no clean stop |
| 4. DEV restore proof | `dev-restore-proof.py` (below) | Any step |
| 5. Pre-live | Primary healthy, supervised by launchd, auto-identity read, Brain and LastSecrets locators read | Any read fails |
| 6. Stage | Pair copied to `~/.lastdb/native-run-v2-programs/<full commit>/`, hashes and code signatures checked | A hash differs |
| 7. Recovery point | From the OLD build status (below). Primary is not stopped on a refusal. | Any field missing or false |
| 8. Strict stop | Memory-guard revive held, `launchctl kill SIGTERM`, wait up to 300 s, no forced kill, exact flush receipt and clean session | Timeout or no receipt |
| 9. Switch | `ProgramArguments:0` and `~/.lastdb/current` (via `last-stack-lastdb-current set`) name the new folder; job bootout, then bootstrap with retries | Reload fails |
| 10. Soak | Five minutes: same pid as the launchd job, identity, writer healthy, LaunchAgent env keys present, memory, locators. Then the backup soak (below). | Any sample fails |

The Loom steps are PROBE (`--candidate X --probe-only`), CUTOVER (`--candidate X --yes`,
steps 1 to 10; the DEV proof runs again) and VERIFY (`--live-read-check`). The
five-minute soak cannot be shortened.

## Recovery point (step 7)

The recovery point is the primary's own signed-log backup plus the saved old program
folder. Before the stop, the driver reads `GET /api/status` of the OLD running build
and requires all of the following in `status.cloud_sync`. A field that is missing is
a refusal (fail closed):

- `connected` is true, `environment` is a non-empty string, `captures_accepted` is
  true, `payment_hold` is false, `last_error` is present and null.
- `databases` is a non-empty object. For every database: `upload.spool_head` and
  `upload.spool_confirmed_through` are numbers and equal (acked == head);
  `upload.last_error` and `download.last_error` are null.
- `snapshot.state` is `published` or `installed`, with a `taken_at_ms` and a 64-hex
  `manifest_sha256`.

The driver retries for `LASTDB_BACKUP_WAIT_SECS` (default 300) while the relay is still
confirming the newest writes, then refuses. It records the head of each database. The
same facts are in `lastdb status` (`Cloud sync: connected (prod)`, `Snapshot:`) and in
`status.spool` of `GET /api/status` (`head`, `acked`). Since LastDB 2d3e474a5 the spool
lives in the store's commit; the old `data/disk-run/accepted-v1/state.json` file is gone.

## DEV restore proof (step 4)

`scripts/dev-restore-proof.py` follows the CI recipe of EdgeVector/lastdb
(`scripts/operations/personal_database_proof.py` and `personal_proof_deployed.py`):
a new identity per run, no account, no secret, the deployed DEV relay. It uses the
exact candidate pair and reads nothing of the primary.

1. `lastdb admin backup init --into <dir> --recovery-phrase-out <file> --env dev --json`
   makes a throwaway home and phrase offline.
2. The candidate daemon runs on it with `LASTDB_RELAY_URL` set to the DEV relay
   (`environments.dev.exemem_api` of `lastdb_node/environments.json` at the candidate
   commit). The proof seeds one schema, writes 30 records in 3 batches, waits for
   `acked == head`, runs `lastdb backup snapshot --wait`, writes 10 more records in 2
   batches (the tail), and waits again. The daemon stops with a flush receipt.
3. `lastdb backup restore --recovery-phrase-stdin --relay-url <DEV relay> --into <new dir> --json`
   restores from the phrase alone. The report must name the snapshot (sequence 1) and
   replay exactly the tail.
4. The candidate daemon runs on the restored home. Every record equals what was
   written, key by key, and the key listing has no other key.
5. Both daemons stop; the proof deletes its own temporary directory, phrase included.

The proof prints one `DEV_RESTORE_SUMMARY:` line. The relay keeps the entries and
blobs of each run (a node cannot delete); no cleanup routine exists for them.

## Backup soak (step 10)

After the five-minute health soak, with the new `lastdb` CLI and the new build serving:

- Within `LASTDB_BACKUP_WAIT_SECS` (default 300) `acked` follows `head` again: every
  database that existed before the stop is reported, its head has not moved back, and
  `spool_head == spool_confirmed_through` with no error.
- `lastdb backup snapshot --wait` succeeds (bounded by `LASTDB_BACKUP_SNAPSHOT_WAIT_SECS`,
  default 3600), and the status then shows a published snapshot taken during this run.

A failure here is RED after the cutover. Recovery is the rollback below; the primary
is not restarted on its own.

## Hard rules for the live steps

- Never run a candidate with `--data-dir ~/.lastdb` before the generated trials are GREEN.
- Never replace only `lastdbd`: the sibling `lastdb` of the same build installs with it.
- Never kill or force the old daemon. The strict stop waits for the flush receipt.
- The old program folder is never changed; it is the rollback pair.
- **Bootstrap EIO is a race, not a verdict.** `bootstrap` right after `bootout` can fail
  with `Input/output error`, and launchd returns the same error for an already loaded
  job. The driver waits for the old service to disappear, retries `bootstrap` with
  backoff (`LASTDB_LAUNCHD_BOOTSTRAP_RETRY_DELAYS`, default `2 5 15 30 30 30`), and
  decides by `launchctl print`, never by the exit code. After the retries it prints
  `LASTDB_LAUNCHD_RECOVERY=<exact bootstrap command>` and pages.
- **A leftover socket inode is not a listener.** Success needs a listener pid and `/health`.
- **A nohup start is not GREEN.** KeepAlive must own the new pid.
- Live reads use `live-read.env` (mode 600) under
  `${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/lastdb-nightly-primary-upgrade/`
  (`LASTDB_LIVE_BRAIN_SLUG`, `LASTDB_LIVE_SECRET_SLUG`), or those two variables. The
  secret read is `keys_only`; no secret text is requested. Kanban and Situations are
  off, so `LASTDB_SAFE_UPGRADE_APPS_OFF` defaults to 1: no notice or card step runs.

## Do this, in order

### A. Use Loom for every live cutover

```bash
last-stack-safe-upgrade-loom \
  --candidate /path/to/release/lastdbd \
  --source-git-oid <full-lastdb-commit>
```

The launcher hashes the sibling `lastdbd` and `lastdb` and binds source commit,
paths, hashes and versions into the execution key. An equal candidate is a no-op;
an older, divergent or unknown commit fails closed. A byte change needs a new
execution. The nightly routine `lastdb-nightly-primary-upgrade` downloads the
GitHub nightly pair and calls this launcher; nothing compiles on this machine.

### B. Probe only (no install)

```bash
LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID=<full-lastdb-commit> \
  bash ~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh \
  --candidate /path/to/release/lastdbd --probe-only
```

Steps 1 to 5. The candidate must be a release build with a sibling `lastdb`, never
`target/debug` or `-dirty`. `--version X` fetches that tap release tarball instead.

### C. If the graph or script is missing or fails open

Do not hand-roll a weaker path. Fix the graph or script, or stop. If the skill is
missing on a harness, run `~/.last-stack/setup --host auto` from a clean install tree.

### D. Report to Tom

Print: current to candidate version; qualification links; generated-home result and
peak memory against the limit; the `DEV_RESTORE_SUMMARY:` line; recovery point (heads
per database, snapshot time); cutover seconds; soak result; the rollback commands.

## Reading results

| Output | Meaning | Action |
|--------|---------|--------|
| `VERDICT: GREEN` | Every gate and the live soak passed | Done |
| `VERDICT: GREEN_PROBE_ONLY` | Steps 1 to 5 passed; primary untouched | Start the Loom launcher if Tom wants the upgrade |
| `VERDICT: ALREADY_CURRENT` | Already on the candidate | Nothing |
| `VERDICT: RED` / non-zero exit | A gate failed. Before step 8 the primary is untouched. | Fix the cause; start a new execution |

## Rollback

The old program folder is intact. To return to it:

```bash
# plist ProgramArguments:0 names the old folder (skip when it already names ~/.lastdb/current/lastdbd)
/usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 <old folder>/lastdbd' ~/Library/LaunchAgents/<primary label>.plist
last-stack-lastdb-current set --lastdb-home ~/.lastdb --bin-dir <old folder>
# stop the new daemon with the strict stop (SIGTERM, wait for the flush receipt), then:
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/<primary label>.plist
bash ~/.last-stack/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh --live-read-check
```

`cutover-timeout-recovery.sh` does this from the recovery state when the Loom step
times out. After the candidate serves, recovery keeps the exact candidate and verifies
its supervision, because the home may already hold writes from the new build. If it
never serves, recovery unloads and removes that candidate, restores the old pair, and
keeps the cutover failure status.

**Data.** No copy of the primary exists. If the home is damaged, Tom restores it
himself from the recovery phrase; no agent reads that phrase:

```text
lastdb backup restore --recovery-phrase-stdin --into <new dir> --json
```

Keep the damaged home until the restored node serves real records.

## Related

- `lastdb status` and `lastdb ops` name the load and the caller when the primary is slow
  before an upgrade. Read them first.
- Retained copies from older flows: `scripts/cleanup-retained-upgrade-copy.sh` and
  `scripts/cleanup-retained-rollback.sh` release them (default does not delete;
  `--execute` removes one exact copy).

## Never

- `brew upgrade lastdb` as a one-liner on the primary.
- Run `safe-upgrade-lastdb.sh` without `--probe-only` outside a Loom execution.
- Start a second safe-upgrade while another owns the host-wide lock.
- Copy `~/.lastdb` (also with `cp -cR`) or boot a node on a copy of it.
- Read the primary's `identity.key` or recovery phrase, or print an invite, API key,
  identity seed or phrase in output.
- Pass `--candidate .../target/debug/lastdbd` or any `-dirty` build.
- Restart or kill the primary on a RED trial.
- Run local builds or benchmarks (Tom, 2026-10-23): qualification is the CI of the
  exact source commit.

## Background

Incidents behind the gates: 2026-07-13 wrong-key decrypt brick; 2026-07-16 brew
upgrade on a launchd primary; 2026-07-22 resident memory above the guard (memory
bar); 2026-08-01 debug worktree build cut over (class bar); 2026-08-07 GREEN printed
without restarting the daemon (the running build must report the candidate version);
2026-09-24 SIGKILL five seconds into graceful shutdown (strict stop). The signed-log
backup replaced the earlier native snapshot backup when the primary moved to build cacb31886 on 2026-11-23; this skill follows
`docs/designs/signed-log-on-local-machinery.md` and `relay-protocol.md` in EdgeVector/lastdb.
