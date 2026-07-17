# North Star terminal proof harnesses

Product-grade entrypoint: `bin/last-stack-north-star-proof`.

Each active North Star has a `run.sh` that proves its end state on throwaway
surfaces or source-controlled fixture checks. Harnesses must never target the
primary `~/.lastdb` brain.

```bash
last-stack-north-star-proof --list
last-stack-north-star-proof --offline all
NORTH_STAR_PROOF_MODE=live last-stack-north-star-proof north-star-coderings
```

Reports: `$NORTH_STAR_PROOF_DIR` or
`~/.last-stack/north-star-proofs/<slug>.md`. The first line is `PASS`,
`PASS-OFFLINE`, or `FAIL` for kanban DONE-WHEN matching.

| Slug | Offline proof | Live proof |
|---|---|---|
| coderings | fixture capstone exerciser | same (+ optional `--real-node`) |
| deliver-slices | import + FoF unittest | `discovery/scripts/dogfood_one_loop.sh` |
| lastgit | dogfood contract + install smoke | `lastgit/test/native-forge-dogfood.sh` |
| metering | audit script contract | `audit-storage-metering.sh` + API key |
| minimal-node | throwaway lastdbd boot | CoW smoke skill |
| app-ops | `lastdb ops --by-app` | same against live Mini |
| schema | no-wasm tree gate | fold capstone `run.sh` when landed |
| file-blobs-on-demand-sync | fold source/test contract + optional narrow cargo tests | same narrow fold proof command on a non-primary checkout |
