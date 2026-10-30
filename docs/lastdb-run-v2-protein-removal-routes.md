# LastDB protein removal routes

## Scope

These closed routes move the primary from `a1c406f5` to the protein removal release.
Each route admits one exact program pair or one offline format change.
Each route keeps the format 4 final stopped backup policy of
[format 4 maintenance](lastdb-format4-automatic-maintenance.md).
No route copies the primary. No route restores or migrates primary data.

| Profile | Kind | Baseline | Candidate | Marker before | Marker after |
|---|---|---|---|---|---|
| `run-v2-a1c406f5-to-c793-format4-v1` (P1) | program | `a1c406f5` | C793 | format 4 | format 4 |
| `run-v2-c793-format6-activation-v1` (P1b) | activation | C793 | C793 | format 4 | format 6 |
| `run-v2-c793-to-c803-format6-v1` (P2) | program | C793 | C803 | format 6 | format 6 |

C793 is the accepted lastdb main commit that has lastdb#793 and not lastdb#803.
C803 is the accepted lastdb main commit that has lastdb#803.

## Pins

`lib/canary-loom/native_run_v2_routes.py` holds the only two pins.
Each pin is one line. A route stays closed while its pin is `None`.

```python
C793 = "<full 40-character lastdb main commit>"
C803 = "<full 40-character lastdb main commit>"
```

Every other value comes from the pinned commit, the reviewed source record, or GitHub metadata.
The gate reads each run ID from the hashed evidence. Then it verifies the run properties on GitHub.

## Schemas and protocol

- Approval schema: `lastdb.run-v2-maintenance-approval.v5`.
- Evidence schema: `lastdb.run-v2-maintenance-evidence.v5`.
- Launcher protocol: `15`. The upgrade journal uses `lastdb.run-v2-maintenance-upgrade.v4`.
- Execution key: `safe-upgrade-v15-<candidate digest>-native-<approval SHA256>`.

## Order

1. Run P1. The primary then runs C793 at format 4.
2. Run P1b. The primary then runs C793 at format 6.
3. Do the explicit conversions and the drops that Tom approved for C793.
4. Declare the upgrade probe schema and write its one record. See [Upgrade probe](#upgrade-probe-for-p2).
5. Make the accepted V2 backup and its source-free restore proof for P2.
6. Run P2. The primary then runs C803 at format 6.

CAUTION: Do not run `host-track refresh loom` and do not run `loom init` between P1 and P2.
The launcher uses the installed Loom (`loom 0.1.1`) in local recovery mode.
That mode reads only `~/.local/state/last-stack/loom/recovery/executions.jsonl`.
It does not read `~/.loom/schema-hashes.json` and does not contact LastDB.

## Approval fields

Each approval has the format 4 final stopped fields, with these differences.

| Field | Value |
|---|---|
| `schema` | `lastdb.run-v2-maintenance-approval.v5` |
| `profile` | the route profile |
| `source_git_oid`, `accepted_main_commit` | the route candidate commit |
| `baseline_source_git_oid` | the route baseline commit |
| `baseline_programs_sha256` | the installed pair: P1 uses the `a1c406f5` pin; P1b uses the candidate pair; P2 uses the C793 pair |
| `recovery_policy` | P1 and P2: `accepted-stopped-native-cut-and-saved-pair`; P1b: `accepted-stopped-native-cut-offline-activation-and-saved-pair` |
| `baseline_writer_policy` | `{path, sha256}` of a fresh `lastdb.primary-writer-policy-observation.v1` of the live primary pair |
| `development_writer_policy` | P1b only: the writer observation that the P1 Mac DEV operation used |
| `format_activation` | P1b only: see below |
| `proofs` | SHA256 of `artifact_receipt`, `development_proof`, `compatibility_record`, `stopped_development_proof` |
| `target_program_dir` | `<primary_home>/native-run-v2-programs/<source_git_oid>` |

P1b requires this exact value:

```json
{"from": "format=4\nhome=disk-run\ncas=disk-cas\nranges=typed-v1\n",
 "to": "format=6\nhome=disk-run\ncas=disk-cas\nranges=typed-v1\nalternate-keys=v2\n",
 "command": "db enable-alternate-keys --i-know-this-is-primary --json",
 "recovery": "same-pair-restart-forward-only"}
```

The gate refuses `automatic_backup_enabled`, `current_writer_policy`, and `baseline_recovery_state`.
These fields belong to the historical profile only.

The other required fields keep their format 4 meaning:
`mode`, `approved_by`, `quote`, `approved_at`, `cloud_off`, `primary_home`, `launchd_plist`,
`memory_limit_mb`, `keyed_read`, `recovery`, `final_backup`, `automatic_restore`,
`primary_data_copy`, `primary_restore_or_migration`, `primary_validation`,
`evidence_path`, and `evidence_sha256`.

## Evidence fields

| Field | Meaning |
|---|---|
| `schema`, `profile` | `lastdb.run-v2-maintenance-evidence.v5` and the route profile |
| `source_git_oid`, `accepted_main_commit` | the route candidate commit |
| `source_repository` | a local lastdb clone that has both route commits |
| `compatibility_record`, `compatibility_sha256` | the route source review (below) |
| `artifact_receipt`, `artifact_receipt_sha256`, `artifact_archive` | the verified Mini artifact of the candidate |
| `baseline_artifact_receipt`, `baseline_artifact_receipt_sha256`, `baseline_artifact_archive` | P2 only: the verified Mini artifact of C793 |
| `required_ci_run`, `accepted_main_benchmark_run`, `linux_dev_run` | the GitHub run IDs; the gate checks each run |
| `development_proof`, `development_sha256` | the main Mac DEV proof |
| `stopped_development_proof`, `stopped_development_sha256` | the stopped extension (P1, P2) or the activation extension (P1b) |

The route source review uses schema `lastdb.run-v2-route-source-review.v1`. It holds:

- `profile`, `baseline`, `candidate`, `baseline_tree`, and `candidate_tree`.
- `reviewed_changes`: the complete Git mode, type, and blob map from the baseline to the candidate.
- `reviewed_paths` and `reviewed_changes_sha256` for that map.
- `baseline_node_marker` and `candidate_node_marker` as text.
- `format_activation`: `true` for P1b only. P1b has no source change.
- `source_reviewed: true`, `legacy_format_support: false`, and `primary_restore_or_migration: false`.

The baseline must be the single merge base of the candidate.

## Mac DEV proofs

The main Mac DEV proof uses the existing qualifier with a route argument.
P1b uses the P1 main proof. P1b does not run its own main proof.

```bash
Q="$LS/lib/canary-loom/native_run_v2_auto_qualify.py"
python3 "$Q" plan --route run-v2-a1c406f5-to-c793-format4-v1 \
  --output "$W/dev-p1" --homes "$H/p1" --source-repository "$LASTDB" \
  --baseline-bin-dir "$A1C/bin" --baseline-version "$A1C_VERSION" \
  --candidate-receipt "$C793_ART/receipt.json" --credential-home "$CRED" \
  --catalog-read-result "$CATALOG" --writer-policy-result "$W/writer-a1c406f5.json" \
  --account "$DEV_ACCOUNT" --memory-limit-mb "$LIMIT"
python3 "$Q" run --plan "$W/dev-p1/plan.json" --approved-plan-sha256 "$PLAN_SHA" --execute
```

For P2, use `--route run-v2-c793-to-c803-format6-v1`. Add `--baseline-receipt` with the C793 Mini receipt.
Use the C803 receipt as the candidate receipt. Use a writer observation of the primary at C793.

With `--route`, the qualifier changes only these values:

- The plan binds the candidate receipt, the writer receipt, and the catalog read by hash. No pin applies.
- The frozen helpers and the compiled profile come from the route candidate commit.
- The restored marker and the receipt profile come from the route marker: format 4 is profile 2; format 6 is profile 4.
- The proof records the route profile and protocol 15.

The stopped extension (`lastdb.run-v2-route-stopped-development.v1`) keeps the format 4 extension contract.
It uses the route profile, protocol 15, and the route marker.

The activation extension (`lastdb.run-v2-route-activation-development.v1`) adds an `activation` record:

- `before`: a `lastdb.native-file-list.v1` list of the stopped DEV home. It equals the captured manifest.
- `result`: the CLI result on the stopped DEV home with `home`, `programs`, `source`, `operation_sha256`, `reply`, `exit_code: 0`, and `observed_at`.
- `after`: the second file list. It differs from `before` only in the node marker, which is format 6.
- `read`: the boot after the activation at stage `activated-source`, with 14 records, 2 absent records, and the exact files.

The extension producers stay outside this repository, as on 2026-10-29.

## Launcher

Use a clean last-stack checkout `$LS` at the merged main commit. Use the verified Mini artifact pair `$C`.

```bash
"$LS/bin/last-stack-safe-upgrade-loom" --candidate "$C793/bin/lastdbd" \
  --native-run-v2-ci-approval "$W/approval-p1/approval.json" --json
"$LS/bin/last-stack-safe-upgrade-loom" --candidate "$C793/bin/lastdbd" \
  --native-run-v2-ci-approval "$W/approval-p1b/approval.json" --json
"$LS/bin/last-stack-safe-upgrade-loom" --candidate "$C803/bin/lastdbd" \
  --native-run-v2-ci-approval "$W/approval-p2/approval.json" --json
```

## The offline activation (P1b)

P1b keeps the exact pair that P1 selected. The candidate directory is the current pointer target.

1. The route stops the primary with the strict clean stop.
2. The verified candidate CLI makes the final stopped backup. The route verifies every file hash.
3. The route records `activation-requested`. Then it runs `lastdb --data-dir <home> db enable-alternate-keys --i-know-this-is-primary --json`.
4. The route requires the exact format 4 to format 6 reply and the format 6 marker.
5. The route re-hashes every native file of the final backup except the marker. Each file must keep its bytes.
6. The route records `activated`. Then it restarts the same pair and completes the five-minute soak.

Recovery restarts the same pair. The marker change is forward only.
If an interrupted run changed the marker, recovery proves and records the change before the restart.
If that proof fails, the primary stays stopped for review.

## Upgrade probe for P2

CAUTION: Do not reuse the earlier keyed read for P2. It names the compaction receipt schema `c010ab51…`. Tom drops that schema before P2.

CAUTION: The declaration registers the schema definition with the Schema Service. It registers no record value.

Run these commands on the primary at C793, after the conversions and drops, before the P2 backup.
Each command sends one request. The write sends one batch with the one record.

```bash
P="$HOME/.local/state/last-stack/artifacts/lastdb/upgrade-probe-c793"
SOCK="$HOME/.lastdb/data/folddb.sock"
mkdir -m 700 "$P"
cat > "$P/declare.json" <<'JSON'
{"app_id":"lastdb-upgrade-probe","schema":{"name":"UpgradeProbeReceipt","descriptive_name":"UpgradeProbeReceipt",
 "schema_type":"Hash","key":{"hash_field":"receipt_id"},"independent_fields":true,
 "fields":["receipt_id","receipt_value"],
 "field_types":{"receipt_id":"String","receipt_value":"String"},
 "field_descriptions":{"receipt_id":"synthetic upgrade probe receipt key","receipt_value":"synthetic upgrade probe receipt value"},
 "field_data_classifications":{"receipt_id":{"sensitivity_level":0,"data_domain":"general"},
  "receipt_value":{"sensitivity_level":0,"data_domain":"general"}}}}
JSON
curl --fail-with-body -sS --max-time 120 --unix-socket "$SOCK" \
  -H 'Content-Type: application/json' -H 'X-LastDB-Client: lastdb-upgrade-probe' \
  --data-binary @"$P/declare.json" http://localhost/api/apps/declare-schema > "$P/declare-reply.json"
SCHEMA="$(jq -er '(.data // .).canonical | select(test("^[0-9a-f]{64}$"))' "$P/declare-reply.json")"

jq -nc --arg s "$SCHEMA" '{convergence:"sync",mutations:[{type:"mutation",schema:$s,
  mutation_type:"create",key_value:{hash:"upgrade-probe-c793-to-c803"},
  fields_and_values:{receipt_id:"upgrade-probe-c793-to-c803",
  receipt_value:"synthetic receipt for the C793 to C803 keyed read"}}]}' > "$P/write.json"
curl --fail-with-body -sS --max-time 60 --unix-socket "$SOCK" \
  -H 'Content-Type: application/json' -H 'X-LastDB-Client: lastdb-upgrade-probe' \
  --data-binary @"$P/write.json" http://localhost/api/mutations/batch > "$P/write-reply.json"
jq -e '(.data // .).count == 1' "$P/write-reply.json"
```

Make the P2 keyed-read input. Then read it with the same request that the route sends.

```bash
umask 077
jq -n --arg s "$SCHEMA" '{schema:"lastdb.native-keyed-read.v1",application:"lastdb-upgrade-probe",
  schema_name:$s,fields:["receipt_id","receipt_value"],
  keys:[{hash:"upgrade-probe-c793-to-c803",range:""}]}' > "$P/primary-keyed-read.json"
shasum -a 256 "$P/primary-keyed-read.json"
jq -nc --arg s "$SCHEMA" '{schema_name:$s,fields:["receipt_id","receipt_value"],
  filter:{HashRangeKeys:[["upgrade-probe-c793-to-c803",""]]},limit:1}' \
  | curl --fail-with-body -sS --max-time 30 --unix-socket "$SOCK" \
      -H 'Content-Type: application/json' -H 'X-LastDB-Client: lastdb-upgrade-probe' \
      --data-binary @- http://localhost/api/query > "$P/read-reply.json"
jq -e '(.data // .) | .unresolved_rows == 0 and .tombstoned_rows == 0 and .has_more == false
  and (.results | length) == 1' "$P/read-reply.json"
```

Set the P2 approval `keyed_read` to this value:

```json
{"input_path": "<P>/primary-keyed-read.json", "input_sha256": "<the shasum output>"}
```

### If the declaration fails

The PROD Schema Service keeps its developer-account gate. It can refuse the new definition with a certificate or developer error.

1. Do not write a record. Keep `declare-reply.json` as the refusal record.
2. Do not use LastSecrets (`6a570228…`, fields `slug` and `secret_value`). Its records hold secret material, and the read result goes into an artifact.
3. Do not use the compaction receipt schema `c010ab51…`. Tom drops it before P2.
4. Do not relax the name guard in `lib/canary-loom/native_v2_read.py`. The guard refuses an application or schema name that contains `brain`, `kanban`, or `situation`. Its reason still applies: the 2026-10-14 standing rule says that no agent reads brain, kanban, or situations until Tom says they are back. The kept converted records of lastdb#793 are the F-Kanban and Brain records. All of them are in the guarded namespaces.
5. Stop before the P2 backup. Report the refusal to Tom. Tom can choose one of these actions:
   - Enable the developer account for `lastdb-upgrade-probe` on PROD. Then run the declaration again.
   - Say that brain or kanban is back. Then name one kept, non-secret, converted record. Remove only that namespace from the guard in a reviewed PR.
   - Name another kept, non-secret schema outside the guarded namespaces that C803 loads.

The route has no keyed-read waiver. P2 does not start without a keyed read that passes.

## Known limits

- The qualifier route mode and the activation have source checks only. Their first real run is the DEV operation.
- C803 can refuse the public file contract `9fdab70c…` if that contract keeps a shared-value layout. Then the P2 qualifier needs a catalog change.
- The Linux DEV run on a main push can be cancelled by its concurrency group. Then pin a later main commit that has a successful run.
