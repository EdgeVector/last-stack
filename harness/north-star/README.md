# North Star terminal proof harnesses

Product-grade entrypoint: `bin/last-stack-north-star-proof`.

Each active North Star has a `run.sh` that proves its end state on **throwaway**
surfaces (never the primary `~/.lastdb` brain).

```bash
last-stack-north-star-proof --list
last-stack-north-star-proof --offline all          # CI-safe default
NORTH_STAR_PROOF_MODE=live last-stack-north-star-proof north-star-coderings
```

Reports: `$NORTH_STAR_PROOF_DIR` or `~/.last-stack/north-star-proofs/<slug>.md`.
First line is `PASS`, `PASS-OFFLINE`, or `FAIL` for kanban DONE-WHEN matching.

| Slug | Offline proof | Live proof |
|---|---|---|
| coderings | fixture capstone exerciser | same (+ optional --real-node) |
| deliver-slices | import + FoF unittest | `discovery/scripts/dogfood_one_loop.sh` |
| lastgit | dogfood contract + install smoke | `lastgit/test/native-forge-dogfood.sh` |
| metering | audit script contract | `audit-storage-metering.sh` + API key |
| minimal-node | throwaway lastdbd boot | CoW smoke skill |
| app-ops | `lastdb ops --by-app` | same against live Mini |
| schema | no-wasm tree gate | fold capstone `run.sh` when landed |
| file-blobs-on-demand-sync | fold source/test contract + optional narrow cargo tests | same narrow fold proof command on a non-primary checkout |
| laststore-is-document-store-last-db-is-conventions | Brain record/design contract, fixtureable via `LASTSTORE_PROOF_RECORD_FILE` | same Brain contract against the live record |
| mini-brain-observability | Fold source contract for `lastdb status`, session/crash attribution, self-metrics, dashboard regen, health alert, and dogfood hooks | same checks against current source; never restarts the primary daemon |
| host-track | artifact registry invariant + per-app host-track checks, writing a North Star proof report | same checks against current registry; never edits the install |
| exemem-cloud-account | redacted evidence contract via `EXEMEM_CLOUD_ACCOUNT_PROOF_EVIDENCE_FILE`, or CLI drive against `EXEMEM_CLOUD_ACCOUNT_LASTDB_HOME` (never `~/.lastdb`; never pays) | `lastdb cloud status` + `lastdb cloud account --json --no-open` on a throwaway connected home; upgrade is help-only (decision-2026-08-17: existing paid account, no fresh checkout) |
| org-cloud-principal-membership | fixture-proven grant/list/presign/revoke/403/owner/E2E contract | two-principal live Org/Mini + storage-service dogfood using only LastSecrets locators |
| lastdb-ideal-storage-shape | validates redacted CoW + dogfood evidence for proteins, backup, plane map, status, and fkanban coherence | same evidence contract; evidence collection remains CoW-first and primary-safe |
| lastdb-io-free-commit-and-barrierless-purge | validates the Fold-generated isolated-copy evidence, warm apply-gate p99, reverse-index audit, and zero purge barriers | requires the same evidence to carry a PASS verdict after safe live cutover |
| lastdb-uuid-hash-group-addressing | validates Fold source contracts and the immutable 11M-document CoW migration proof | runs focused new-home, legacy-read, warm-set, group-backup, and as-is restore tests; preserves the later Tom-authorized primary sync configuration |

## Org cloud principal membership

The live proof writes
`$NORTH_STAR_PROOF_DIR/north-star-org-cloud-principal-membership.md` (default
`~/.last-stack/north-star-proofs/…`) with `PASS` on its first line only after
the full two-principal sequence succeeds. Configure it with locators, not raw
keys:

```bash
NORTH_STAR_PROOF_MODE=live \
ORG_CLOUD_MEMBERSHIP_ORG_SLUG=<org-slug> \
ORG_CLOUD_MEMBERSHIP_MEMBER_USER_HASH=<member-user-hash> \
ORG_CLOUD_MEMBERSHIP_OWNER_API_KEY_REF=lastsecrets://<owner-api-key> \
ORG_CLOUD_MEMBERSHIP_MEMBER_API_KEY_REF=lastsecrets://<member-api-key> \
ORG_CLOUD_MEMBERSHIP_STORAGE_URL=https://<storage-service> \
ORG_CLOUD_MEMBERSHIP_OWNER_SOCKET="$HOME/.lastdb/data/folddb.sock" \
last-stack-north-star-proof north-star-org-cloud-principal-membership
```

The command never restarts Mini. After a successful grant, any later failure
attempts a revoke before exiting. The artifact contains only redacted hashes
and pass/fail state; API keys and the shared E2E key are never persisted.
