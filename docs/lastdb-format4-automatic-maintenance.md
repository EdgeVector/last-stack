# LastDB format 4 maintenance and the final stopped backup

## Current profile

Use `run-v2-format4-final-stopped-maintenance-v1` for the exact `1d4b205bb` to `a1c406f5` pair.
Approval and evidence schemas use version 4. The launcher selects the existing protocol 13.

The old baseline always writes clean-stop meter metadata during shutdown.
A live snapshot therefore cannot prove the exact stopped files.
Fresh version 3 approvals now refuse this pair. Their old records and recovery path remain readable.

The version 4 flow keeps the strict stop and full file checks:

1. Prove the current automatic snapshot, source-free restore, selected request obligations, and the exact current writer.
2. Drain automatic work while it remains enabled. Then disable it through the normal product command.
3. Require the exact disabled revision, no pending request, no active work, and no retained source before Loom starts.
4. Stop the old program with its actual clean flush receipt and session ledger.
5. Use the verified candidate CLI to capture the final stopped files with one immutable manual request UUID.
6. Require full provider readback, unchanged stopped files, source release, and the original native file manifest.
7. Select the candidate and complete the existing five-minute soak with automatic backup off.
8. Restore the original 60-second log and 86400-second snapshot schedule through a separate authorized product action.
9. Require a new automatic full snapshot, a coherent journal anchor, and complete acknowledgement before the final backup verdict.

The manual stopped snapshot has no automatic journal position while automatic backup is disabled.
An enabled flag alone does not prove adoption. The new automatic full snapshot establishes that boundary.

The DEV qualification retains its original eight-point and 64 MiB allowance.
A separate stopped extension permits one manual snapshot and one automatic adoption snapshot.
Each permits 32 MiB of declared inventory. Their combined allowance is 64 MiB.
The extension requires one source-free restore, two normal boots, full file reads, deletions, and strict stops.
It also requires a real candidate source boot and an automatic adoption snapshot without new user writes.

Version 4 permits 24 hours for the original immutable Mac compatibility proof.
It still requires the exact programs, original ten clean consumers, all file reads, and an unexpired verified artifact.
The new stopped and adoption extension must complete within one hour of admission.
The current PROD snapshot and provider checks keep their existing freshness limits.
Versions 2 and 3 keep the original one-hour Mac proof limit. No proof timestamp changes.

The stopped extension version 2 preserves the original failed version 1 attempt and its diagnostic.
It reuses the original manual snapshot, automatic adoption, SDK restore, and complete preboot native hashes.
Only two new restored starts, current file reads, and strict stops use the new continuation intent.
It creates no backup, source start, upload, or restore.

A normal start can remove an old file that no current record references.
The postboot proof derives every required file from the original final expected record pointers.
It rejects unknown current pointers and checks every current file's complete bytes and hash.
The original two-file compatibility checks and the complete preboot native file proof remain unchanged.
Future qualification plans must derive this current file set before any restored start.
They must not require an old unreferenced file after normal garbage collection.

The current writer observation must link to the actual recorded rollback and new session.
Do not reuse the old PID or edit its original writer receipt.
If a step fails, preserve the real records. Do not repeat an unknown request with a new UUID.
Program recovery retains automatic backup off; restore its schedule as an explicit, verified action.

## Historical automatic profile

Protocol 14 supports one reviewed program change from `1d4b205bb` to `a1c406f5`.
It uses approval and evidence schema version 3.
The profile is `run-v2-format4-auto-maintenance-v1`.
The accepted source launcher uses its own graph and scripts with the installed Loom engine.

This profile supports the current typed format 4 home and its current encrypted values.
It does not convert data, restore into the primary, copy the primary, or admit retired formats.
The full source change map closes the profile to the reviewed program pair.
The baseline is the original head of PR606, which used a squash merge.
The profile pins both original source trees and their exact common ancestor.
The old profiles keep their separate requirements.

## Program and recovery checks

The profile requires these independent records:

- The exact accepted source passes required CI and the benchmark completion check.
- The existing Mini workflow produces the exact Mac program pair.
- The workflow source, artifact, archive, manifest, signatures, and program hashes agree.
- The accepted Linux DEV operation passes. Its result does not qualify the Mac program bytes.
- A separate Mac DEV operation uses the exact old pair and candidate pair.

The Mac operation creates fresh DEV data with the old pair.
The DEV operation uses the primary's exact file encryption and compression settings.
It does not qualify the old client's default file settings.
The candidate opens that data, changes records and files, and creates automatic backups.
The operation checks a snapshot, later mutation logs, and another snapshot after a normal restart.
It restores the selected points without the source node.
Each restored node passes two normal starts and two clean stops.
The old pair must also open and read the candidate data.
The operation checks complete file bytes and the selected provider objects.
It does not claim a full account allocation comparison.

A DEV account must permit new work before the operation starts.
An existing account hold stays in place.
The qualifier can use a separate account through a protected credential home.
It selects each restore receipt by its exact destination.

Development evidence version 3 can complete the retained DEV operation after its receipt observer stops.
The original intent, failure, backup points, and completed operations retain their original hashes.
The continuation uses a separate intent for its four remaining starts and one later snapshot restore.
It cannot create a new connection, backup, capture, or account.
All record, file, provider, and clean-stop checks remain required.

## Automatic backup stays enabled

The approval binds the account, automatic policy revision, intervals, and journal head.
The primary keeps the same identity, home, device stream, and automatic policy through the program change.
Legacy cloud sync stays off.
The profile refuses a journal gap, a failed request, a policy change, or a covered boundary that moves backwards.

Before the stop, one accepted automatic snapshot must cover the current mutation journal.
The journal head, acknowledged position, and saved backup frontiers must agree.
The source hold must be released, and the backup must be idle.
The snapshot's automatic consent revision must exist in the original saved job.

A source-free cloud restore provides the original snapshot file proofs.
The operator records the complete restored file hashes before the first normal start.
It retains the original selection, result, receipt, and observation through their actual hashes.
This proof has the origin `completed-source-free-snapshot-restore`.
It does not claim that the operator retained a source manifest before cleanup.

The approved source checkpoint must agree with the restored file proofs and current native metadata.
The provider proof must name that same accepted snapshot and complete native file list.
The final read bookends must show the same covered automatic state.

## Cutover and recovery

The operator saves the exact old programs and LaunchAgent configuration.
It uses the existing strict stop and requires an unforced stop, a clean session record, and a successful flush receipt.
After the stop, it hashes every file in the accepted native snapshot.
Both CURRENT files must still equal the approved recovery boundary.
Any later write or changed file prevents candidate selection.

The operator changes only the primary program pointer and daemon program argument.
The existing supervisor starts the selected pair.
The candidate must pass the same known-key read, native health checks, automatic policy checks, and a five-minute supervised interval.
Recovery keeps the existing exact-session and clean-stop requirements.
A failed stop never becomes a clean stop through an operator receipt.

After cutover, a separate PROD restore checks the selected snapshot and complete later log chain.
The operator freezes that accepted point before the restore.
Its report distinguishes a covered journal boundary from changes that arrive after that point.
