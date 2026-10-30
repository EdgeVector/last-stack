# LastDB home copy for the protein removal

This document gives the Brain migration path for the protein removal on the primary LastDB.
On 2026-10-30 the in-place Brain conversion was removed. This home copy is the only Brain migration path.
The path makes a new home, copies the kept records into it, and then moves the homes.

The helper is `bin/last-stack-lastdb-home-copy`.
It is one Python file. It uses only the two daemon sockets.

CAUTION: Nobody ran this runbook on the primary. Only the read-only plan and census ran on the primary.

## 1. Summary

- The old home `~/.lastdb` stays as it is. It becomes the rollback home.
- A new home gets the same identity and cloud credentials, and no data.
- A second daemon serves the new home on its own socket. It runs the protein-free release (#803, API 13).
- The new Brain and LastSecrets releases declare their own schemas on the new home.
- The helper reads every kept record from the old daemon and writes it to the new daemon in batches.
- The helper verifies each schema by key set, by a value digest per record, by file bytes, and by spot reads.
- A short write freeze copies the last changes. Then the homes change places.

The plan and census on the primary found no value problem. Design has 38 records and a stored count of 37. The coordinator accepted 38 on 2026-10-30. The runbook names that value with `--accept-directory-count design=38`.

The synthetic proof passed end to end on the #803 pair (head 11280163c) from CI. It covered the copy, the verify, the export, and the home move on a format 6 store (section 5).
`brain init` on #803 needs a fix first. #803 refuses the keyless Brain schema `BrainCompactListLocator_v1` (B10).

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

On 2026-10-30 the label `native-dev-artifact` went on #803. Run 41126284642 built the pair for head 11280163c. The synthetic proof used that pair (section 5.1).

The dev pair is for proof runs only. It has an adhoc linker signature and a 3-day life.
The primary cutover uses the signed pair from `mini-upgrade-artifact.yml` after #803 merges (Step 2).

### Q4. How the apps declare schemas on the new home

- Brain (brain#484): `brain init` with a staging config. The variables are `BRAIN_CONFIG` (or `FBRAIN_CONFIG`) and `FBRAIN_FOLDDB_SOCKET`. The socket variable wins over the config (`src/client.ts:180-185`).
  - Init declares 25 owned schemas with the canonical field names. The config gets `schemaFieldAliases` and `storageModel: multi-key-v1`.
  - On #803 head 11280163c, init stops at `BrainCompactListLocator_v1`. That schema has `key: {}`. #803 refuses it with `alternate keys require a declared primary hash field` (B10).
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
- Backup: take a manual V2 backup of the old home before the freeze. Connect the new home after the cutover, take a manual backup, and turn on the automatic backup.
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
- A refusal stops the route before its first write:
  - An unselected key (override: `--allow-unselected`).
  - A count guard difference. The override names the accepted value: `--accept-directory-count TYPE=N` (for example `design=38`). The report shows the stored count, the accepted count, and the selected records.
  - An accepted value that differs from the selected records. A new Design record before the run changes the number, and the run refuses. There is no plain skip.
  - A target schema without independent fields (override: `--allow-shared-value-target`, for the synthetic proof only).
- A record with an issue is not written: an unmapped field, a type error, a value over `--value-max-bytes`, or an alternate key problem.
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

- Run 41126284642 of `native-dev-artifact.yml` built head 11280163cfeb0a3f401aa99eb2ba24a65f4db23e. No local build ran.
- The zip sha256 equals the artifact digest (`9abaffee5dc92e2f…`). `shasum -c SHA256SUMS` passed for both programs.
- `SOURCE_COMMIT` equals the head. `TARGET` is `aarch64-apple-darwin`.
- `codesign --verify --strict` passed for both programs (adhoc, linker-signed). `lipo -archs` prints `arm64`.
- Both programs print `nightly-20261030-85ff2b6d2-102-g11280163c`.

### 5.2 End-to-end run on the #803 pair

Setup:

- Source: program a1c406f5 on a new home, with `LASTDB_ISOLATED_COPY=1`. It got old-layout schemas with synthetic data.
- Data: 250 references, 7 concepts and 5 sops in one Concept schema, 30 decisions, 1 design with a stored count of 0, 2500 list pages, 5 body files, 3 papercuts, 6 secrets, and one export-list schema with a file.
- Planted problems: one orphan concept with no directory record, one date-only DateTime value, and the design count.
- Target home: the OLD CLI `prepare-recovery-home` (`--env dev`, a synthetic API key) made it. `ok`, both `matches` fields true, 3 files, mode 0700, the same identity.
- Target daemon: the #803 program on that home. API 13, format 6, the same user hash as the source.
- App schemas: `brain init` (brain#484 at 5c71286b) and `lastsecrets init` (lastsecrets#14 at 8b2d8720) ran against the target only, with Bun.
  - `brain init` stopped at `BrainCompactListLocator_v1` (B10). A temporary copy of Brain skipped that one schema. Then init declared 24 schemas with `multi-key-v1`. The Brain runtime does not need that schema (`list-locator.ts` falls back to `BrainListLocator`).
  - LastSecrets init declared `LastSecret` and `LastSecretIndex`.

Results:

1. The plan with the target showed no `independent_fields` refusal.
2. Without overrides the plan refused the orphan and the design count. The count refusal named the fix: `--accept-directory-count design=1`.
3. The first copy (`--accept-directory-count design=1 --allow-unselected --normalize-datetime`) wrote 3,103 records in 2.6 s. All 11 routes were equal. 5 file checks and all spot reads passed.
4. Brain reads on the target:
   - `get` of the date-only decision worked with `appIdentityEnforce` false and true.
   - `list` by type worked for design, sop, concept, reference, and decision. These reads use the alternate keys.
   - `search` found nothing. The synthetic source has no token sets.
5. LastSecrets on the target: `list` showed 6 slugs. `admin-slice` gave metadata keys only.
6. Freeze: the source got an update, an add, a delete, and a field removal. Then the old program moved to a private socket. The default socket did not answer.
7. The last copy with `--delete-extra` took 1.07 s:
   - It wrote 3 reference records and 1 directory record.
   - It deleted 1 extra key in each of the two schemas.
   - The verify was equal on all 11 routes.
8. `--export` wrote ChildTaskIndex (12 records, 1587 bytes) with mode 0600 and a sha256 manifest.
9. Home move: both daemons stopped cleanly. One `mv` made the source home the rollback home. A second `mv` put the new home on the primary path. The moved home reports format 6.
10. The #803 daemon started on the moved home with its default socket.
11. The verify after the move was equal on all 11 routes, with 5 file checks. The rollback home was the source, on a private socket.
12. Brain reads on the moved home with `appIdentityEnforce: true`:
    - `get` worked.
    - The changed title showed.
    - The deleted reference returned `No reference`.
13. LastSecrets `list` on the moved home showed 6 slugs.
14. The secret scan found no "SYNTH-SECRET" value and no synthetic API key in any output, report, export, log, or configuration file.
15. Clean-up: the run stopped both daemons and removed the temporary folder. After the run, only the primary daemon ran.

### 5.3 The first run (API 7 on both daemons)

An earlier run used program a1c406f5 for the source and the target. It showed these guards:

- The helper refused a target under a protected home, the same socket, and different user hashes.
- A second run into the same export folder was refused.
- A pass with no change took 0.8 s.

### 5.4 Limits of the proof

- The data is synthetic and small. The primary has about 101,800 records.
- The source home used `--env dev`. The primary uses PROD. The PROD Schema Service path did not run.
- `brain init` used a stand-in for B10.
- Brain writes with `appIdentityEnforce: true` on #803 did not run. Only reads ran.
- `brain search` did not run on copied token sets.
- Backup V2 (Steps 8a and 12) did not run.
- The LaunchAgent, the plist change, and `last-stack-lastdb-current` (Step 10) did not run.
- The 423 pause did not run.
- brain#484 moved to f1bd8cfb after the run. That head changes the alternate key wire form (`src/alternate-key-wire.ts`). The run did not use it.

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
export BASE=$(basename "$(readlink "$OLD/current")")
export W="${LAST_STACK_EVIDENCE_ROOT:-${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/last-stack}/home-copy-protein-removal-20261030"
export X="${XDG_STATE_HOME:-$HOME/.local/state}/last-stack/artifacts/protein-removal-20261030/home-copy-export"
export COPY="<accepted last-stack checkout>/bin/last-stack-lastdb-home-copy"
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
lastsecrets get lastdb-primary-cloud-api-key-prod \
  | "$OLD/current/lastdb" --data-dir "$OLD" cloud prepare-recovery-home --into "$NEW" --env prod --api-key-stdin --json \
  > "$W/s3-prepare.json"; echo "rc=$?"
jq -c '{ok, credentials_only, identity_matches_source, api_key_matches_source, saved_url_matches_environment,
  cloud_sync_off, data_directory_created, files, home_mode}' "$W/s3-prepare.json"
```

The key goes through the pipe only. It does not go to the terminal or to a file.

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
export BRAIN_CONFIG="$W/staging-config/brain.json" FBRAIN_CONFIG="$W/staging-config/brain.json"
export FBRAIN_FOLDDB_SOCKET="$NEW/data/folddb.sock"
"$BR/bin/brain" init --schema-service-url "$(jq -r .schemaServiceUrl "$HOME/.brain/config.json")" --yes
bun "$LR/src/cli.ts" init --config "$W/staging-config/lastsecrets.json" --socket "$NEW/data/folddb.sock"
for f in brain lastsecrets; do
  jq --arg s "$NEW/data/folddb.sock" '.nodeSocketPath=$s' "$W/staging-config/$f.json" > "$W/staging-config/$f.tmp" \
    && mv "$W/staging-config/$f.tmp" "$W/staging-config/$f.json"
done
jq '.appIdentityEnforce=true' "$W/staging-config/brain.json" > "$W/staging-config/brain.tmp" \
  && mv "$W/staging-config/brain.tmp" "$W/staging-config/brain.json"
jq -c '{socket: .nodeSocketPath, keys: (.schemaHashes|length), model: .storageModel, enforce: .appIdentityEnforce}' "$W/staging-config/brain.json"
jq -c '{socket: .nodeSocketPath, secret: .schemaHash, index: .indexSchemaHash}' "$W/staging-config/lastsecrets.json"
```

Use the release checkouts. Do not change the installed `brain` or `lastsecrets` programs in this step.

Check: Brain has 25 keys, `multi-key-v1`, and `enforce` true. LastSecrets has both pins. Both sockets name `$NEW`.

If `brain init` stops at `BrainCompactListLocator_v1`, B10 is still open. Stop the staging daemon and wait for the fix.

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

Rollback: none needed. The copy writes the staging home only.

### Step 7. App read checks on the staging home

Use the Step 5 shell (the three Brain variables are set).

```bash
"$BR/bin/brain" get decision-2026-09-25-revert-primary-brain-to-lastdb --type decision | head -5
"$BR/bin/brain" search "LastDB" --limit 5 --json > "$W/s7-search.json"; jq -r '.. | .slug? // empty' "$W/s7-search.json" | head
LASTSECRETS_CONFIG="$W/staging-config/lastsecrets.json" bun "$LR/src/cli.ts" list | wc -l
LASTSECRETS_CONFIG="$W/staging-config/lastsecrets.json" bun "$LR/src/cli.ts" admin-slice | jq 'keys'
```

`list` and `admin-slice` take no `--config` flag. They read `LASTSECRETS_CONFIG`.

Check: `get` shows the record. `search` gives slugs. The LastSecrets list count equals the plan (164 on 2026-10-30). No secret value appears.

### Step 8. Freeze: final old backup, then a private socket for the old daemon

8a. Manual V2 backup of the old home while it is still on its own socket:

```bash
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 status --json > "$W/s8-v2-before.json"
jq -c '{running, phase, auto: .automatic_backup.enabled, pending: .automatic_backup.pending_request_id}' "$W/s8-v2-before.json"
export R0=$(uuidgen | tr 'A-Z' 'a-z'); echo "$R0" > "$W/R0.request-id"
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 start --request-id "$R0" --json > "$W/s8-R0.json"; echo "rc=$?"
"$OLD/current/lastdb" --data-dir "$OLD" cloud backup-v2 status --json > "$W/s8-v2-R0.json"
jq -c '{request_id, phase, running, ordinal: .last_accepted_backup.ordinal}' "$W/s8-v2-R0.json"
```

Check: `request_id` equals R0, `phase` is `published`, `running` is false. If `auto` is true, run `backup-v2 disable-automatic --json` first.

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
plutil -replace ProgramArguments.0 -string "$OLD/native-run-v2-programs/$C803/lastdbd" "$PLIST"
plutil -lint "$PLIST"
"$HOME/.last-stack/bin/last-stack-lastdb-current" set --lastdb-home "$OLD" --bin-dir "$OLD/native-run-v2-programs/$C803"
launchctl bootstrap "gui/$(id -u)" "$PLIST"
"$HOME/.last-stack/bin/last-stack-lastdb-current" check --verbose
curl -s --unix-socket "$OLD/data/folddb.sock" http://localhost/api/version | jq -c '{api_version, build}'
```

Wait for each `kill` until `pgrep` shows no daemon on `$OLD`, `$NEW`, or the private socket. The log ends with the shutdown line.

Check: API 13 on `~/.lastdb/data/folddb.sock`. `last-stack-lastdb-current check` passes. `~/.folddb` still points to `~/.lastdb`.

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
jq --arg s "$OLD/data/folddb.sock" '.nodeSocketPath=$s | .appIdentityEnforce=true' "$W/staging-config/brain.json" > "$HOME/.brain/config.json"
jq --arg s "$OLD/data/folddb.sock" '.nodeSocketPath=$s' "$W/staging-config/lastsecrets.json" > "$HOME/.lastsecrets/config.json"
unset BRAIN_CONFIG FBRAIN_CONFIG FBRAIN_FOLDDB_SOCKET
jq -c '{socket: .nodeSocketPath, enforce: .appIdentityEnforce}' "$HOME/.brain/config.json"
```

Check: `enforce` is true (B5).

11c. Install the new Brain and LastSecrets releases with the `app-safe-upgrade` skill (probe, then activate on GREEN).

11d. Remove the hold and check the apps:

```bash
rm "$OLD/monitoring/lastdbd-revive.hold"
brain get decision-2026-09-25-revert-primary-brain-to-lastdb --type decision | head -3
lastsecrets list | wc -l
```

The write freeze ends here.

### Step 12. Backup on the new home

```bash
lastsecrets get lastdb-primary-cloud-api-key-prod \
  | lastdb --data-dir "$OLD" cloud backup-v2 connect --existing --env prod --api-key-stdin \
    --expected-user-hash "$(jq -r .userHash "$HOME/.brain/config.json")" --json > "$W/s12-connect.json"; echo "rc=$?"
export R1=$(uuidgen | tr 'A-Z' 'a-z'); echo "$R1" > "$W/R1.request-id"
lastdb --data-dir "$OLD" cloud backup-v2 start --request-id "$R1" --json > "$W/s12-R1.json"; echo "rc=$?"
lastdb --data-dir "$OLD" cloud backup-v2 enable-automatic --log-interval-seconds 60 --snapshot-interval-seconds 86400 --json \
  > "$W/s12-enable.json"
lastdb --data-dir "$OLD" cloud backup-v2 status --json > "$W/s12-status.json"
jq -c '{request_id, phase, running, auto: .automatic_backup.enabled, blocked_reason}' "$W/s12-status.json"
```

Check: `request_id` equals R1, `phase` is `published`, `auto` is true, `blocked_reason` is null. The stream id differs from the old stream.

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
Turn on the automatic backup of the old home if Tom wants it: `lastdb --data-dir "$OLD" cloud backup-v2 enable-automatic --log-interval-seconds 60 --snapshot-interval-seconds 86400 --json`.

## 8. Blockers and decisions

| ID | Blocker or decision | Owner |
|---|---|---|
| B1 | Open. #803 is not merged. The primary needs the signed pair from a main commit (Step 2a). The dev pair of head 11280163c exists for proof runs (label `native-dev-artifact`, kept 3 days). | #803 author |
| B2 | Open. The brain#484 definitions must exist in the PROD Schema Service. Tom allowed the publish on 2026-10-30. A separate agent does it. LastSecrets#14 definitions are already in PROD. | publish agent |
| B3 | Open. brain#484 and lastsecrets#14 are not merged. The runbook needs their merged commits. brain#484 has two writers, and its head moves (f1bd8cfb on 2026-10-30). | app authors |
| B4 | Decided 2026-10-30. Design: trust the 38 records over the stored count of 37. The new Brain rebuilds its counts. The runbook names `--accept-directory-count design=38`. | done |
| B5 | Decided 2026-10-30. `appIdentityEnforce` stays true. Steps 5 and 11b set it. Brain reads with true passed in the proof. Brain writes with true on #803 did not run. | done |
| B6 | Decided 2026-10-30. Tom allowed `brain init` and read-only `brain get` and `brain search` against the NEW home for this migration. | done |
| B7 | Open. Two V2 streams on one account. The quota and the cost are not known. The old stream stays for recovery. | Tom |
| B8 | Closed by the proof. The #803 daemon ran in the synthetic run (section 5.2). The first check on real data is still Step 6. | operator |
| B9 | Closed by the proof. The home move ran on a format 6 store, and the #803 daemon started on the moved home. If the real move fails, point the plist, the configs, and `current` at `~/.lastdb-v13` instead. | operator |
| B10 | Open. brain#484 declares `BrainCompactListLocator_v1` with `key: {}`. #803 head 11280163c refuses it: `alternate keys require a declared primary hash field`. `brain init` stops there. Fix (a): LastDB accepts a keyless one-field schema with no alternate keys. Fix (b): Brain gives the locator a hash field in a new version. On the home-copy path, fix (b) needs no LastDB drop, because the new home never holds v1. | #803 author or Brain author |

## 9. Loss compared with the in-place conversion

The in-place conversion was removed on 2026-10-30. This section stays as the record of what the home copy does not keep.

| Item | In place (removed) | Home copy |
|---|---|---|
| Atom history, atom UUIDs, authors, clocks | Kept | Lost |
| Tombstones | Kept | Lost |
| Molecule IDs and file `blob_ref`/`dek` | Kept | New |
| V2 backup stream | Same stream | New stream; the old stream stays for recovery |
| Not-moved schemas | Convert or drop. On 2026-10-30 Brain and LastDB refuse the drop of named legacy schemas. | Export. They stay only in the rollback home. No drop is necessary. |
| Sop in the Concept schema | The Brain conversion refuses it on 2026-10-30. | The copy writes Sop records to the new Sop schema. |
| Rollback | Forward only after format activation, or a V2 restore | Two `mv` commands while no new write exists |
| Old program and old data | Changed | Untouched in `$BACK` |
| Write freeze | Each converter pauses non-GET requests (423) | About 10 to 15 minutes |

The home copy keeps every current value, every key, every file byte, the identity, and the account.
