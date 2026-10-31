# LastDB home copy for the protein removal

This document gives the Brain migration path for the protein removal on the primary LastDB.
On 2026-10-30 the in-place Brain conversion was removed. This home copy is the only Brain migration path.
The path makes a new home, copies the kept records into it, and then moves the homes.

The helper is `bin/last-stack-lastdb-home-copy`.
It is one Python file. It uses only the two daemon sockets.

CAUTION: Nobody ran this runbook on the primary. Only the read-only plan and census ran on the primary.

CAUTION: Tom permits cloud backup to stay off during this work, and requires it on again after the cutover (Step 12).
The primary cutover also needs separate authorization. This document does not authorize a primary change.

## 1. Summary

- The old home `~/.lastdb` stays as it is. It becomes the rollback home.
- A new home gets the same identity and cloud credentials, and no data.
- A second daemon serves the new home on its own socket. It runs the protein-free release (#803, API 13).
- The new Brain and LastSecrets releases declare their own schemas on the new home.
- The helper reads every kept record from the old daemon and writes it to the new daemon in batches.
- The helper verifies each schema by key set, by a value digest per record, by file bytes, and by spot reads.
- A short write freeze copies the last changes. Then the homes change places.

The plan and census on the primary found no value problem. Design has 38 records and a stored count of 37. The coordinator accepted 38 on 2026-10-30. The runbook names that value with `--accept-directory-count design=38`.

Tom renamed the Brain app id from `fbrain` to `brain` on 2026-10-30 (brain#484). The old Brain schemas have the owner `fbrain`. The new Brain schemas have the owner `brain`. The runbook declares that change with `--source-owner fbrain --target-owner brain`.

The second synthetic proof passed end to end on the #803 pair (head 9196e5be9) from CI with the renamed Brain (brain#484 at 7c0a573e0). It covered `brain init` with all 25 schemas, the copy, the verify, the export, and the home move on a format 6 store (section 5). #803 accepts the keyless `BrainCompactListLocator_v1` since a83d5f06d (B10 is closed). The third run (section 5.6) passed on the signed pair of the merged release (main e13ca0db) with brain#484 at 2f7b54e4b and lastsecrets#14 at 6883d2632, after one helper fix.

## 2. Answers to the eight questions

Source references name the LastDB revision of #803 at 209d4ec0 unless the text says "OLD" (a1c406f5).

### Q1. A new home with the same identity and the same backup credentials

- `lastdb --data-dir <old> cloud prepare-recovery-home --into <new> --env prod --api-key-stdin --json` makes the home.
  - It reads only `identity.key` and `cloud_sync.json.paused` from the old home (`recovery_home.rs:102-130`).
  - It writes `identity.key`, `cloud_sync.json.paused`, and an empty `.cloud_resume_required`. It makes no `data/` (`:116-120`).
  - The key on stdin must equal the saved key, and the saved URL must equal the PROD URL (`:107-113`).
  - It does not open the database, so it is safe while the old daemon runs. The OLD CLI has the same command (OLD `cli_defs/cloud.rs:55`).
- The NEW daemon boots on that home and makes a format 6 store (`alternate-keys=v2`) with the same identity (`run_admission.rs:13-14`).
- The daemon mints a new identity when `identity.key` is absent (`lastdb_identity/src/lib.rs:57-66`). Prepare the home before the first start.
- The OLD daemon opens format 4 only. It can never open the new home.

Backup V2 uses a new stream for the new home.

- The worker uses `data/cloud-byte-backup-v2/stream.json` again only for the same native home id (`worker/stream.rs:41-73`). Each new store gets a random native home id.
- `backup-v2 connect --existing --env prod --api-key-stdin [--expected-user-hash H]` connects the new home to the same account. It writes `cloud-byte-backup-v2-manual.json` (`connection.rs:20,66-85`).
- The old stream stays in the cloud. A NEW restore accepts format 4, 5, and 6 backups. An OLD restore accepts format 4 only.

### Q2. A second daemon on its own socket

- `lastdbd` flags: `--data-dir`, `--socket-path` (default `<home>/data/folddb.sock`), `--full-socket-path` (`lastdbd/cli.rs:17-36`). OLD has the same flags.
- The daemon has no TCP listener, no global lock file, no Keychain item, and no launchd label in code.
- The daemon reads the service-home file only when `--data-dir` and the home variables are absent (`service_home.rs:11-58`). Always give `--data-dir`.
- The daemon refuses a socket that has a live listener (`lastdb_uds/src/uds.rs:241-257`). A socket path has a limit of 103 bytes.
- The `lastdb` CLI goes to `<home>/data/folddb.sock` for `--data-dir <home>`. The `backup-v2` commands always use that path and ignore `LASTDB_SOCKET_PATH`.
- A daemon with `--socket-path` elsewhere makes no socket in `<home>/data/`. The synthetic proof showed this.

### Q3. The program pair without a local build

| Workflow | What it builds | Limit |
|---|---|---|
| `mini-upgrade-artifact.yml` | An accepted main commit only (`git merge-base --is-ancestor`). Signed release pair. | 14 days. A PR head fails the source check. |
| `native-dev-artifact.yml` | A PR head, only with the label `native-dev-artifact`. | 3 days. No strip, no explicit sign. No `workflow_dispatch`. |
| benchmark build | Ubuntu programs. | Not usable on macOS. |

On 2026-10-30 the label `native-dev-artifact` went on #803. The workflow builds a pair for each new head. Run 41134992191 built the pair for head 9196e5be9. The second synthetic proof used that pair (section 5.1). Run 41126284642 built the pair for head 11280163c for the first proof.

The dev pair is for proof runs only. It has an adhoc linker signature and a 3-day life.
The primary cutover uses the signed pair from `mini-upgrade-artifact.yml` after #803 merges (Step 2).

### Q4. How the apps declare schemas on the new home

- Brain (brain#484 at 7c0a573e0): `brain init` with a staging config. The app id is `brain`. The variables are `BRAIN_CONFIG` and `BRAIN_FOLDDB_SOCKET`. The socket variable wins over the config (`src/client.ts:186`). brain#484 removed the `FBRAIN_*` variables and the `~/.fbrain` fallback.
  - Init declares 25 owned schemas with the owner `brain` and the canonical field names. The config gets `schemaFieldAliases` and `storageModel: multi-key-v1`.
  - Init refuses a config with the old shared-value layout (`home_copy_required`, `src/commands/init.ts:301`). Use a new staging config.
  - #803 accepts the keyless `BrainCompactListLocator_v1` since a83d5f06d (one field, no alternate keys). The first proof on head 11280163c stopped there (B10, closed).
  - The soft-delete tag is `__brain_deleted__` and the backlink tag prefix is `__brain_backlink__:`. The old Brain wrote `__fbrain_deleted__` and `__fbrain_backlink__:`. The helper renames these tags (section 3.2).
  - The capability files are `~/.brain/capabilities/brain@<hash>.cap`. The old `fbrain@<hash>.cap` files stay, but the new Brain does not read them.
  - Init writes `appIdentityEnforce: false` for a new config (`src/owned-schema-init.ts:155`, `src/commands/init.ts:501`). The installed config has `true`. The coordinator decided `true` for the new config on 2026-10-30. Step 5 sets it.
  - With `false`, the client sends no capability headers. The writes go in as the node owner (`src/write-context.ts:79-100`).
- LastSecrets (lastsecrets#14): `lastsecrets init --config <path> --socket <path>`. On a new home the vocabulary mode is `auto`, so init declares the canonical names. The aliases `lastsecrets/LastSecret` and `lastsecrets/LastSecretIndex` go away.
- The NEW node sends each declaration to the Schema Service of the environment in `cloud_sync.json.paused`. For this home that is PROD.
  - The variables `FOLD_SCHEMA_SERVICE_URL`, `ENVIRONMENT`, and `EXEMEM_ENV` override the home file. Step 4 removes them from the daemon environment.
  - In the synthetic proof (a DEV home), each declaration found the DEV definition and reused it. The node registered nothing new.
- Every new declaration on NEW uses independent fields (`load/owned.rs:12`). NEW refuses to start when a stored schema has the shared-value layout. An empty home passes.

CAUTION: The Brain definitions must be in the PROD Schema Service before Step 5. Tom allowed the publish on 2026-10-30. A separate agent does it. See blocker B2.

### Q5. Copy routes, file bytes, and what the copy does not keep

Read routes (the helper permits only these on the source):

- `GET /api/schemas?include_system=true`, `GET /api/schema/<name>`, `GET /api/version`.
- `GET /api/list?schema=&limit=1000&cursor=`. It lists live keys only. A tombstone does not appear.
- `POST /api/query` with `HashRangeKeys`, at most 1000 keys.
- `POST /api/db/fetch-file-blob {pointer}`. It returns the bytes and the `file_hash`.

Write routes (target only, with `--apply`):

- `POST /api/mutations/batch` with `create`, `update`, or `delete`, `durability: durable`, `convergence: sync`.
- `POST /api/db/put-blob-local {bytes_b64, name, media_type}`. It returns a new pointer for the target.
- `POST /api/db/flush {}` at the end.

File bytes: the helper fetches each file from the source and checks its sha256. It stores the bytes on the target with the same name and media type, checks the returned `file_hash`, and writes the new pointer.
The target encrypts the file with its own keys (`sharing/file_blob_seal.rs:99-113`). The `blob_ref` and the `dek` change. The bytes stay the same.

The copy keeps:

- The current value of each kept field, at the same key.
- The plain bytes of each file.
- The identity, the user hash, and the cloud account.

The copy does not keep:

- The atom history (old versions), the atom UUIDs, the author key and signature, and the write clocks and times.
- The molecule IDs. The NEW node builds new molecules for each write.
- The tombstones of deleted records.
- The old file `blob_ref` and `dek`.
- The old V2 backup stream. The new home starts a new stream.
- The schemas on the not-moved list (section 4.3).

### Q6. Field mapping and derived records

For each field the helper maps three names:

1. The old stored name (the source schema field).
2. The app local name. The old config `schemaFieldAliases` gives it, or the stored name is the local name.
3. The new stored name. The new config `schemaFieldAliases` gives it, or the release `src/canonical-fields.json`.

A field with no map is an issue. The helper does not write a record with an issue.
The helper checks each value against the target field type. It mirrors the DateTime check of the Schema Service (RFC 3339 with an offset).

Brain membership follows the rules of the removed brain#484 `multi-key-convert`:

- `BrainTypeDirectory` (range `__types__`, field `btd_types`) gives the record types of each slug.
- One old Concept schema holds the concept and the sop records. The helper sends each slug to Concept or to the new Sop schema by its directory types.
- `BrainListCount` (`bln_n`) gives the count of each type. The selected count must equal it. This is the count guard.
- A key with no directory type is "unselected". The helper refuses it before any write.

Derived records:

| Records | Treatment |
|---|---|
| Alternate keys `recent`, `by_status`, and `by_design` (Task) | The NEW node writes them for each create. The helper does not copy them. |
| `BrainListPage`, `BrainListLocator`, `BrainListCount`, `BrainTypeDirectory`, `BrainEdgeSet`, `BrainTokenSet` | Copied as records. The in-place converter also keeps them. |
| `BrainBodyFile` | Copied as records. The file bytes go to the target as in Q5. |
| `__braincompactlocator__` | No source. The new release fills it. |

With the alternate keys, the new release writes no new `all`, type, status, or child list slot (`src/list-page.ts`, `slotsFor`, `native`). The copied slots stay.

### Q7. Verification

`--verify` is read-only on both daemons. For each route it checks:

- The key sets: missing keys, extra keys, and keys with a different value.
- A digest per record: HMAC-SHA256 over the key and the mapped fields. The run makes a random key. The output never shows the key.
- The file bytes: the helper fetches each target file and checks its sha256.
- Spot reads: single-key reads on both daemons (`--spot-reads`, default 8).

For the LastSecrets routes the output gives counts only. It gives no key, no digest, and no value.

The app read checks (runbook steps 7 and 11):

- Brain: `brain get <slug> --type decision` and `brain search "<text>" --json` with the staging config.
- LastSecrets: `lastsecrets list --config <path> | wc -l` and `lastsecrets admin-slice --config <path>`. These print metadata only. Do not use `lastsecrets get` for the check.

### Q8. Cutover, rollback, backup, and freeze

- The old daemon stays up during the first copy. The apps continue to write to it.
- The freeze moves the old daemon to a private socket. The apps cannot reach it, so a write fails and does not go to the old home.
- The helper copies the last changes, verifies, and exports the not-moved schemas.
- Both daemons stop. The homes change places with two `mv` commands. The LaunchAgent starts the NEW program on `~/.lastdb`.
- Rollback before the move: start the old LaunchAgent again. Rollback after the move: two `mv` commands and the old plist.
- Step 8 takes one manual V2 backup of the old home, then keeps automatic backup off on both homes until the apps pass on the moved home.
- Step 12 turns automatic backup on for the new home. Its new native home id starts a new stream on the same account. The old stream stays for recovery.
- The freeze takes about 10 to 15 minutes. The copy and verify part takes about 2 to 3 minutes. The app release activation takes most of the rest.

## 3. The helper

### 3.1 Modes

| Mode | Flag | Effect |
|---|---|---|
| plan | (none) | Read-only. Lists the routes, key counts, membership, and the field map. |
| census | `--census` | Read-only. Plan, and it reads every value and checks it. |
| copy | `--apply` | Writes the target only. Then verifies. |
| verify | `--verify` | Read-only on both daemons. |
| export | `--export DIR` | Read-only on the source. Writes the export list to `DIR` as JSONL. |

Exit codes: 0 for success, 2 for a refusal or a copy issue, 3 for a verify difference, 1 for a node error.

### 3.2 Guards

- The source accepts GET and three read POST routes only. The program cannot write to the source.
- `--apply` refuses a target under `~/.lastdb` or under `--protect-home`. It refuses the same socket for source and target.
- `--apply` refuses different user hashes (override: `--allow-different-identity`).
- `--apply` needs the new configs for each app in scope.
- Owners (Tom renamed the Brain app id from `fbrain` to `brain` on 2026-10-30):
  - Each route maps the source schema to the target schema with the same descriptive name and the expected owner. The `sop` route also accepts the old `Concept` schema as its source.
  - A pin in the new app config must name that same target schema.
  - An app group changes owner only through a declared map: `--source-owner fbrain --target-owner brain`. The long form is `--owner-map brain:fbrain=brain`. `-` means no owner.
  - Every other owner difference is a refusal. For example, LastSecrets keeps the owner `lastsecrets`, and a Brain target without the map must keep `fbrain`.
  - A record digest covers the key and the mapped values only. The digest does not include the schema name or the owner, so the verify compares `fbrain` records with `brain` records.
  - The Brain owner map also renames the app-id tags in Brain values: `__fbrain_deleted__` becomes `__brain_deleted__`, and the prefix `__fbrain_backlink__:` becomes `__brain_backlink__:`. Without this change, the new Brain shows soft-deleted records again.
  - The map takes the tag pair from the Brain owners. `--app-tag-rename OLD=NEW` gives the pair when the source has no owner (the synthetic proof). It must agree with the Brain map.
  - The digest compares the renamed source values with the target values. A key that holds an old tag is a refusal. The report counts the renamed values (`tag_renames`).
  - Only the declared tag fields can change. A matching title, body, or other field stays unchanged.
  - A changed label in TagIndex or TagMembership is an issue. Its hash derives from the tag and needs an explicit address conversion.
- A refusal stops the route before its first write:
  - An unselected key (override: `--allow-unselected`).
  - A count guard difference. The override names the accepted value: `--accept-directory-count TYPE=N` (for example `design=38`). The report shows the stored count, the accepted count, and the selected records.
  - An accepted value that differs from the selected records. A new Design record before the run changes the number, and the run refuses. There is no plain skip.
  - A target schema without independent fields (override: `--allow-shared-value-target`, for the synthetic proof only).
- A record with an issue is not written: an unmapped field, a type error, a value over `--value-max-bytes`, or an alternate key problem.
- A keyed read refuses an unresolved page, a repeated or foreign record, an incomplete cursor, or a missing listed record.
- Each present field needs its actual atom metadata. An explicit null remains a value. An absent field stays absent.
- A complete target digest and complete record coverage are required for an equal result.
- A DateTime value with no offset is an issue. `--normalize-datetime` repairs date-only and similar values.
- Plan, copy, and verify print no record value, no file pointer, and no secret. Digests use a random HMAC key.
- `--export` writes non-secret values only, into an empty directory (0700, files 0600). It skips Papercut and every LastSecrets schema. A file pointer keeps only its `file_hash`.

### 3.3 Repeat runs

The copy compares each record with the target before a write.
An equal record is not written. A changed record gets an `update`.
When the target has a field that the source no longer has, the helper deletes and creates the record.
`--delete-extra` deletes target keys that the source does not have. It runs before the final listing of the verify.

### 3.4 Batches and limits

- Lists: 1000 keys per page. Reads: 100 keys per query (`--read-batch`).
- Writes: 64 mutations or 4 MiB per batch (`--write-batch`, `--write-bytes`).
- Routes run in parallel (`--concurrency`, default 4, maximum 8).
- 503 gets a retry after `Retry-After`. 423 (maintenance) stops the run.
- A value over `--value-max-bytes` (default 256 KiB, the node default) is an issue. The primary LaunchAgent sets `LASTDB_MAX_ATOM_CONTENT_BYTES=524288`. Give the staging daemon the same value.

## 4. Facts on the primary (2026-10-30, read-only)

### 4.1 The daemon

- Program a1c406f5, API 7, format 4. 38 schemas. No system schemas.
- The LaunchAgent runs `~/.lastdb/native-run-v2-programs/<oid>/lastdbd --data-dir ~/.lastdb`, with `KeepAlive` and `ExitTimeOut 150`.
- `identity.key` and `cloud_sync.json.paused` have mode 0600. `prepare-recovery-home` accepts that.

### 4.2 Plan and census

Plan: 312 source calls in 11.6 s. Census: 1340 source calls in 27 s. No write.

| Brain key or route | Old schema | Listed | Selected | Count guard | New schema |
|---|---|---:|---:|---:|---|
| reference | Reference | 5060 | 5060 | 5060 | Reference |
| decision | Decision | 126 | 126 | 126 | Decision |
| project | Project | 56 | 56 | 56 | Project |
| design | Design | 38 | 38 | 37 (refused) | Design |
| preference | Preference | 14 | 14 | 14 | Preference |
| concept | Concept | 19 | 9 | 9 | Concept |
| sop | Concept | 19 | 10 | 10 | Sop |
| spike | Spike | 1 | 1 | 1 | Spike |
| task, agent | Task, Agent | 0 | 0 | 0 | Task, Agent |
| `__bodyfile__` | BrainBodyFile | 66 | 66 | - | BrainBodyFile |
| `__brainlistpage__` | BrainListPage | 38183 | 38183 | - | BrainListPage |
| `__brainlistlocator__` | BrainListLocator | 33587 | 33587 | - | BrainListLocator |
| `__brainlistcount__` | BrainListCount | 10 | 10 | - | BrainListCount |
| `__braintypedirectory__` | BrainTypeDirectory | 8164 | 8164 | - | BrainTypeDirectory |
| `__brainedgeset__` | BrainEdgeSet | 8166 | 8166 | - | BrainEdgeSet |
| `__braintokenset__` | BrainTokenSet | 8165 | 8165 | - | BrainTokenSet |
| tag, attachment, admin, backfill keys (7) | 7 schemas | 0 | 0 | - | same names |
| lastsecrets:secret | LastSecret 6a570228… | 164 | 164 | - | LastSecret |
| lastsecrets:index | LastSecretIndex 8749701f… | 1 | 1 | - | LastSecretIndex |

- The type directory has 8164 records. None is unreadable.
- The copy writes about 101,800 records. 66 records have a file pointer.
- The census found no type issue, no DateTime issue, no empty record, and no value over 256 KiB.
- The census had no target, so it did not check the alternate key rules. The plan with the staging target checks them before the first write (step 6).

### 4.3 Not moved

| Schema | Tom's decision |
|---|---|
| Papercut, PapercutStatusIndex_hashrange_v1 | Drop. No export. |
| BrainGraphEdgeBySource_hashrange_v1, BrainGraphEdgeByDestination_hashrange_v1 | Export, then drop. |
| ChildTaskIndex, ClusterIndex, EphIndex, LiveIndex, ParkedIndex (`_hashrange_v1`) | Export, then drop. |
| RecordListEntry_hashrange_v2 | Export, then drop. |
| Compaction recovery receipt c010ab51… | Export, then drop. |
| `lastsecrets/LastSecret`, `lastsecrets/LastSecretIndex` | Aliases with no own values. lastsecrets#14 retires them. |

The export goes to `${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/protein-removal-20261030/`. It is not in Git.
The primary has no F-Kanban, Situations, Routines, or Loom schemas.

## 5. Synthetic proof (2026-10-30)

No step of this proof read or wrote the primary. No step copied `~/.lastdb`. All homes were new folders under `$TMPDIR`. The run removed them at the end.

### 5.1 The #803 program pair

- Run 41134992191 of `native-dev-artifact.yml` built head 9196e5be9ceab355c9470e5c3317e756a2f5e4a2. That head contains a83d5f06d (the B10 fix). No local build ran.
- The zip sha256 equals the artifact digest (`959e7921915654b8…`). `shasum -c SHA256SUMS` passed for both programs.
- `SOURCE_COMMIT` equals the head. `TARGET` is `aarch64-apple-darwin`.
- `codesign --verify` passed for both programs (adhoc, linker-signed). `lipo -archs` prints `arm64`.
- Both programs print `nightly-20261030-ae0b7936d-93-g9196e5be9`. The artifact expires on 2026-11-02.

After the run, #803 moved to head 4df57d28b (4 commits). These commits change the alternate-key query page format and the SDK cursor parser. The helper uses no alternate-key query, and it sends the list cursor back unchanged. The proof did not run on that head.

### 5.2 Second end-to-end run (renamed Brain)

Setup:

- Source: program a1c406f5 on a new home, with `LASTDB_ISOLATED_COPY=1`. `seed-system` gave it old-layout schemas with synthetic data.
- Data: 250 references, 7 concepts and 5 sops in one Concept schema, 30 decisions, 1 design with a stored count of 0, 2500 list pages, 5 body files, 3 papercuts, 6 secrets, and one export-list schema (ChildTaskIndex, 12 records).
- Planted problems:
  - One orphan concept with no directory record.
  - One date-only DateTime value (`dec-007`).
  - The design count.
  - The old tombstone tag `__fbrain_deleted__` on `ref-0010`.
  - The old backlink tag `__fbrain_backlink__:ref-0012` on `ref-0011`.
- Source owners: the synthetic source schemas have no owner.
  - `seed-system` refuses `owner_app_id`.
  - A declaration with the owner `fbrain` needs the old Brain definitions in the Schema Service. A read-only `check` of the 35 old definitions gave no `reuse` in DEV or in PROD. In PROD each check gave `register` (`no_candidate_schema`).
  - A sync would write to a shared Schema Service, so the proof did not do it.
  - The run used `--owner-map brain:-=brain --owner-map lastsecrets:-=lastsecrets --app-tag-rename fbrain=brain`.
- Target home: the OLD CLI `prepare-recovery-home` (`--env dev`, a synthetic API key) made it, with the same identity.
- Target daemon: the #803 program on that home. API 13, format 6, `LASTDB_MAX_ATOM_CONTENT_BYTES=524288`.
- App schemas: `brain init` (brain#484 at 7c0a573e0) and `lastsecrets init` (lastsecrets#14 at 8b2d8720) ran against the target only, with Bun.
  - Brain used `BRAIN_CONFIG` and `BRAIN_FOLDDB_SOCKET` with a staging config.
  - A read-only `check` of the 25 `brain/*` definitions gave `reuse` for each in DEV. This includes `BrainCompactListLocator_v1`.
  - `brain init` declared all 25 schemas with no stand-in. The config has 25 schema keys. Step 5 then set `appIdentityEnforce: true`.
  - LastSecrets init declared `LastSecret` and `LastSecretIndex` (`reuse`).

Results:

1. The owner guard:
   - With no owner map, the plan refused all 11 routes: `the target schema owner is brain, not the source owner none; a rename needs --owner-map`.
   - With `--owner-map brain:fbrain=brain`, the plan refused the 9 Brain routes (`the source schema owner is none, not the declared fbrain`) and the 2 LastSecrets routes.
   - With the synthetic map, the plan showed only the planted refusals.
2. The first copy (`--accept-directory-count design=1 --allow-unselected --normalize-datetime` and the map) wrote 3,103 records. All 11 routes were equal. The copy renamed 2 tag values. 5 file checks and all spot reads passed.
3. Brain reads on the target with `appIdentityEnforce: true`:
   - `get dec-007` showed `created_at: 2026-07-01T00:00:00Z`.
   - `get ref-0011` showed the tag `__brain_backlink__:ref-0012`.
   - `get ref-0010` returned `No reference`. The tombstone stayed in effect.
   - `list` by type gave design 1, sop 5, concept 7, decision 20 (one page), and reference 100 (one page, no `ref-0010`).
   - `search` found nothing. The synthetic source has no token sets.
4. LastSecrets on the target: `list` showed 6 slugs. `admin-slice` gave metadata keys only.
5. Freeze: the source got an update, an add, a delete, and a field removal. Then the old program moved to a private socket.
6. The last copy with `--delete-extra` wrote 3 reference records and 1 directory record. It deleted 1 extra key in each of the two schemas. The verify was equal on all 11 routes.
7. `--export` wrote ChildTaskIndex (12 records, 1587 bytes) with mode 0600 and a sha256 manifest.
8. Home move: both daemons stopped cleanly. One `mv` made the source home the rollback home. A second `mv` put the new home on the source path.
9. The #803 daemon started on the moved home with its default socket. The old program started on the rollback home with a private socket.
10. The verify after the move was equal on all 11 routes. It read the target through `--target-home`.
11. Brain reads on the moved home with `appIdentityEnforce: true`:
    - `ref-0001` showed the changed title.
    - The deleted `ref-0002` returned `No reference`.
    - `ref-0010` stayed hidden. `ref-0011` kept `__brain_backlink__:ref-0012`.
    - `dec-007` showed the decision fields.
12. LastSecrets `list` on the moved home showed 6 slugs.
13. The secret scan found no synthetic secret value and no synthetic API key in any output, report, export, log, configuration file, or the worktree.
14. Clean-up: the run stopped both daemons and removed the temporary folder. After the run, only the primary daemon ran.

### 5.3 The first run on #803 (head 11280163c)

The first run used run 41126284642 (head 11280163c) and brain#484 at 5c71286b (app id `fbrain`).

- `brain init` stopped at `BrainCompactListLocator_v1` (B10). A temporary copy of Brain skipped that one schema.
- The copy, the freeze, the export, the home move, and the verify after the move gave the same results as section 5.2.

### 5.4 The run with API 7 on both daemons

An earlier run used program a1c406f5 for the source and the target. It showed these guards:

- The helper refused a target under a protected home, the same socket, and different user hashes.
- A second run into the same export folder was refused.
- A pass with no change took 0.8 s.

### 5.5 Limits of the proof

- The data is synthetic and small. The primary has about 101,800 records.
- The source schemas have no owner. The `fbrain` to `brain` owner map ran only as a plan refusal. The primary run is the first copy with the `fbrain` owner.
- The source home used `--env dev`. The primary uses PROD. The PROD Schema Service path did not run (B2).
- Brain writes with `appIdentityEnforce: true` on #803 did not run. Only reads ran.
- `brain search` did not run on copied token sets.
- Backup V2 (Steps 8a and 12) did not run.
- The LaunchAgent, the plist change, and `last-stack-lastdb-current` (Step 10) did not run.
- The 423 pause did not run.
- #803 head 4df57d28b and later heads did not run (section 5.1).

### 5.6 Third end-to-end run: the merged removal release (2026-10-30)

Setup:

- Pair: the signed Mini artifact of lastdb main e13ca0db (#803 merged), run 41150186693, digest `sha256:34cdcd3c…050932`. `lastdb` `5fce9d98…3882`, `lastdbd` `725a1c80…4a79`. Both print `nightly-20261030-ae0b7936d-15-ge13ca0dbb`.
- Apps: brain#484 at 2f7b54e4b and lastsecrets#14 at 6883d2632 (no explicit conversion). The same synthetic source and planted problems as section 5.2.

Results:

- The helper at 581ea3e05 refused every plan with `/api/query returned a foreign, repeated, or empty row`. The API 7 node returns the hash key field with each keyed record. The fix in this revision drops an unasked field only when it is a key field and equals the record key.
- With the fix: the owner guard, the first copy (3,103 records, 11 of 11 equal, 62 of 62 spot reads), the freeze, the last copy with `--delete-extra`, the export, the home move, and the verify after the move (0 missing, 0 extra, 0 different) passed.
- Brain writes (new record, update, delete) passed on the target and on the moved home with the init value `appIdentityEnforce: false`. With `true`, each write failed: `No write capability is cached for "brain" on this node`. Brain reads passed with both values.
- LastSecrets: a copied value and a new value read back with an equal sha256. No value appeared in any output.
- A read-only `check` against the PROD Schema Service gave `reuse` for 27 of 27 definitions (25 Brain, 2 LastSecrets).
- The secret scan found no value in 357 files. Only the primary daemon ran after the clean-up.
- The fixed helper ran the Step 1 census on the primary (read-only, 1,337 calls, 26 s): rc 0, 0 issues, 0 app-id tag renames. LastSecret has 165 records.

Findings that do not block the primary:

- A copied record with the old tombstone tag stays in `brain list` (`get` hides it). The primary has no such tag.
- The copy keeps the stored Design count (37). `brain list` shows 38 designs.
- An app write on the target before the last copy can leave records in the fresh Brain schemas. Step 7 only reads.

## 6. Runbook

CAUTION: This runbook changes the primary. Tom approves each stop. Start only after the blockers in section 8 are clear.

CAUTION: The 2026-10-14 notice forbids `brain` commands. On 2026-10-30 Tom allowed `brain init` and read-only `brain get` and `brain search` against the NEW home, for this migration only. Steps 5, 7, and 11d use only these commands. Do not use other `brain` commands.

### Step 0. Shell variables (each new shell)

```bash
export OLD="$HOME/.lastdb"
export NEW="$HOME/.lastdb-v13"
export BACK="$HOME/.lastdb-v7-rollback"
export LABEL=$(launchctl list | awk '/lastdbd-primary/ {print $3}')
export PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
export KICK=$(launchctl list | awk '/lastdb-cloud-backup-kick/ {print $3}')
export BASE=$(basename "$(readlink "$OLD/current")")
export W="${LAST_STACK_EVIDENCE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/last-stack}/home-copy-protein-removal-20261030"
export X="${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/protein-removal-20261030/home-copy-export"
export COPY="<accepted last-stack checkout>/bin/last-stack-lastdb-home-copy"
export SEED="<accepted last-stack checkout>/bin/last-stack-lastseek-seed-brain"
export BR="<brain checkout at the merged brain#484 commit>"
export LR="<lastsecrets checkout at the merged lastsecrets#14 commit>"
mkdir -p "$W" && chmod 700 "$W"
```

Check: `echo "$LABEL"` prints one label. `ls -d "$NEW" "$BACK"` finds neither. `echo "$BASE"` prints the old program commit.

The work folder is outside Git. Do not commit raw output.

### Step 1. Read-only census of the old home

```bash
python3 "$COPY" --source-home "$OLD" --brain-release "$BR" --lastsecrets-release "$LR" \
  --census --report "$W/s1-census.json" > "$W/s1-census.txt"; echo "rc=$?"
sed -n '1,40p' "$W/s1-census.txt"
```

Check: `unreadable 0`. No `issue:` line. The only refusal is the Design count guard. Its text names `--accept-directory-count design=38`. If the number is not 38, stop and review the new Design records.

### Step 2. Get the NEW program pair (after #803 merges)

The primary uses the signed pair from a main commit. The dev pair from a PR head is for proof runs only (2b).

2a. The signed pair:

```bash
export C803=<40-hex main commit that contains #803>
gh workflow run mini-upgrade-artifact.yml -R EdgeVector/lastdb --ref main -f source_oid="$C803"
gh run list -R EdgeVector/lastdb --workflow mini-upgrade-artifact.yml --event workflow_dispatch --limit 3 \
  --json databaseId,createdAt,status --jq '.[] | "\(.databaseId) \(.createdAt) \(.status)"'
export RUN=<run id of this dispatch>
gh run watch "$RUN" -R EdgeVector/lastdb --exit-status
export CAND="$W/candidate-${C803:0:9}"; mkdir -p "$CAND/dl" "$CAND/bin"
export NAME="lastdb-mini-$C803-aarch64-apple-darwin"
gh api "repos/EdgeVector/lastdb/actions/runs/$RUN/artifacts" > "$CAND/artifacts.json"
jq --arg n "$NAME" '.artifacts[] | select(.name==$n)' "$CAND/artifacts.json" > "$CAND/artifact.json"
gh api "$(jq -r .archive_download_url "$CAND/artifact.json")" > "$CAND/artifact.zip"
shasum -a 256 "$CAND/artifact.zip"; jq -r '.digest, .expires_at' "$CAND/artifact.json"
unzip -o -q "$CAND/artifact.zip" -d "$CAND/dl"
jq . "$CAND/dl/lastdb-aarch64-apple-darwin.manifest.json"
tar -xzf "$CAND/dl/lastdb-aarch64-apple-darwin.tar.gz" -C "$CAND/bin"
shasum -a 256 "$CAND/bin/lastdb" "$CAND/bin/lastdbd"
for b in lastdb lastdbd; do codesign --verify --strict "$CAND/bin/$b" && lipo -archs "$CAND/bin/$b"; "$CAND/bin/$b" --version | tail -1; done
```

Use a Bash timeout of 600000 ms for `gh run watch`. Repeat it until the run ends.

Check:

- The zip sha256 equals `digest`. `expires_at` is in the future.
- The manifest `source_git_oid` equals `C803`. The binary hashes equal the manifest.
- `codesign` passes. `lipo` prints `arm64`. Both versions end with `g${C803:0:9}`.

2b. The dev pair of an open PR (proof runs only, never the primary):

```bash
export H=$(gh pr view 803 -R EdgeVector/lastdb --json headRefOid --jq .headRefOid)
gh pr edit 803 -R EdgeVector/lastdb --add-label native-dev-artifact
gh run list -R EdgeVector/lastdb --workflow native-dev-artifact.yml --commit "$H" --limit 3 --json databaseId,status,conclusion
export RUN=<run id>; gh run watch "$RUN" -R EdgeVector/lastdb --exit-status
export CAND=$(mktemp -d "$TMPDIR/cand.XXXXXX"); mkdir -p "$CAND/dl" "$CAND/x"
gh api "repos/EdgeVector/lastdb/actions/runs/$RUN/artifacts" > "$CAND/artifacts.json"
jq --arg n "lastdb-native-dev-arm64-$H" '.artifacts[] | select(.name==$n)' "$CAND/artifacts.json" > "$CAND/artifact.json"
gh api "$(jq -r .archive_download_url "$CAND/artifact.json")" > "$CAND/artifact.zip"
shasum -a 256 "$CAND/artifact.zip"; jq -r '.digest, .expires_at' "$CAND/artifact.json"
unzip -o -q "$CAND/artifact.zip" -d "$CAND/dl"
tar -xzf "$CAND/dl/lastdb-native-dev-arm64.tar.gz" -C "$CAND/x"
(cd "$CAND/x" && shasum -a 256 -c SHA256SUMS); cat "$CAND/x/SOURCE_COMMIT" "$CAND/x/TARGET"
for b in lastdb lastdbd; do codesign --verify --strict "$CAND/x/bin/$b" && lipo -archs "$CAND/x/bin/$b"; "$CAND/x/bin/$b" --version | tail -1; done
```

Check: the zip sha256 equals `digest`. `SOURCE_COMMIT` equals `$H`. `TARGET` is `aarch64-apple-darwin`. Both versions end with `g${H:0:9}`. The label stays on the PR. Each new head gets a new pair, kept 3 days.

### Step 3. Prepare the new home

```bash
set -o pipefail
lastsecrets get cloud-v2-completion-20261027-0os3adpz-prod-api-key \
  | "$OLD/current/lastdb" --data-dir "$OLD" cloud prepare-recovery-home --into "$NEW" --env prod --api-key-stdin --json \
  > "$W/s3-prepare.json"; echo "rc=$?"
jq -c '{ok, credentials_only, identity_matches_source, api_key_matches_source, saved_url_matches_environment,
  cloud_sync_off, data_directory_created, files, home_mode}' "$W/s3-prepare.json"
```

The key goes through the pipe only. It does not go to the terminal or to a file.

Use the key that the source home uses now ("Primary Cloud V2 backup access"). On 2026-10-30 that was `cloud-v2-completion-20261027-0os3adpz-prod-api-key`. The older `lastdb-primary-cloud-api-key-prod` does not match, and the command refuses it with `stdin API key does not match the source cloud credentials`. To find the correct slug, compare hashes only, never values.

Give `--into` and `--data-dir` as real absolute paths. The command refuses a path with a symlink part, for example `~/.folddb` or `/var` on macOS (use `/private/var`). `--env` must agree with the saved URL.

Check: `ok`, both `matches` fields, `saved_url_matches_environment`, and `cloud_sync_off` are true. `data_directory_created` is false. `files` is 3. `home_mode` is `0700`.

Rollback: `rm "$NEW/identity.key" "$NEW/cloud_sync.json.paused" "$NEW/.cloud_resume_required" && rmdir "$NEW"`.

### Step 4. Start the staging daemon on the new home

```bash
export N="$NEW/native-run-v2-programs/$C803"
mkdir -p "$N" && cp -p "$CAND/bin/lastdb" "$CAND/bin/lastdbd" "$N/"
env -u LASTDB_HOME -u FOLDDB_HOME -u LASTDB_SOCKET_PATH -u ENVIRONMENT -u EXEMEM_ENV -u FOLD_SCHEMA_SERVICE_URL \
  LASTDB_ENGINE=laststore LASTDB_MAX_ATOM_CONTENT_BYTES=524288 \
  nohup "$N/lastdbd" --data-dir "$NEW" > "$W/s4-staging.log" 2>&1 &
echo $! > "$W/s4-staging.pid"
curl -s --unix-socket "$NEW/data/folddb.sock" http://localhost/api/version | jq -c '{api_version, build}'
python3 "$COPY" --source-home "$OLD" --target-home "$NEW" --brain-release "$BR" --lastsecrets-release "$LR" | sed -n '1,3p'
```

Check: `api_version` is 13. The `user` value of the source and the target is the same. The log has no `last_boot_error`.

The staging daemon uses `$NEW/data/folddb.sock`. No app knows this path.

Rollback: `kill -TERM "$(cat "$W/s4-staging.pid")"`. The new home stays for review.

### Step 5. Declare the new app schemas on the staging home

```bash
mkdir -p "$W/staging-config" && chmod 700 "$W/staging-config"
export BRAIN_CONFIG="$W/staging-config/brain.json"
export BRAIN_FOLDDB_SOCKET="$NEW/data/folddb.sock"
"$BR/bin/brain" init --schema-service-url "$(jq -r .schemaServiceUrl "$HOME/.brain/config.json")" --yes
bun "$LR/src/cli.ts" init --config "$W/staging-config/lastsecrets.json" --socket "$NEW/data/folddb.sock"
for f in brain lastsecrets; do
  jq --arg s "$NEW/data/folddb.sock" '.nodeSocketPath=$s' "$W/staging-config/$f.json" > "$W/staging-config/$f.tmp" \
    && mv "$W/staging-config/$f.tmp" "$W/staging-config/$f.json"
done
jq -c '{socket: .nodeSocketPath, keys: (.schemaHashes|length), model: .storageModel, enforce: .appIdentityEnforce}' "$W/staging-config/brain.json"
jq -c '{socket: .nodeSocketPath, secret: .schemaHash, index: .indexSchemaHash}' "$W/staging-config/lastsecrets.json"
```

Use the release checkouts. Do not change the installed `brain` or `lastsecrets` programs in this step.

The new Brain reads only `BRAIN_CONFIG` and `BRAIN_FOLDDB_SOCKET`. It ignores the old `FBRAIN_*` variables. `brain init` writes the app id `brain` and declares the 25 `brain/*` schemas. It refuses an old-layout config with `home_copy_required`, so use the empty staging config.

Check: Brain has 25 keys (the keyless `BrainCompactListLocator_v1` is one of them), `multi-key-v1`, and `enforce` false. LastSecrets has both pins. Both sockets name `$NEW`.

Keep the init value `appIdentityEnforce: false` (B5). On Mini the init skips consent and stores no write capability, so a Brain write with `true` fails (section 5.6). With `false`, Brain writes as the node owner on the owner socket.

If `brain init` reports a `register` resolution or a Schema Service error, B2 is still open. Stop the staging daemon and wait for the PROD publish.

### Step 6. Plan with the target, then the first copy

```bash
A=(--source-home "$OLD" --target-home "$NEW" --brain-release "$BR" --lastsecrets-release "$LR"
   --new-brain-config "$W/staging-config/brain.json" --new-lastsecrets-config "$W/staging-config/lastsecrets.json"
   --value-max-bytes 524288 --accept-directory-count design=38 --source-owner fbrain --target-owner brain)
python3 "$COPY" "${A[@]}" --census --report "$W/s6-plan.json" > "$W/s6-plan.txt"; echo "rc=$?"
python3 "$COPY" "${A[@]}" --apply --report "$W/s6-copy.json" > "$W/s6-copy.txt"; echo "rc=$?"
sed -n '1,45p' "$W/s6-copy.txt"
```

The value 38 is the coordinator decision (B4). The report line `count override: stored 37, accepted 38, selected 38` records it.
If the run refuses because the selected number is not 38, review the new Design records. Then give the new number.

Check: rc is 0. Each route says `equal`. No `issue:` line. The source is still live, so a later run can show new changes.

The text shows `owner map brain: fbrain -> brain (declared)`. A Brain route that held old app-id tags shows `app-id tags renamed: N values`. The report keeps N in `tag_renames` for each route. No route refuses `keys hold an old app-id tag name`.

Rollback: none needed. The copy writes the staging home only.

### Step 7. App read checks on the staging home

Use the Step 5 shell (`BRAIN_CONFIG` and `BRAIN_FOLDDB_SOCKET` are set).

```bash
"$BR/bin/brain" get decision-2026-09-25-revert-primary-brain-to-lastdb --type decision | head -5
"$BR/bin/brain" search "LastDB" --limit 5 --json > "$W/s7-search.json"; jq -r '.. | .slug? // empty' "$W/s7-search.json" | head
LASTSECRETS_CONFIG="$W/staging-config/lastsecrets.json" bun "$LR/src/cli.ts" list | wc -l
LASTSECRETS_CONFIG="$W/staging-config/lastsecrets.json" bun "$LR/src/cli.ts" admin-slice | jq 'keys'
```

`list` and `admin-slice` take no `--config` flag. They read `LASTSECRETS_CONFIG`.

Check: `get` shows the record. `search` gives slugs. The LastSecrets list count equals the plan (164 on 2026-10-30). No secret value appears.

### Step 8. Freeze: cloud-off check, then a private socket for the old daemon

8a. Take one manual V2 backup of the old home (R0). Then check that automatic backup is off on both homes.

```bash
export R0=$(uuidgen | tr 'A-Z' 'a-z'); echo "$R0" > "$W/R0.request-id"
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 start --request-id "$R0" --json > "$W/s8-start-R0.json" 2> "$W/s8-start-R0.err"; echo "rc=$?"
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 status --json > "$W/s8-v2-R0.json"
jq -c '{request_id, phase, running, retained_source_bytes, ordinal: .last_accepted_backup.ordinal, commit: .last_accepted_backup.commit_sha256}' "$W/s8-v2-R0.json"
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 disable-automatic --json > "$W/s8-v2-disable.json"
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 status --json > "$W/s8-v2-before.json"
jq -c '{running, phase, auto: .automatic_backup.enabled, pending: .automatic_backup.pending_request_id}' "$W/s8-v2-before.json"
"$N/lastdb" --data-dir "$NEW" cloud backup-v2 disable-automatic --json > "$W/s8-new-v2-disable.json"
"$N/lastdb" --data-dir "$NEW" cloud backup-v2 status --json > "$W/s8-new-v2-status.json"
jq -e '.running == false and .automatic_backup.enabled == false' "$W/s8-v2-before.json" "$W/s8-new-v2-status.json"
```

Check: R0 has `request_id == R0`, `phase=published`, `running=false`, and `retained_source_bytes=0`. Record the ordinal and the commit sha256. If `start` returns before publication, run `cloud backup-v2 resume --json`; do not start a second request. If the old stream refuses the backup, record the error and continue: the rollback home keeps every record.

Check: `running` and `automatic_backup.enabled` are false on both homes. A missing status value is a refusal.

8b. Stop the old LaunchAgent and hold the memory guard:

CAUTION: The memory guard starts the primary LaunchAgent again when the daemon is absent for two cycles. The hold file stops that.

```bash
mkdir -p "$OLD/monitoring" && touch "$OLD/monitoring/lastdbd-revive.hold"
launchctl bootout "gui/$(id -u)/$LABEL"
pgrep -fl lastdbd
```

Check: no `lastdbd` process uses `--data-dir $OLD`. The staging daemon still runs.

8c. Start the old program on a private socket:

```bash
export FS=$(mktemp -d "$TMPDIR/hc.XXXXXX")
env -u LASTDB_HOME -u FOLDDB_HOME -u LASTDB_SOCKET_PATH LASTDB_ENGINE=laststore \
  nohup "$OLD/native-run-v2-programs/$BASE/lastdbd" --data-dir "$OLD" \
  --socket-path "$FS/old.sock" --full-socket-path "$FS/old-full.sock" > "$W/s8-old-private.log" 2>&1 &
echo $! > "$W/s8-old-private.pid"
curl -s --unix-socket "$FS/old.sock" http://localhost/api/version | jq -c '{api_version, build}'
curl -s -m 3 --unix-socket "$OLD/data/folddb.sock" http://localhost/api/version; echo "default-socket rc=$?"
```

Check: the private socket answers with API 7. The default socket does not answer. From now on an app write fails. It does not reach the old home.

Rollback for Step 8: `kill -TERM "$(cat "$W/s8-old-private.pid")"`, then `launchctl bootstrap "gui/$(id -u)" "$PLIST"`, then `rm "$OLD/monitoring/lastdbd-revive.hold"`.

### Step 9. Last copy, verify, and export

```bash
F=(--source-socket "$FS/old.sock" --target-home "$NEW" --brain-release "$BR" --lastsecrets-release "$LR"
   --new-brain-config "$W/staging-config/brain.json" --new-lastsecrets-config "$W/staging-config/lastsecrets.json"
   --value-max-bytes 524288 --accept-directory-count design=38 --source-owner fbrain --target-owner brain)
python3 "$COPY" "${F[@]}" --apply --delete-extra --report "$W/s9-copy.json" > "$W/s9-copy.txt"; echo "rc=$?"
python3 "$COPY" "${F[@]}" --verify --report "$W/s9-verify.json" > "$W/s9-verify.txt"; echo "rc=$?"
python3 "$COPY" --source-socket "$FS/old.sock" --brain-release "$BR" --lastsecrets-release "$LR" \
  --export "$X" --report "$W/s9-export.json" > "$W/s9-export.txt"; echo "rc=$?"
sed -n '1,45p' "$W/s9-verify.txt"; tail -15 "$W/s9-export.txt"
```

Check:

- The copy and the verify end with rc 0. Each route says `equal`.
- The export lists the nine export-list schemas with their record counts. `export-manifest.json` has a sha256 for each file.
- `ls -la "$X"` shows mode `drwx------` and files `-rw-------`.

If the verify shows a difference, do not continue. Use the Step 8 rollback.

### Step 10. Stop both daemons and move the homes

```bash
kill -TERM "$(cat "$W/s8-old-private.pid")" "$(cat "$W/s4-staging.pid")"
pgrep -fl lastdbd
tail -2 "$W/s8-old-private.log" "$W/s4-staging.log"
mkdir -p "$NEW/monitoring" && touch "$NEW/monitoring/lastdbd-revive.hold"
mv "$OLD" "$BACK"
mv "$NEW" "$OLD"
cp -p "$PLIST" "$W/s10-plist.before"
/usr/libexec/PlistBuddy -c "Set :ProgramArguments:0 $OLD/native-run-v2-programs/$C803/lastdbd" "$PLIST"
plutil -lint "$PLIST"
/usr/libexec/PlistBuddy -c 'Print :ProgramArguments' "$PLIST"
"$HOME/.last-stack/bin/last-stack-lastdb-current" set --lastdb-home "$OLD" --bin-dir "$OLD/native-run-v2-programs/$C803"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
"$HOME/.last-stack/bin/last-stack-lastdb-current" check --verbose
curl -s --unix-socket "$OLD/data/folddb.sock" http://localhost/api/version | jq -c '{api_version, build}'
```

Wait for each `kill` until `pgrep` shows no daemon on `$OLD`, `$NEW`, or the private socket. The log ends with the shutdown line.

CAUTION: Do not use `plutil -replace ProgramArguments.0`. It inserts a new first element and keeps the old path. The daemon then gets four arguments, exits with `lastdbd: invalid_arguments`, and KeepAlive restarts it in a loop. The 2026-10-30 run hit this. Recovery: `launchctl bootout "gui/$(id -u)/$LABEL"`, copy `$W/s10-plist.before` back, run the PlistBuddy line, then bootstrap.

Check: `ProgramArguments` has three entries: the new `lastdbd`, `--data-dir`, and `$OLD`. API 13 on `~/.lastdb/data/folddb.sock`. `last-stack-lastdb-current check` passes. `~/.folddb` still points to `~/.lastdb`.

### Step 11. Verify after the move, then open the apps

11a. Verify the moved home against the rollback home on a private socket:

```bash
env -u LASTDB_HOME -u FOLDDB_HOME -u LASTDB_SOCKET_PATH LASTDB_ENGINE=laststore \
  nohup "$BACK/native-run-v2-programs/$BASE/lastdbd" --data-dir "$BACK" \
  --socket-path "$FS/old.sock" --full-socket-path "$FS/old-full.sock" > "$W/s11-back.log" 2>&1 &
echo $! > "$W/s11-back.pid"
python3 "$COPY" --source-socket "$FS/old.sock" --target-home "$OLD" --brain-release "$BR" --lastsecrets-release "$LR" \
  --new-brain-config "$W/staging-config/brain.json" --new-lastsecrets-config "$W/staging-config/lastsecrets.json" \
  --accept-directory-count design=38 --source-owner fbrain --target-owner brain \
  --verify --report "$W/s11-verify.json" > "$W/s11-verify.txt"; echo "rc=$?"
kill -TERM "$(cat "$W/s11-back.pid")"
```

Check: rc 0 and each route `equal`.

11b. Install the app configs:

```bash
mkdir -p "$W/rollback-config"
cp -p "$HOME/.brain/config.json" "$W/rollback-config/brain.json"
cp -p "$HOME/.lastsecrets/config.json" "$W/rollback-config/lastsecrets.json"
jq --arg s "$OLD/data/folddb.sock" '.nodeSocketPath=$s' "$W/staging-config/brain.json" > "$HOME/.brain/config.json"
jq --arg s "$OLD/data/folddb.sock" '.nodeSocketPath=$s' "$W/staging-config/lastsecrets.json" > "$HOME/.lastsecrets/config.json"
unset BRAIN_CONFIG BRAIN_FOLDDB_SOCKET
jq -c '{socket: .nodeSocketPath, enforce: .appIdentityEnforce, keys: (.schemaHashes|length), model: .storageModel}' "$HOME/.brain/config.json"
```

The new Brain reads `~/.brain/config.json` only. brain#484 removed the `~/.fbrain` fallback and the `FBRAIN_*` variables. The new config has the 25 `brain/*` schema keys of the staging home.

With `appIdentityEnforce: false` the new Brain needs no capability file. The old `fbrain@<hash>.cap` files in `~/.brain/capabilities` stay for the rollback. Do not delete them.

Check: `enforce` is false (B5). `keys` is 25. `model` is `multi-key-v1`.

11c. Merge brain#484 and lastsecrets#14 at the heads that ran in Steps 5 to 7. Then install the merged Brain and LastSecrets releases through the LastDB app registry (`next` channel) with the probe gate.

Do not merge them before the move. The new releases refuse the old home with `home_copy_required`, and Step 3 reads a key through the installed LastSecrets.

CAUTION: Get Tom's decision on the install gate before Step 8. The installed old Brain and LastSecrets fail against the new home, so both are down from Step 10 until this install. On 2026-10-30, `host-track refresh --activate lastsecrets` stopped with rc 3: `REFUSED: Situations blocks host-track-refresh`. Situations has no schemas since the 2026-10-14 reset, so its preflight fails closed for every app except `situations` and `last-stack`. On 2026-10-31 Tom ordered "install through app registry" and "skip situations for now" for these two installs.

The registry path that ran on 2026-10-31:

1. Dispatch `.github/workflows/registry-proof.yml` on last-stack main for the new LastDB build. The plan reads the main head of each app repo, so each app repo must be public (Tom made `EdgeVector/lastseek` public for this). Run 41167685531 proved 8 apps on e13ca0db; `kanban` and `lastseek` were RED.
2. Publish the proved rows with `bin/last-stack-registry-apply-proof` from last-stack main, with `--publish-bin` set to the main `bin/last-stack-registry-publish-next`. The installed copy was older than main and lacked the `lastseek` row and the proof-record step. The rows merged as homebrew-lastdb#152.
3. Install each app. LastSecrets first, because Brain reads its key through LastSecrets:

```bash
export LAST_STACK_SITUATIONS_BIN="$W/install-tools/situations-skip"   # prints a note, exits 0; Tom's order only
HOST_TRACK_ACTIVATE=1 host-track install lastsecrets > "$W/install-lastsecrets.out" 2> "$W/install-lastsecrets.err"; echo "rc=$?"
HOST_TRACK_ACTIVATE=1 host-track install brain > "$W/install-brain.out" 2> "$W/install-brain.err"; echo "rc=$?"
unset LAST_STACK_SITUATIONS_BIN
```

`host-track install` has no refresh preflight. Only the artifact puller runs `situations preflight`, and `LAST_STACK_SITUATIONS_BIN` replaces that one call. The candidate probes still run, and activation needs GREEN. Do not use `HOST_TRACK_PROBE_SKIP=1`.

The Brain install log shows `probe attempt 1/3 failed` for the old version tree. That is the latency control: the old Brain cannot read the new home. The candidate probe is the gate.

Until the install, read checks can use the merged release exports: `bun run "$LR/src/cli.ts" list` and the Brain CLI under `$BR`.

11d. Remove the hold and check the apps:

```bash
rm "$OLD/monitoring/lastdbd-revive.hold"
brain get decision-2026-09-25-revert-primary-brain-to-lastdb --type decision | head -3
lastsecrets list | wc -l
```

The write freeze ends here.

11e. Make `brain search` work on the new home.

`brain search` and `brain ask` scope LastSeek with the new schema names (`brain/Design`, ...). LastSeek knows a local name only after a batch with that name reaches the inbox. The copy wrote with Search delivery off, so the first `brain search` fails with `lastseek: unknown schema "brain/Design"`.

CAUTION: Search delivery is off by default since lastdb#497. Without `LASTDB_SEARCH_ENABLED=1` in the plist, no new write reaches LastSeek, and the index goes stale with no error.

First turn on delivery for new writes. The restart takes about 2 seconds:

```bash
cp -p "$PLIST" "$W/search-plist.before"
touch "$OLD/monitoring/lastdbd-revive.hold"
launchctl bootout "gui/$(id -u)/$LABEL"
pgrep -f "lastdbd --data-dir $OLD"; echo "absent when empty"
/usr/libexec/PlistBuddy -c "Add :EnvironmentVariables:LASTDB_SEARCH_ENABLED string 1" "$PLIST"
plutil -lint "$PLIST"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
lastdb status | head -3
rm "$OLD/monitoring/lastdbd-revive.hold"
```

Then deliver every existing Brain record once. The daemon must run:

```bash
lastseek schema-table > "$W/lastseek-table.out"
"$SEED" --count-only > "$W/seed-count.json"
"$SEED" > "$W/seed-write.json"
launchctl kickstart "gui/$(id -u)/com.edgevector.lastseek-drain"
```

The helper reads only. It pages the keys with `/api/list`, reads the searchable fields by key with `/api/query`, and writes `IndexChangeBatch` files in the daemon's own outbox format. The LastSeek drain then embeds them and deletes the files.

Check:

- `seed-count.json` shows `missing: 0` for each type, and the per-type records equal the Step 9 copy counts (5,314 on 2026-10-31).
- The inbox is empty after the drain. `~/.lastseek/drain.log` shows the records.
- `brain search "home copy"` returns hits with no `unknown schema` error.

Do not use `lastdb search-rebuild` on e13ca0db. Its offline open has no molecule wrap key and does not load the molecule key bundles, so it stops with `the typed molecule has no admitted range profile`. The LastDB fix: open with `from_namespaced_store_with_content_and_molecule_keys` and call `molecule_keys().load_schema` before the field reads, as the query path does.

The LastSeek index keeps the old rows under the old schema identities. Brain does not query those identities. They use space only.

### Step 12. Turn cloud backup on for the new home

Tom requires cloud backup on again after the work. The moved home has a new native home id, so it starts a new stream on the same account. The old stream stays for recovery (B7).

```bash
set -o pipefail
lastsecrets get cloud-v2-completion-20261027-0os3adpz-prod-api-key \
  | lastdb --data-dir "$OLD" cloud backup-v2 connect --existing --env prod --api-key-stdin \
      --expected-user-hash "$(jq -r .account_id "$BACK/cloud-byte-backup-v2-manual.json")" --json > "$W/s12-connect.json"; echo "rc=$?"
stat -f '%Sp %N' "$OLD/data/disk-run" "$BACK/data/disk-run"
chmod 700 "$OLD/data/disk-run"
date +%s > "$W/s12-enable-at"
lastdb --data-dir "$OLD" cloud backup-v2 enable-automatic --log-interval-seconds 60 --snapshot-interval-seconds 86400 --json > "$W/s12-enable.json"
lastdb --data-dir "$OLD" cloud backup-v2 status --json > "$W/s12-status.json"
jq -c '{auto: .automatic_backup.enabled, rev: .automatic_backup.revision, log: .automatic_backup.log_interval_seconds,
  snap: .automatic_backup.snapshot_interval_seconds, last_snapshot_at: .automatic_backup.last_snapshot_at, phase,
  running, retained_source_bytes, blocked_reason, head: .mutation_log.head.frontiers, backed: .automatic_backup.last_backed_up_frontiers}' "$W/s12-status.json"
launchctl print "gui/$(id -u)/$KICK" | grep -E 'state =|run interval'
```

The key goes through the pipe only. The expected user hash is the account id of the rollback home (`bdad5eed…` on 2026-10-30).

CAUTION: Do the `chmod 700` before `enable-automatic`. The e13ca0db daemon creates `data/disk-run` with mode 0755 on a fresh home. The mutation log stores its files under `data/disk-run/mutation-log-v1` and refuses a parent folder that is not private. Without the chmod, `enable-automatic` returns `HTTP 409 Conflict: native backup source needs attention`, the daemon logs one WARN each second, and no snapshot starts. The rollback home has `disk-run` at 0700. The chmod changes no data. On 2026-10-30 the first automatic snapshot started within 8 seconds after the chmod. The LastDB fix is to create `disk-run` at 0700 (the cloud restore path already does).

Repeat the status read (one read per turn or a Monitor loop) until the first snapshot publishes.

Check:

- `auto=true`, log 60, snapshot 86400.
- `last_snapshot_at` is later than `s12-enable-at`, `phase=published`, `retained_source_bytes=0`, `blocked_reason=null`, `head == backed`.
- The backup kick LaunchAgent is loaded (`$KICK` is not empty). If it is not, bootstrap its plist from `$HOME/Library/LaunchAgents`.

Rollback: `lastdb --data-dir "$OLD" cloud backup-v2 disable-automatic --json`.

### Step 13. Clean up

- Remove `$FS` with `rmdir` after both private daemons stop.
- Keep `$BACK` untouched until Tom approves its removal. It is the rollback home.
- Keep `$W` and `$X`. They are outside Git.

## 7. Rollback

### 7.1 Before Step 10

Use the Step 8 rollback. The old home has every write. Keep `$NEW` for review.

### 7.2 After Step 10

CAUTION: Records written on the new home after the cutover are not in the rollback home. The helper copies only from the old layout to the new layout.

```bash
touch "$OLD/monitoring/lastdbd-revive.hold"
launchctl bootout "gui/$(id -u)/$LABEL"
pgrep -fl lastdbd
mv "$OLD" "$NEW"
mv "$BACK" "$OLD"
cp -p "$W/s10-plist.before" "$PLIST"
"$HOME/.last-stack/bin/last-stack-lastdb-current" set --lastdb-home "$OLD" --bin-dir "$OLD/native-run-v2-programs/$BASE"
cp -p "$W/rollback-config/brain.json" "$HOME/.brain/config.json"
cp -p "$W/rollback-config/lastsecrets.json" "$HOME/.lastsecrets/config.json"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
rm "$OLD/monitoring/lastdbd-revive.hold"
```

Then install the previous Brain and LastSecrets releases with `app-safe-upgrade`.
Keep cloud sync and automatic cloud backup off after rollback. A later instruction from Tom can change this rule.

## 8. Blockers and decisions

| ID | Blocker or decision | Owner |
|---|---|---|
| B1 | Closed 2026-10-30. #803 merged as lastdb main e13ca0db. The signed Mini pair is run 41150186693 (digest `sha256:34cdcd3c…050932`, expires 2026-11-14). Section 5.6 ran on it. | done |
| B2 | Closed 2026-10-30. A read-only PROD `check` gave `reuse` for all 25 `brain/*` and both LastSecrets definitions (section 5.6). The PROD app `brain` stays in the sandbox tier; Brain init and writes do not use the tier. | done |
| B3 | Closed 2026-10-31. brain#484 merged as brain main 73ca4d41 and lastsecrets#14 as lastsecrets main 8d50002f. Both installed through the registry `next` channel with GREEN probes (Step 11c). | done |
| B15 | Closed 2026-10-31 by Step 11e. `lastdb search-rebuild` fails on e13ca0db (no molecule wrap key on the offline open). The seed helper delivered the Brain records through the running daemon. The LastDB fix is still open. | LastDB |
| B4 | Decided 2026-10-30. Design: trust the 38 records over the stored count of 37. The new Brain rebuilds its counts. The runbook names `--accept-directory-count design=38`. | done |
| B5 | Decided 2026-10-30 (changed). `appIdentityEnforce` stays at the init value `false`. On Mini a write with `true` has no capability and fails (section 5.6). | done |
| B6 | Decided 2026-10-30. Tom allowed `brain init` and read-only `brain get` and `brain search` against the NEW home for this migration. | done |
| B7 | Decided 2026-10-30. Tom requires cloud backup on after the work, so Step 12 starts a new stream on the same account. The old stream stays for recovery. | done |
| B8 | Closed by the proof. The #803 daemon ran in the synthetic run (section 5.2). The first check on real data is still Step 6. | operator |
| B9 | Closed by the proof. The home move ran on a format 6 store, and the #803 daemon started on the moved home. If the real move fails, point the plist, the configs, and `current` at `~/.lastdb-v13` instead. | operator |
| B10 | Closed. #803 a83d5f06d accepts the keyless `BrainCompactListLocator_v1` (one field, no alternate keys). In section 5.2, `brain init` on head 9196e5be9 declared all 25 schemas with no stand-in. | done |
| B11 | Decided by Tom on 2026-10-30: "Just build a new database and then do a one-time read of the old one and put it into the new one", and do not worry about the data too much. New mutations with new atom identities, authors, and clocks are accepted (section 9). | done |
| B12 | Decided by the same instruction. The one-time read uses the existing list route of the old daemon for key membership, with bounded pages and the Brain type directory. | done |
| B13 | Closed. Tests are retired. The product proof is the synthetic end-to-end run on the signed pair (section 5.6) and the read-only census of the primary. | done |
| B14 | Not on the primary. The primary has 0 TagIndex and 0 TagMembership records, and the census found 0 app-id tags (section 5.6). The helper still refuses a changed tag address. | done |

The source review at `ee0a9cd16946f38bf15d4cd81fe32f24a0fab1ff` found explicit-null loss and incomplete target digest coverage.
The corrective source preserves nulls and refuses incomplete reads and digests. Section 5.6 is the product proof on the signed pair.
The existing peer import is not a replacement: it requires unchanged schema and molecule identities and refuses signed tips and file references.
Do not relax those peer admission rules for this migration.

## 9. Loss compared with the in-place conversion

The in-place conversion was removed on 2026-10-30. This section stays as the record of what the home copy does not keep.

| Item | In place (removed) | Home copy |
|---|---|---|
| Atom history, atom UUIDs, authors, clocks | Kept | Lost |
| LastDB tombstones of deleted records | Kept | Lost |
| Brain soft-delete and backlink tags | - | Kept, renamed to `__brain_deleted__` and `__brain_backlink__:` |
| Molecule IDs and file `blob_ref`/`dek` | Kept | New |
| V2 backup stream | Same stream | New stream; the old stream stays for recovery |
| Not-moved schemas | Convert or drop. On 2026-10-30 Brain and LastDB refuse the drop of named legacy schemas. | Export. They stay only in the rollback home. No drop is necessary. |
| Sop in the Concept schema | The Brain conversion refuses it on 2026-10-30. | The copy writes Sop records to the new Sop schema. |
| Rollback | Forward only after format activation, or a V2 restore | Two `mv` commands while no new write exists |
| Old program and old data | Changed | Untouched in `$BACK` |
| Write freeze | Each converter pauses non-GET requests (423) | About 10 to 15 minutes |

The home copy keeps every current value, every key, every file byte, the identity, and the account.
