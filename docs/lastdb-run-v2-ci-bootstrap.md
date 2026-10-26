# RunV2 Cloud-Off bootstrap through Loom

The separate `native-run-v2-ci-cloud-off` mode uses protocol 11.
Its versioned profile is `run-v2-ci-bootstrap-v1`.
Protocols 7, 8, 9, and 10 keep their existing behavior.
This mode changes only the selected program pair on the existing RunV2 primary.
It does not copy, restore, migrate, or rewrite the primary data.

CAUTION: This bootstrap creates no new primary cloud recovery point.
Recovery uses the saved program pair and the same native files.
Tom must approve that recovery policy for the exact candidate.
The mode keeps Cloud Off through the upgrade and the five-minute health interval.
Connection and a new PROD backup are separate operations after successful completion.
The primary gate proves metadata and health continuity.
It reads no primary records and discovers no record keys.
Full primary logical backup validation occurs after the upgrade through the new manual backup.

## Closed baseline and exact candidate

The only baseline source is `58752ee6e40c658735ee9d6423cedadda40383b4`.
Its installed program hashes are:

- `lastdb`: `3b7b52d441ef2a768fa9e862e0fa9a5ab15c889ee471b22579f25a516f8b5250`.
- `lastdbd`: `5fbc9aaf18667dff39742ab7eb1cc1c7c3bac809f8568ec4cacba850748e0dc2`.

The candidate comes from PR434's final head H and the normal Mac artifact workflow.
GitHub must report PR434 as merged with that exact head.
Its accepted merge M must remain an ancestor of main.
M's complete tree must equal H's complete tree.
The baseline must be an ancestor of H.
A squash merge does not require H to be an ancestor of main.

Both H and M need successful `ci-required` and `benchmark-complete` checks.
The evidence binds H's exact required workflow run and Mac artifact run.
M also needs real main-push benchmark measurements and successful artifact uploads.
The gate verifies the original retained Mac archive, GitHub digest, source, target, and both program hashes.
The archive must remain unexpired at GitHub.
The exact pair must pass signature, arm64, version, and hash checks.

The closed source policy binds H `ee8a5b78f4d337c26542fea5e38543ef523587f7`.
Its exact tree is `9d82065b4afbe58a312db64ba12a6ee85fc576f7`.
The policy binds all 96 protected changed paths to exact before/after Git entries.
Each entry includes the mode, object type, and blob hash.
Each map value is `[before, after]`; each entry is `[mode, type, object ID]` or null for absence.
The private compatibility record must contain the same complete map.
Unknown storage, writer, crypto, format, protocol, dependency, or build-input changes refuse activation.
The record states source review and no native format change.
It does not claim a backward reopen by itself.

Provenance uses bounded, credential-free HTTPS GET requests to the fixed public LastDB repository.
Rate limits, unavailable metadata, incomplete pages, and expired artifacts refuse the operation.
The gate does not create credentials or repair GitHub authentication.
It downloads no archive; the original verified local archive remains required.

## Original DEV and backward-read evidence

The exact H pair must complete a real owned DEV operation.
The proof uses 16 known records and one exact 8MiB logical file (`8388608` bytes).
The existing local CAS value cap prevents this operation from claiming one 100MiB RunV2 logical file.
Earlier 100MiB cloud transport evidence is separate.

The DEV operation requires these facts:

- Exact accepted Begin, account generation, transport stream, request, and commit.
- Both RunV2 home identities, generations, frontiers, descriptor hashes, and CURRENT hashes.
- An original manifest of every native file, with its exact path, length, and SHA256.
- Actual R2/B2 placement, complete transport verification, and real multi-file packs.
- Zero retained source bytes after accepted publication.
- Source-free restore into a fresh absent target, without cloud credentials in that target.
- Complete native file hash comparison before the first restored boot.
- Two ordinary restored read passes, with one restart, 16 records, and the complete 8MiB file hash.
- Exact clean-stop receipts and ledger records for the source and restored sessions.
- Ordinary reopen of the owned restored home with the exact baseline pair.
- The same known records and complete file hash under that baseline, followed by a clean stop.

The baseline reopen uses the existing native files and ordinary product calls.
It creates no schema, fixture program, primary copy, or new record mutation.
The DEV source may contain normal candidate writes before its backup.
The exact restored manifest and the baseline's read digest bind those writes to the backward-read proof.
Keep the original operational outputs outside Git until review and recovery consumers close.

The original proof uses schema `lastdb.run-v2-development.v1`.
It binds `client_source`, both `client_programs_sha256`, `environment=dev`, and `completed_at`.
It contains `source_home_path`, `restored_home_path`, both final session identities, and `request_id`.
It contains the exact `accepted_backup`, `run_profile`, and `native_root`.
It records `records_sha256` and `logical_file_sha256`; it contains no record bodies or file pointers.
The required completion booleans are `source_stopped`, `restored_stopped`, `source_free_restore`,
`restored_without_cloud_credentials`, `provider_routes_verified`, `transport_integrity_verified`, and `raw_native_files_verified`.

Each original output reference is exactly `{path, sha256}`.
Required references are `backup_status`, `native_manifest`, `source_binding`, `raw_file_verification`,
`restore_report`, `read_restart`, `source_stop`, and `restored_stop`.
The source binding is the original stream record: it binds the random transport stream UUID to the native source home UUID.
The native manifest uses `lastdb.run-v2-native-files.v1` with `begin`, `run_profile`, `native_root`, and `files`.
Each file retains the product fields `path`, `native_bytes`, and `native_sha256`.
The pre-boot hash receipt uses `lastdb.run-v2-restored-files.v1` with `home_path`,
`accepted_commit_sha256`, `before_first_boot=true`, and the exact same complete `files` list.
The restored read receipt contains `restart_count=1` and exactly two `passes`.
Each pass contains `records=16`, `records_sha256`, `file_bytes=8388608`, and `file_sha256`.
Stop references retain the actual `receipt` and matching unique clean `session` ledger record.

The separate backward receipt uses `lastdb.run-v2-baseline-reopen.v1`.
It binds `baseline_source`, `baseline_programs_sha256`, the restored `home_path`, `home_ids`, and `accepted_commit_sha256`.
It records `ordinary_product_read=true`, `schema_initialized=false`, `record_mutations=0`,
`primary_data_copy=false`, `daemon_stopped=true`, and its actual `completed_at` and `session`.
Its original `read_receipt` and `stop_receipt` references bind the complete ordinary read and clean stop.

## Approval and evidence inputs

The private approval uses schema `lastdb.run-v2-ci-bootstrap-approval.v1`.
It records the actual human quote, `approved_by=Tom`, and positive Unix `approved_at`.
No helper manufactures approval from the existence of DEV evidence.
A new cutover needs approval within 24 hours.
Interrupted recovery uses the original effect time and the same approval.

The approval binds these fields:

- `mode=native-run-v2-ci-cloud-off` and `profile=run-v2-ci-bootstrap-v1`.
- `source_git_oid=H`, `accepted_main_commit=M`, and `accepted_tree`.
- `candidate`: both exact paths, SHA256 values, and versions.
- The fixed `baseline_source_git_oid` and `baseline_programs_sha256` above.
- Canonical `primary_home` and the exact primary `launchd_plist`.
- `target_program_dir=<primary>/native-run-v2-programs/<H>`.
- `cloud_off=true`, `primary_data_copy=false`, and `primary_restore_or_migration=false`.
- `primary_validation=metadata-health-continuity`.
- `recovery_policy=saved-pair-same-run-v2-home`.
- `evidence_path`, its exact `evidence_sha256`, and the four `proofs` hashes below.

The evidence uses schema `lastdb.run-v2-ci-evidence.v1` and the same profile.
It names H, `source_repository`, M, `accepted_tree`, and `accepted_pull_request=434`.
It sets `github_metadata_transport=public_https`.
It names `required_ci_run`, `accepted_main_benchmark_run`, `artifact_archive`, and `artifact_receipt`.
It names `development_proof`, `baseline_reopen_proof`, and `compatibility_record`.
The approval's `proofs` exactly match these evidence hashes:
`artifact_receipt_sha256`, `development_sha256`, `baseline_reopen_sha256`, and `compatibility_sha256`.
All files must be private, bounded, unchanged, canonical external inputs.
Their paths must use the exact `~/.local/state/last-stack/artifacts` root or this profile's journal root.
Owned DEV homes also remain under that artifact root.
Case aliases, alternate volume paths, and symlink components cannot select a different input root.
The source Git repository keeps its separate exact Git identity policy.
The original artifact receipt keeps its existing schema and fields.

## Strict stop and local recovery

The mode uses the existing local Loom graph and host-wide owner lock.
Its separate journal lives under `lastdb-safe-upgrade/native-run-v2-ci-bootstrap/` outside LastDB.
It never reconciles into retired apps.
PROBE reads the supplied evidence; it starts no node and writes no records.

Before effects, the driver binds the exact baseline pair, primary session, process start,
LaunchAgent, current pointer, shell aliases, identity-file hash, node marker, both home descriptors, and existing LOCK files.
The health check requires fresh metadata, Cloud Off, an idle manual backup, a writable home, zero persist failures,
and a healthy RunV2 writer with valid native counters.
It does not impose pack-maintenance fields on RunV2.

The driver saves both old programs and stages the candidate in its isolated primary-only directory.
It makes no primary logical read or schema mutation.
The ordinary keyed reads remain confined to the owned DEV and baseline-reopen evidence.
The existing consumer check proves that every other consumer of the old executable is unloaded.
The strict stop uses the same unforced supervisor helper, exact flush receipt, and unique clean ledger record.
It restores the original executable inode and hash after unload.
Unknown consumers or a failed clean stop prevent installation.

While the supervisor is absent, the driver obtains existing owner locks without file creation.
It hashes both stopped CURRENT files with fixed read buffers and unchanged-file checks.
The same two hashes must match again before program selection.
It does not decode, re-encode, or change either CURRENT file.

The driver changes only the primary's program argument and current pointer.
Each candidate or rollback startup has a separate durable intent before bootstrap.
A fresh startup requires the supervisor to be absent and no process to exist.
The first observed session and process start become an immutable target-specific binding.
Resume accepts only that same recorded process through health and activation.
An intent without a completed process binding retains an unknown outcome and refuses another bootstrap.
That unknown outcome also refuses automatic program recovery, even when the old flush receipt remains present.
The same supervised home must pass strict health and the memory guard for five minutes.
The same candidate session must remain active through that interval and the final check.
Recovery changes only program selection through the saved transaction.
It requires a clean candidate stop before a program downgrade.
An unclean or unbound candidate session causes refusal and retains the journal.
It does not force a kill, reset data, restore data, or change cloud configuration.

After named approval and accepted helper publication, invoke the supported launcher:

```bash
last-stack-safe-upgrade-loom --candidate <verified-H-lastdbd> --source-git-oid <full-H> \
  --native-run-v2-ci-approval <private-approval.json> --json
```

Source, syntax, and format checks do not prove an executed upgrade.
Only the completed supported operation and its exact receipts prove that result.
