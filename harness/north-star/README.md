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
| exemem-hands-off-prod-deploy | read-only deploy-pipeline freeze gate, canary alarm rollback, and CodeDeploy contract, plus redacted evidence (`EXEMEM_HANDS_OFF_PROOF_EVIDENCE_FILE` or the recorded brain proof). No deploy. No LastDB home. PASS requires promotion to 100%, freeze skip, alarm rollback, and visible Sentry failure; the recorded live-fire proof fails the Sentry check | same read-only checks; live mode does not cut over |
| org-cloud-principal-membership | fixture-proven grant/list/presign/revoke/403/owner/E2E contract | two-principal live Org/Mini + storage-service dogfood using only LastSecrets locators |
| lastdb-ideal-storage-shape | validates redacted CoW + dogfood evidence for proteins, backup, plane map, status, and fkanban coherence | same evidence contract; evidence collection remains CoW-first and primary-safe |
| lastdb-io-free-commit-and-barrierless-purge | validates the Fold-generated isolated-copy evidence, warm apply-gate p99, reverse-index audit, and zero purge barriers | requires the same evidence to carry a PASS verdict after safe live cutover |
| lastdb-uuid-hash-group-addressing | validates Fold source contracts and the immutable 11M-document CoW migration proof | runs focused new-home, legacy-read, warm-set, group-backup, and as-is restore tests; preserves the later Tom-authorized primary sync configuration |
| lastdb-no-scan-access | refuses terminal PASS without the keyed scan-deprecation tracker and its completion proof | reads the tracker by slug; never scans, restarts, or mutates LastDB |
| lastdb-cloud-owned-gc | FAIL; no child execution in offline or unknown mode | explicit clean Fold source and exact commit pin; verified child invocation still returns FAIL until P9 supplies the reviewed release-evidence validator |
| lastdb-cloud-transaction-groups | Fold pin-log source contract; PASS-OFFLINE only when the evidence file carries measured CoW output for frontier 1787974212509104000, the restore, and a 24-hour soak window | same evidence contract; does not open a LastDB home and does not start a cloud cutover |
| lastdb-cloud-sync-resume | Fold snapshot+log, upload-interlock, hash-group, and file-blob source contract; PASS-OFFLINE only from measured CoW or ephemeral evidence after Tom clears the pause Situation | offline only; does not open a LastDB home and does not re-enable primary cloud sync |
| lastgit-pack-blobs-b2-migration | LastGit pack-file source contract plus the mocked pack-file test; PASS-OFFLINE only from measured pointer coverage, a verified second backfill, and B2 SHA-256 samples | same evidence contract; does not open a LastDB home and does not start a B2 cutover |
| portable-routine-fleet | bootstrap-kit dry-run for a second project, plus two registry-rotator triggers and two session-miner triggers; no engine edits | same checks; does not open a LastDB home and does not run a canary upgrade |
| lastdb-schema-root-data-attribution | Fold attribution source contract plus one throwaway object graph; PASS-OFFLINE only from redacted isolated-copy evidence with zero unattributed residue and zero unknown user objects after restore | offline only; does not open a LastDB home, does not delete from a source home, and does not run a production cutover |

## Cloud-owned GC: registration is not release proof

This harness has no full-release PASS or PASS-OFFLINE path.
The future P9 validator must verify the actual release evidence before this rule changes.
A source pin permits an invocation. It does not certify a release or authorize cloud or primary operations.

The live invocation requires:

- `CLOUD_OWNED_GC_FOLD_SOURCE`, or the supported `FOLD_REPO` override, names an explicit source root.
- `CLOUD_OWNED_GC_FOLD_SOURCE_OID` is the exact 40-character commit at that root's HEAD.
- The source is a clean Git checkout or DEV worktree. Portal paths, unbound archives, mismatched pins, and dirty sources fail.
- Index flags must not hide changes. Assume-unchanged and skip-worktree entries, including sparse sources, fail inspection.
- The tracked executable `scripts/prove-cloud-owned-gc` matches its pinned Git blob without content filters. Symlink verifiers fail.
- The caller keeps this private source immutable through the invocation. This harness is not a sandbox for untrusted code.

The child runs from that source root with exactly `--require-full-release-proof`.
Offline and unknown modes never resolve the source or execute a child.
No implicit archive of current main is used. An installed archive needs a future verified source resolver before admission.

The harness discards child stdout and stderr directly. It creates no raw child log.
It ignores the old evidence-file input and nonce. The child's legacy evidence-file destination is `/dev/null`.
A nonzero child exit stays nonzero and yields `VERIFIER_NONZERO_EXIT`; the generic runner aggregates failures as exit one.
A zero child exit yields `FULL_RELEASE_EVIDENCE_CONTRACT_UNIMPLEMENTED`, also with a nonzero harness exit.
Markdown, JSON, PASS text, and self-declared private or full-release checklists never establish release truth.

The report contains fixed reason codes, verified source identifiers, and the numeric child exit, not child claims or payloads.
It replaces prior PASS before helper load, source checks, or child execution. It remains FAIL through unexpected exits.
If the report cannot be written, the harness refuses child execution. No software can overwrite a report on an unwritable filesystem.
The harness does not claim a completed proof after an uncatchable process or host failure.

P9 still owns the reviewed evidence validator and its exact release, service, binary, scope, epoch, and receipt bindings.
It also owns physical absence, retained controls, crash recovery, concurrent publication, device disconnect, fresh restore, and byte reconciliation.
Private DEV evidence does not satisfy the full release proof. Production activation still requires its separate approval.
Fixture success verifies these refusal rules only; it is never a P9 success claim.

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
