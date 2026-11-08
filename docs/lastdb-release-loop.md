# The LastDB release loop on the app registry

North Star: brain `north-star-lastdb-app-registry-release-loop`. Decision:
`decision-2026-09-19-app-registry-is-the-release-unit`. Index grammar: fold
`docs/lastdb-app-registry-index.md`.

One unit of release: a LastDB build plus the app commits proved with it. A
public user installs an app and gets the newest commit that was proved with
the LastDB build on their machine. Tom's Mac and a fresh public install draw
from the same proved rows.

## Install by proof

- Public: `last-stack-install-apps` asks `lastdb app resolve <app> --channel
  stable` for each app and checks out that commit. Receipts land in
  `~/lastdb-apps/.lastdb-app-receipts/<app>.json` with `mode` = `proved`,
  `pinned`, `unproved-main`, or `failed` (with `stage` = `source`,
  `dependencies`, or `link`). One failed app does not stop the others; the
  installer exits 1 after all apps and names each failure. A `lastdb` without `app resolve` falls back to
  `main` and says so. No proved row for this node fails closed unless
  `--allow-unproved`.

## Terminal proof

`last-stack-north-star-app-registry-release-loop-proof` writes
`~/.last-stack/north-star-proofs/north-star-lastdb-app-registry-release-loop.md`.
PASS means: `lastdb app install brain situations` from brew stable
resolved every app by proved pair, each installed row names a proof record on
the index host, and the llms-txt install smoke is GREEN with install-by-proof
enforced. Rehearse against a local index with `--lastdb-bin … --index <dir>`.

Kanban is outside the required bundle and proof set (Tom, 2026-11-06).
Its registry metadata remains available for deliberate selection; this does
not uninstall it or remove app source or data. Situations remains required.

## Keys and files

| | |
|---|---|
| Signing key | Existing `lastsecrets://` locator in `LASTDB_REGISTRY_SIGNING_KEY_LASTSECRETS`; native signer stdin |
| Verifying key | pinned in `lastdb` (`lastdb app index trust-key`); published as `registry/index-signing.pub` |
| Publication DEV root | `LAST_STACK_REGISTRY_TAP_DIR`, the clean DEV worktree for `last-stack-registry-publish-next` |
| Candidate sets | `~/.local/state/last-stack/canary-candidate-sets/<build>.json` |
| App set | `config/registry/apps.json` (forge + public source per app) |
