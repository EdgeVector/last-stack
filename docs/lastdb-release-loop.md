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
| `lastdb-canary-soak-watch` | hourly | `last-stack-canary-reconcile-gate` | v2 quiet-window verdict; on green writes `PROMOTE.md` + notifies |

`lastdb-canary-build-main`, `lastdb-canary-dogfood`,
`lastdb-canary-promote-prepare`, and `lastdb-canary-red-heal` are removed.
`bin/last-stack-lastdb-canary-candidate-set-routine --retire-superseded`
pauses their live registry entries.

## The nightly candidate gate, step by step

1. **build** — `last-stack-canary-build-main --json` stages Forge fold `main`
   under `~/.local/state/last-stack/canary-builds/<oid>/`.
2. **resolve** — `last-stack-lastdb-canary-dogfood --dry-run --json` names the
   candidate build and binary; the pipeline `channels` command applies the
   cutover-hold policy. Same build as the primary → `noop`.
3. **set** — `last-stack-canary-candidate-set --lastdbd <bin>` fixes one commit
   per app from `config/registry/apps.json`: the app's artifact channel head
   (built and green-published), else Forge `main`. Output:
   `$ROUTINES_RUN_DIR/candidate-set.json`.
4. **smoke** — `skills/llms-txt-install-smoke/run.sh --json` with
   `SMOKE_LASTDBD_BIN=<candidate lastdbd>` and `SMOKE_CANDIDATE_SET=<file>`.
   The sandbox boots the candidate daemon, puts the candidate `lastdb` first on
   PATH, and `last-stack-install-apps --pins <file>` checks out exactly the
   pinned commits. Receipts must read `pinned`; anything else is RED. RED stops
   here: no cutover, no rows, a build-subject line event in the ledger.
5. **cutover** — `last-stack-lastdb-canary-dogfood --cutover --json` (the
   safe-upgrade probe, DEV photograph, and primary cutover; unchanged).
6. **rows** — `last-stack-registry-publish-next --candidate-set … --proof …`
   adds one compat row per app to `registry/next.json` on the tap repo, writes
   `registry/proofs/<proof_run>.json`, signs with
   `~/.lastdb/registry-index-signing.key` through `lastdb app index sign`, and
   opens an auto-merging Forgejo PR on `EdgeVector/homebrew-lastdb`.

## Promote material and the one human command

On a green quiet window the reconciler runs `last-stack-canary-promote-material`.
It writes `~/.local/state/last-stack/canary-promote/<date>/PROMOTE.md` with the
node build, the `next` rows proved with it, and:

```bash
last-stack-release-publish --lastdb-version <build>
```

That command does two things together: fold's
`forge-promote-homebrew-stable.sh --publish` (bottle to the public CDN, formula
PR on the Forgejo tap) and `last-stack-registry-index promote` (the `next` rows
for that build → `registry/stable.json`, sources rewritten to the public GitHub
mirrors from `config/registry/apps.json`, every commit fetched from its public
source first, signed, second auto-merging PR). `--dry-run` shows both without
writing anything public. Stable stays a human action until five clean manual
promotes.

## Install by proof

- Public: `last-stack-install-apps` asks `lastdb app resolve <app> --channel
  stable` for each app and checks out that commit. Receipts land in
  `~/lastdb-apps/.lastdb-app-receipts/<app>.json` with `mode` = `proved`,
  `pinned`, or `unproved-main`. A `lastdb` without `app resolve` falls back to
  `main` and says so. No proved row for this node fails closed unless
  `--allow-unproved`.
- Tom's Mac: host-track follows the registry `next` channel
  (`config/host-track/apps.json` defaults `registry_channel` /
  `registry_index`). For an app on the index, the desired oid is the proved
  commit, and the artifact with that `source_oid` is installed. No proved row
  → hold the current install (`refresh` exits 75, status
  `registry_pin_state=no-proved-row`, not stale). Apps not on the index keep
  following their artifact channel head.

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
| Signing key | `~/.lastdb/registry-index-signing.key` (`LASTDB_REGISTRY_SIGNING_KEY`) |
| Verifying key | pinned in `lastdb` (`lastdb app index trust-key`); published as `registry/index-signing.pub` |
| Tap checkout the lane uses | `~/.local/state/last-stack/registry-tap` |
| Candidate sets | `~/.local/state/last-stack/canary-candidate-sets/<build>.json` |
| Promote material | `~/.local/state/last-stack/canary-promote/<date>/PROMOTE.md` |
| App set | `config/registry/apps.json` (forge + public source per app) |
