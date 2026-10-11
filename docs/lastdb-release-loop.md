# The LastDB release loop on the app registry

North Star: brain `north-star-lastdb-app-registry-release-loop`. Decision:
`decision-2026-09-19-app-registry-is-the-release-unit`. Index grammar: fold
`docs/lastdb-app-registry-index.md`.

One unit of release: a LastDB build plus the app commits proved with it. A
public user installs an app and gets the newest commit that was proved with
the LastDB build on their machine. Tom's Mac and a fresh public install draw
from the same proved rows.

## The two routines

| Routine | Cadence | Gate | Does |
|---|---|---|---|
| `lastdb-canary-candidate-set` | nightly 02:47 PT | `last-stack-canary-candidate-gate` | build → candidate set → isolated smoke → primary cutover → rows to `next` |
| `lastdb-canary-soak-watch` | hourly | `last-stack-canary-reconcile-gate` | v2 quiet-window verdict; on green writes `PROMOTE.md`, **publishes stable** (`release-publish --if-needed`), notifies |

`lastdb-canary-build-main`, `lastdb-canary-dogfood`,
`lastdb-canary-promote-prepare`, and `lastdb-canary-red-heal` are removed.
`bin/last-stack-lastdb-canary-candidate-set-routine --retire-superseded`
pauses their live registry entries.

## The nightly candidate gate, step by step

1. **build** — `last-stack-canary-build-main --json` stages public LastDB `main`
   from GitHub under `~/.local/state/last-stack/canary-builds/<oid>/`.
   The build and stage require `lastdb` and `lastdbd` from the same source.
   The removed synthetic restore probe and harness are not required.
   Stage reuse keeps the source manifest check. The build keeps equal versions
   and refuses dirty binaries. The normal real-copy safe upgrade checks the
   exact source, pair hashes, versions, restore receipt, and primary protection.
   The resolver keeps its existing source and SHA drift fields. Legacy JSON
   fields `lastdb_restore_probe` and `restore_probe_script` always return null.
   The legacy `--allow-no-restore-script` flag is a deprecated no-op.
   `--allow-daemon-only` stays explicit; backup restore still requires the pair.
2. **resolve** — `last-stack-lastdb-canary-dogfood --dry-run --json` names the
   candidate build and binary; the pipeline `channels` command applies the
   cutover-hold policy. Same build as the primary → `noop`.
3. **set** — `last-stack-canary-candidate-set --lastdbd <bin>` fixes one commit
   per app from `config/registry/apps.json`: the app's artifact channel head
   (built and green-published), else `main` of the app's gate of record. Since
   LastGit era 3 the gate of record is the `lastgit` field
   (`lastdb:///<repo>`). The Forgejo copy (`forge`) is frozen. The set probes
   each pin on LastGit first and then on Forgejo, and takes the first source
   that serves it. A commit released before the cutover to a LastGit repo that
   was seeded from a squash is on Forgejo only (NOTE, `source_fallback_from`).
   A pin that no source serves gets a WARNING and `source_reachable: false`.
   Each row records `source` (the clone source for `--pins`, and the `next`
   row source), `source_venue`, and `public_source`. Output:
   `$ROUTINES_RUN_DIR/candidate-set.json`.
4. **smoke** — `skills/llms-txt-install-smoke/run.sh --json` with
   `SMOKE_LASTDBD_BIN=<candidate lastdbd>` and `SMOKE_CANDIDATE_SET=<file>`.
   The sandbox boots the candidate daemon, puts the candidate `lastdb` first on
   PATH, and `last-stack-install-apps --pins <file>` checks out exactly the
   pinned commits. A `lastdb://` source reads the login user's node
   (`LASTGIT_SOCKET`, `LASTGIT_SCHEMA_MAP`), because the sandbox HOME has no
   node. The installer tries every app, also after one app fails, and writes a
   `failed` receipt with the stage for each app that fails. Receipts must read
   `pinned`; anything else is RED. RED stops here: no cutover, no rows, a
   build-subject line event in the ledger.
5. **cutover** — `last-stack-lastdb-canary-dogfood --cutover --json` (the
   safe-upgrade probe, DEV photograph, and primary cutover; unchanged).
6. **rows** — `last-stack-registry-publish-next --candidate-set … --proof …`
   adds one compat row per app to `registry/next.json` on the tap repo, writes
   `registry/proofs/<proof_run>.json`, signs with the existing
   `LASTDB_REGISTRY_SIGNING_KEY_LASTSECRETS=lastsecrets://<existing-key-slug>`
   key. LastSecrets sends the key directly to `lastdb app index sign` through stdin, and
   opens an auto-merging GitHub PR on `EdgeVector/homebrew-lastdb`
   (`gh pr merge --squash --auto`; branch protection requires `ci-required`
   and blocks a direct push to `main`). Since 2026-09-30 GitHub is the tap's
   gate of record, and `lastdb app resolve` reads it. The LastGit and Forgejo
   copies are frozen: a row merged there never reaches a reader.
   Publication refuses the retired LastGit and Forgejo venues. The brew formula bump goes through the same PR path
   (`last-stack-brew-app-publish`, and fold's promote script with
   `--formula-venue github`).

## Promote material and the automatic publish

On a green quiet window (1 h since 2026-09-24, was 24 h; v2 verdict;
`LAST_STACK_CANARY_V2_WINDOW_SECONDS` overrides) the reconciler runs
`last-stack-canary-promote-material`. It writes
`~/.local/state/last-stack/canary-promote/<date>/PROMOTE.md` with the node
build and the `next` rows proved with it, then runs:

```bash
last-stack-release-publish --lastdb-version <build> --if-needed
```

That command does two things together: LastDB's
`forge-promote-homebrew-stable.sh --publish` (bottle to the public CDN, formula
PR on the GitHub tap) and `last-stack-registry-index promote` (the `next` rows
for that build → `registry/stable.json`, sources rewritten to the public GitHub
mirrors from `config/registry/apps.json`, every commit fetched from its public
source first, signed, second auto-merging PR). `--if-needed` refuses a build
with no proved `next` rows, skips a half that is already public, and exits 0
when nothing is left. The result is appended to `PROMOTE.md` and sent with the
notify. Since 2026-09-21 a green quiet window is the stable decision
(decision-2026-09-21-stable-publish-is-automatic-on-green); the 2026-09-19
"human until five clean promotes" rule is retired after promote #1.
`LAST_STACK_RELEASE_AUTO_PUBLISH=0` returns the action to material-only.
`--dry-run` by hand shows both halves without writing anything public.

Stable publication requires two independent clean registered portal DEV worktrees.
Create them from the `homebrew-lastdb` portal with `bin/wt start`.
Set `LAST_STACK_FORMULA_TAP_DIR` and `LAST_STACK_REGISTRY_TAP_DIR` to those roots.
Each root must be under `~/.fkanban/worktrees` and at accepted GitHub main.
The publisher checks the portal marker, portal cache, and reciprocal Git registration.
It refuses a scratch linked worktree and keeps the caller's files.

Set `LASTDB_REGISTRY_SIGNING_KEY_LASTSECRETS` to the existing key locator.
The native signer reads the key from stdin at the point of use.
The publisher does not write a key file or change the public trust identity.
Normal `gh` authentication serves the GitHub commands.
The publisher does not retrieve a GitHub token into a receipt or log.

Before either public change, the publisher verifies the selected signed rows,
the current hosted install/startup proof, exact app and Mini OIDs, and source reachability.
The one-hour quiet verdict remains a separate required gate.
Source checks and help output do not prove an actual signature or publication.

Each external create has a bounded owner-only receipt before and after its request.
The receipt keeps the exact build, Mini OID, tag, DEV base, branch, head, and known public URLs.
PR creation and automatic merge are separate stages.
Each automatic merge request binds the exact prepared head with `--match-head-commit`.
A later failure keeps the known release and PR outputs.
An unknown outcome stays requested and holds publication.

The durable identity file is `canary-promote/release-attempts/<build-and-OID-SHA256>.json`.
A retry retains the original tag and refuses a new create while that exact attempt exists.
Read the exact saved tag, branch, release, and PR through GitHub before recovery.
Do not delete the receipt, choose a new tag, reset the DEV root, or repeat an unknown create.
Normal required tap CI and the automatic merge gate remain active.
After both changes reach accepted tap main, `--if-needed` returns the existing result.
The same tag stays held until that state or an explicit reviewed recovery.

The explicit legacy `promote-execute` command also requires `LAST_STACK_FORMULA_TAP_DIR`.
It passes the supplied root to the same strict public helper.
It does not replace the hourly `promote-material` path or alter its quiet window.

## Install by proof

- Public: `last-stack-install-apps` asks `lastdb app resolve <app> --channel
  stable` for each app and checks out that commit. Receipts land in
  `~/lastdb-apps/.lastdb-app-receipts/<app>.json` with `mode` = `proved`,
  `pinned`, `unproved-main`, or `failed` (with `stage` = `source`,
  `dependencies`, or `link`). One failed app does not stop the others; the
  installer exits 1 after all apps and names each failure. A `lastdb` without `app resolve` falls back to
  `main` and says so. No proved row for this node fails closed unless
  `--allow-unproved`.
- Tom's Mac: host-track follows the registry `next` channel
  (`config/host-track/apps.json` defaults `registry_channel` /
  `registry_index`). For an app on the index, the desired oid is the proved
  commit, and the artifact with that `source_oid` is installed. No proved row
  → hold the current install (`refresh` exits 75, status
  `registry_pin_state=no-proved-row`, not stale). Apps not on the index keep
  following their artifact channel head.

### Reading a pin that is behind

Proof rows are keyed on `(app, lastdb_version)`, and `lastdb app resolve` returns
only the newest row for the build the host runs. So `registry_pin_proved_at` and
`registry_pin_proof_run` describe the frontier **for this build**, and a frontier
can be a day old while the index is filled briskly for another build. The two
causes have opposite remedies, so `status` reports the discriminator next to the
lag, for a pin that is behind only:

| field | meaning |
|---|---|
| `registry_lastdb_version` | the build this host runs, which `resolve` filters on |
| `registry_index_newest_version` | the build of the index's newest row for this app, across ALL builds |
| `registry_index_newest_proved_at` / `_oid` | when that row was proved, and the commit it proves |
| `registry_index_build_match` | `match` · `mismatch` · `no-rows` · `unread` |

`mismatch` means the prover is working on a build this host does not run: no
cadence change and no resume can clear it. Prove the running build, or finish the
move to the newer one. `match` means the frontier is as current as the index, so
`registry_pin_proof_age_secs` decides whether the prover stopped. `unread` means
the read failed and no cause was measured. When
`registry_index_newest_oid == pin_behind_oid`, the commit the host is waiting for
is **already proved** and only the build differs — measured on `brain` and
`routines` on 2026-10-03, both held 33 h on a commit proved 24 minutes earlier.

### Who tells you, without being asked

Every field above renders to `host-track status` and nothing else used to read
any of them, so the freeze reached whoever happened to look. Two readers now do.

`last-stack-why-stopped` Class H fires when the frontier for the running build
is older than 30 h and an app has merged past it. It is the fuller verdict, and
it is dispatched by the routines fleet — so it is silent exactly when the fleet
is paused, which is the posture that produced the 34 h freeze on 2026-10-03.

`last-stack-load-collector` is a LaunchAgent and runs every 30 s regardless of
the fleet, so it carries the live surface. It cannot afford a 10 s
`host-track status --json`, so it reads an observation file instead:

| | |
|---|---|
| Written by | `status_json_for`, whenever a pin is holding an install. `refresh_app` calls it for every app, and the `host-track-refresh` agent runs `refresh --all` every 1200 s, so the file is kept current unattended at no extra cost |
| Where | `~/.local/state/last-stack/host-track-frontier/<app>.json` (`HOST_TRACK_FRONTIER_DIR`) |
| Holds | the five fields above, plus `observed_at`, `first_observed_at`, and the verb that wrote it |
| Removed | the moment the pin stops holding, so a stale file never reads as a live freeze |

The notice (`registry_delivery_frozen`, `--system host-track`, severity `warn`)
fires on `index_build_match == mismatch` **and** an index row proved AFTER the
hold began. That second clause is the whole point: after a LastDB version change
every pinned app legitimately holds until the prover writes a row for the new
build, and an age threshold calls that benign wait a freeze. A row proved for
another build while this app is already held is proof the prover is alive and
will never serve this host, which no amount of waiting fixes.

Cold start: `first_observed_at` begins when the file is first written, so a
freeze already in progress when the observation starts needs one more prover
row before the notice fires. On this fleet the GitHub `registry-proof` workflow
runs at `cron: 7,37`, so that is under half an hour.

## Terminal proof

`last-stack-north-star-app-registry-release-loop-proof` writes
`~/.last-stack/north-star-proofs/north-star-lastdb-app-registry-release-loop.md`.
PASS means: `lastdb app install brain kanban situations` from brew stable
resolved every app by proved pair, each installed row names a proof record on
the index host, and the llms-txt install smoke is GREEN with install-by-proof
enforced. Rehearse against a local index with `--lastdb-bin … --index <dir>`.

## Keys and files

| | |
|---|---|
| Signing key | Existing `lastsecrets://` locator in `LASTDB_REGISTRY_SIGNING_KEY_LASTSECRETS`; native signer stdin |
| Verifying key | pinned in `lastdb` (`lastdb app index trust-key`); published as `registry/index-signing.pub` |
| Publication DEV roots | Independent `LAST_STACK_FORMULA_TAP_DIR` and `LAST_STACK_REGISTRY_TAP_DIR` portal worktrees |
| Partial release receipts | Owner-only `canary-promote/release-attempts` plus exact formula proof path |
| Candidate sets | `~/.local/state/last-stack/canary-candidate-sets/<build>.json` |
| Promote material | `~/.local/state/last-stack/canary-promote/<date>/PROMOTE.md` |
| App set | `config/registry/apps.json` (forge + public source per app) |
