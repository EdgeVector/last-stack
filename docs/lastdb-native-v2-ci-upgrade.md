# Native V2 upgrade through Loom

The explicit `native-v2-ci` policy uses protocol 10 in the existing safe-upgrade graph.
Protocols 7, 8, and 9 keep their current behavior.
The local Loom journal remains outside LastDB.
This policy does not reconcile that journal into retired apps.
It does not use brain, kanban, situations, local benchmarks, or a primary copy.

## Required evidence

The private approval file uses schema `lastdb.native-v2-ci-approval.v1`.
It contains the actual human approval quote, approver `Tom`, and Unix `approved_at`.
The quote must correspond to an existing human instruction.
The file binds these fields:

- `mode`: `native-v2-ci`.
- `source_git_oid`: the full candidate commit.
- `candidate`: exact `lastdb` and `lastdbd` path, SHA256, and version objects.
- `baseline_source_git_oid`: the full actual installed source.
- `baseline_programs_sha256`: both actual installed program hashes.
- `primary_home` and `launchd_plist`: the canonical primary and its exact user LaunchAgent.
- `target_program_dir`: `<primary>/native-v2-programs/<full-candidate-source>`.
- `primary_data_copy`: false.
- `primary_restore_or_migration`: false.
- `evidence_path` and `evidence_sha256`: the private evidence input and its exact hash.
- `recovery`: the fields below.
- `keyed_read`: the private input path and its exact SHA256.

The recovery object binds `environment=prod`, `account_id`, and decimal-string `account_generation`.
It also binds `identity_public_key`, native `home_id`, and `home_digest`.
It names canonical `credentials_home` and external `state_dir` paths.
It contains distinct canonical UUIDs `live_request_id` and `final_request_id`.
The caller first completes the live V2 job through the supported standalone command.
The approval cannot replace an unfinished job with a fresh UUID.

The evidence input binds `source_git_oid`, `source_repository`, `accepted_main_commit`, and the verified `artifact_archive`.
It names the original `artifact_receipt`, `dev_proof_root`, `compatibility_record`, and `compatibility_sha256`.
All evidence inputs remain private and bounded.
The gate reads the original CI artifact and operational outputs; it creates no duplicate CI report.

The original `0a9` path requires successful `ci-required` and `benchmark-complete` checks for the exact commit.
The exact `96` maintenance path uses the separate source and accepted-main checks below.
GitHub must confirm that the accepted commit remains an ancestor of main.
The gate first accepts an identical complete candidate and accepted tree, including after a squash merge.
If concurrent main changes produce a different tree, the evidence must also bind `accepted_pull_request`.
That same-repository PR must merge the exact CI source into main at the named accepted commit.
GitHub and the local repository must agree on its tree and single squash parent.
A clean independent `git merge-tree --write-tree <parent> <candidate>` must produce that exact accepted tree.
Conflicts, missing objects, custom merge drivers, or inherited Git graph overrides refuse the operation.
The operator fetches any missing immutable Git objects without a checkout or rebuild of main.
The journal records the artifact source and tree separately from the accepted merge commit, tree, parent, and merge base.
The binary, CI, DEV proof, and protected-source comparison still use the exact reviewed artifact source.
The Mac artifact must come from the normal `native-dev-artifact.yml` workflow for that commit.
The gate verifies its GitHub digest, original archive, target, and both program byte hashes.
The actual DEV proof must use those exact programs.
It must prove one foreground standalone Start, zero Resume requests, and accepted publication.
It also requires packed files, the exact stopped boundary, source-free restore, and two restored boots.
The accepted result, frozen manifest, restore selector, native file count, and byte count must agree.
All source and restored daemons must be stopped, with zero retained source bytes.
The gate reads the original `standalone-terminal-report.json`, `expected-native-files.json`, and `source-stopped-boundary.stdout`.
It also reads `source-free-restore.stdout`, `source-free-selection.json`, and the operator's original `run-state.json`.
It does not convert these outputs into a second proof report.

## Source compatibility and program recovery

The original closed baseline is `0a9d8cf48470c21f0b7b9fef250a2d5598ca2b09`.
Its source, CI, and acceptance behavior remain unchanged.
The separate maintenance path accepts only the exact `96` baseline below.
Every other installed source requires a fresh source review and policy change.
The private compatibility record uses schema `lastdb.native-source-compatibility.v1`.
Its `baseline` and `candidate` must equal the exact approved sources.
Its `reviewed_format_neutral_changes` maps each protected changed path to exact `before` and `after` Git blobs.
A missing blob uses JSON null.
The record requires `source_reviewed`, `no_native_format_change`, and `restore_migration_disallowed`, all true.
These fields record the source review; they do not claim an executed backward reopen.

The gate reads both Git trees and compares the whole protected change set with that record.
The closed path list includes read-only export changes and separately reviewed guard and restore changes from main.
It does not classify those guard changes as read-only.
The native encoders, feature bits, and dependency versions remain unchanged.
The new inactive restore guard refuses a serving target.
This policy permits no restore or migration of the primary.
An unknown writer, codec, feature, or dependency change refuses the operation.

Program recovery retains candidate acknowledged writes in the same native home.
The source compatibility basis permits the original program to read those normal writes.
A failed or unclean candidate stop does not authorize an automatic program downgrade.
The transaction retains its exact pair and recovery state if a clean stop cannot be proved.

## Exact native5 maintenance path

This path accepts only baseline `96f32b2ade27927019179fb57dc60f9c00a0ae68`.
The evidence must set `maintenance_profile` to `native5-cloud-retirement-v1`.
It must supply `baseline_provenance` with schema `lastdb.completed-native-v2-baseline.v1`.
The fields are `journal_path`, `journal_sha256`, `approval_path`, and `approval_sha256`.
The gate requires the original completed mode10 journal and approval, with their closed reviewed hashes.
It checks the original journal location, exact candidate pair, completed phase, native identity, and selected primary configuration.
The fresh installed pair must match that prior candidate at its isolated installed directory.
The prior approval is historical proof. The new cutover still requires its own fresh exact approval.
The gate performs no primary read through these historical evidence files.

The new compatibility record must compare the full `96` tree with the exact candidate H tree.
It must use the same `profile` value and the existing format-neutral review flags.
It must contain every protected changed path and exact before/after blob pair.
The old `0a9` compatibility record cannot satisfy this check.
Only the closed retirement path list permits changes, additions, or deletions in Core.
Native codecs, native5 identity, file formats, crypto, protocol, dependencies, and CI workflows remain unchanged.
The only Cargo exception removes the exact retired `csync_e2e_write` binary stanza and its source file.
Every other Cargo byte, feature, dependency, and build setting must remain unchanged.
Two further exceptions permit only exact source byte changes from `96`.
They add the direct `BTreeSet` import in the query-slice builder and remove two unused store re-exports.
Every other byte in those files must remain unchanged.
The callerless writer cleanup adds 29 closed Git blob pairs for sensitive store, progress, and helper paths.
Each pair binds the exact `96` blob to the reviewed native5 cleanup blob.
Three executable lint scripts also require closed pairs. Their limits and remaining bans stay unchanged.
Each pair includes the exact Git modes. Native source stays `100644`; the three lint scripts stay `100755`.
The counter-writer allowlist requires one complete `100644` pair, with only the reviewed retired entries removed.
The retired fixture's source must also be absent. The exact Cargo stanza check remains required.
Four further `100644` pairs remove the unused config-store field, initializer, accessors, and local factory attachment.
They bind the exact `96` blobs to the reviewed four-file candidate tree.
The native5 namespace export, storage implementation, crypto, and restore path remain unchanged.
These paths do not receive general modification permission.
The fresh full compatibility record must also include those exact blob pairs.
An unknown protected path, a protected source mode change, or a different blob map refuses the operation.
Ordinary Node and host application source remains outside the native compatibility scope.
The exact H CI, artifact, DEV, approval, and merged PR gates still bind that application code.

The evidence must supply `required_ci_run` for a successful H `ci-required.yml` workflow dispatch.
The exact required job and its GitHub Actions check must both name H.
The Mac archive, both programs, and the fresh DEV backup/restore proof must also name H.
The accepted main merge M requires its normal `ci-required` and `benchmark-complete` checks.
The exact merged PR and independent clean merge calculation must bind H to M.
M can retain main's newer native format. The transaction installs only H, with the unchanged native5 format.
The journal records `benchmark_source=M` separately from the artifact source H.
The evidence must supply `accepted_main_benchmark_run` for M's successful main-push `bench.yml` run.
That exact run must contain the successful normal `benchmark-complete` check and real measurements.
Its measurement, resource, summary, upload, and receipt steps must all succeed.
This excludes a documentation-only PR check that skips measurements.

The evidence must also supply `candidate_benchmark_run` for a successful `bench-compare.yml` dispatch at H.
Use explicit baseline `96`, candidate H, driver H, profile `standard`, and `resource_only=false`.
This comparison supplements the normal main gate. It cannot replace `benchmark-complete`.
The original CI archives must remain in protected external files.
Their evidence fields are `candidate_benchmark_archive` and `candidate_benchmark_receipt_archive`.
The gate binds the exact run attempt, artifact names, API digests, expiration, original receipt, and ZIP bytes.
Both original manifests must identify H, baseline `96`, driver H, and two complete pairs.
The candidate must use a fresh CI build. Both ordinary and resource measurements must complete.
Archive bounds protect the evidence reader. They do not limit backup data or native files.

The optional `github_metadata_transport=public_https` uses fixed public LastDB HTTPS GET routes when the CLI credentials are unavailable.
It verifies that the fixed repository is public before other metadata reads.
It uses no credentials, proxy, netrc, redirects, archive download, or write API.
It bounds request count, time, and response size. Rate limits or missing metadata refuse the operation.
The private verified archive remains required because public artifact download can require authentication.
The artifact digest, size, source, workflow, and expiration checks remain mandatory.
An absent transport field keeps the existing GitHub CLI metadata path.
This option does not change private repository behavior.

## Stop and final recovery point

The existing strict helper temporarily holds the old executable to prevent its supervised respawn.
That path is allowed only after the exact consumer gate passes.
The gate reads at most 512 user LaunchAgent entries, without recursion.
Each plist read uses one unchanged owner-controlled file snapshot.
The parser accepts XML and binary plists directly.
For other valid macOS plist formats, it converts the same bytes through bounded `plutil` stdin and anonymous output.
It does not rewrite a LaunchAgent file.
Malformed, unsupported, oversized, or changed files refuse before stop.
Every other same-executable consumer must be unloaded.
The executable open-file check must identify only the exact primary PID.
An unknown or active other consumer refuses before SIGTERM.
The helper applies no forced kill and requires the exact old session's flush receipt and clean ledger record.
The helper then unloads the primary and restores the original shared executable inode and hash.
It does not change another service's program, plist, or job.

The live accepted V2 recovery point must be no more than 300 seconds old before stop.
`capture_started_at` precedes the first capture attempt and therefore gives a conservative age.
A fresh status observation does not refresh that age.

An explicit approval can instead bind `recovery.live_freshness` to `policy=exact_current`.
Its `current_path` must name the expanded canonical `<primary>/data/disk-pack/CURRENT` path.
An absent field keeps the 300-second rule; an unknown policy or field refuses.
The new policy keeps the original capture timestamp and checks that it is not in the future.
It reads only the 4096-byte CURRENT metadata from one owner-controlled file descriptor.
The canonical home, data, and native directories and the file must remain unchanged through that read.
The file hash must equal the accepted job's full captured CURRENT hash.
The gate makes a new observation at probe, before effects, and immediately before strict stop.
It records the last observation, original capture time, exact job, native root, and old session separately.
The stop intent binds that observation to `effect_started_at` in the durable local journal.
After stop, predecessor validation uses that saved observation at the effect time.
It does not read the CURRENT that the final flush can change.
This metadata observation proves the current durable cut only.
It does not prove empty memory or prevent a later write.
The strict session, health, flush, and final stopped-source checks remain mandatory.

After the strict stop, the final standalone job captures the stopped source with its fixed UUID.
The source command uses no daemon, writer, primary copy, or V1 bootstrap.
The launcher enables V2 only in that child CLI environment.
It does not change the primary plist's cloud flags.
The exact Begin, cut, transfer IDs, and holds survive an unknown result.
A retry resumes that exact saved job.
The final job must reach accepted publication, terminal cleanup, and zero retained source bytes.
The full captured native root must equal the supported stopped boundary before and after the final upload.
It must still equal that boundary immediately before program selection.
Frontier equality alone is insufficient.

The final upload can take more than 300 seconds while the source remains stopped.
It must start after the proved stop and cover the exact unchanged CURRENT.
This rule uses full stopped-source identity instead of a file-size cap or a weaker live freshness claim.

## Primary-only installation

The transaction saves the original program pair and exact primary plist outside the data files.
It stages both candidate programs in the new primary-only directory.
The original shared executable bytes and inodes stay unchanged after strict stop.
The stable CLI and daemon links must both use the canonical primary `current` pointer.

While the primary remains unloaded, the transaction changes only its program argument and current pointer.
Every other plist field remains the same.
File and directory barriers protect the saved pair, staged pair, plist, pointer, and transaction phases.
An interrupted selection accepts only the exact original or candidate components.
It never selects an unrelated program.

The same supervisor starts the selected pair.
The gate checks exact program hashes, versions, socket session, environment, native health, and memory size.
It requires a five-minute supervised health interval, with no local latency measurements.
Legacy cloud sync stays off; V2 source work is a separate protocol.
The operation does not create Ready or permanent Hold authority.

The unchanged old session uses the accepted baseline maintenance-history policy.
A recovered historical maintenance count needs a successful publication and no current error.
That exact old session's failure counters must not increase before stop or during old-retained recovery.
Reclaim failures remain blocked.
The candidate, restarted original program, and supervised interval require zero failure counts.

## Ordinary data read

The approval binds `keyed_read.input_path` and `keyed_read.input_sha256`.
The input must be a canonical private file, at most 16384 bytes.
Its schema is `lastdb.native-keyed-read.v1`.
It contains `application`, `schema_name`, `fields`, and `keys`.
Each key contains an explicit string `hash` and string `range`; a hash-only key uses an empty range.
The input permits 1 to 16 distinct keys and 1 to 16 distinct fields.
The application and schema names must exclude brain, kanban, and situations namespaces.
The operator selects existing stable records from an allowed application before cutover.
The policy creates no schema, app, or record.

Immediately before stop, one batch query must return every approved key and field without unresolved or deleted records.
The private journal retains only the input hash, returned record count, and canonical value digest.
The response values remain in memory; the policy writes no response dump.
After the candidate starts, the same query must return the same digest and count.
The original program must pass that comparison after program recovery, including when the original process remains active.
Health does not replace this data read.

Run the accepted launcher with `--candidate <lastdbd> --native-v2-ci-approval <private-file> --json`.
An absolute clean accepted worktree path uses its matching graph and scripts with the installed Loom engine.
This supported source path requires no setup or routine change.
The mode refuses stand-ins, other native modes, stale-backup waivers, zero soak, and alternate graph bundles.
The source PR and CI establish code validation only.
Deployment, installation, and the primary restart remain separate authorized operations.
