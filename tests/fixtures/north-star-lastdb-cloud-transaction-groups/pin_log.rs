//! Target-scoped durable mutation log for cloud-sync pin mode + continuous
//! mutation-log-first segment upload (Phase A single-writer scaffold; Phase B
//! multi-writer concurrent streams).
//!
//! Pin mode freezes a sealed base set at F0 and sends post-F0 mutations to an
//! append-only log for the active sync target. Continuous MutationLog capture
//! reuses the same durable store without freeze. This module owns the local
//! durable log, continuous segment seal/upload under `log/{writer_id}/{seq}`,
//! published frontier F (per-writer vector + scalar max), and replay/status
//! helpers. Snapshot publish orchestration for rare compact stays with the
//! backup controller.
//!
//! Multi-writer (Phase B): each device/process has a stable `writer_id`
//! (`SyncEngine::device_id`). Writers append anytime without a snapshot lock;
//! sealed segments land under distinct `log/{writer_id}/` prefixes on the
//! shared cloud plane. Local R/W never awaits upload.

use super::super::org_sync::SyncTarget;
use super::restore_progress::{self as progress, RestorePhase, RestoreProgress, TransferOperation};
use super::*;
use crate::sync::snapshot_log::{Frontier, MutationLogSegmentId};
use serde::{Deserialize, Serialize};
use serde_json::value::RawValue;
use sha2::{Digest, Sha256};
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::sync::Arc;

pub const PIN_LOG_NAMESPACE: &str = "sync_pin_log";
const PIN_LOG_MODEL_VERSION: u32 = 1;
const PIN_LOG_ENTRY_PREFIX: &str = "target:";
#[cfg(test)]
const PIN_LOG_MATERIALIZED_FRONTIER_PREFIX: &str = "materialized_frontier:";
/// Durable per-writer published high-water mark, keyed by target id.
///
/// Truncation is gated on "cloud confirmed this frontier", and that judgement
/// used to live only in [`PinLogRuntime::published_f_by_writer`] and the
/// process-local [`MutationLogLocalCloud`] — both constructed empty. Every
/// daemon restart therefore forgot every confirmation, re-classified already
/// uploaded records as pending, and left them on disk forever. That is how
/// `sync_pin_log` reached 21 GiB (51% of the store) on Tom's primary *after*
/// truncate-after-confirm had already shipped.
const PIN_LOG_PUBLISHED_F_PREFIX: &str = "published_f:";
const BACKUP_RESTORE_F_KEY: &[u8] = b"backup_restore_f:personal";

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct BackupRestoreFrontier {
    version: u32,
    by_writer: BTreeMap<String, u64>,
}

impl BackupRestoreFrontier {
    fn validate(&self) -> SyncResult<()> {
        if self.version != 1 || self.by_writer.keys().any(String::is_empty) {
            return Err(SyncError::Storage("invalid backup writer frontier".into()));
        }
        Ok(())
    }
}
/// Highest locally appended frontier across every writer and target.
///
/// Pin-row keys omit the writer id, so one home-wide allocation floor prevents
/// any writer from reusing another writer's pending frontier after a restart.
/// The first upgraded append seeds this point row from all legacy pin rows.
pub(crate) const PIN_LOG_APPENDED_F_KEY: &[u8] = b"appended_f:global";

/// SHA-256 length prefixed onto a sealed mutation-log segment's plaintext,
/// matching the `HASH_SIZE` contract in `sync::log`.
const MUTATION_LOG_SEGMENT_HASH_SIZE: usize = 32;
/// Keep request count sublinear in mutation count without producing giant
/// retry units. The byte bound normally fills first for real records.
const MUTATION_LOG_SEGMENT_MAX_RECORDS: usize = 1_000;
/// Target object size for the continuous plane. The cycle-wide byte budget can
/// lower this, but never raises it.
const MUTATION_LOG_SEGMENT_TARGET_BYTES: usize = 4 * 1024 * 1024;
const TRANSACTION_GROUP_WIRE_VERSION: u32 = 2;
const TRANSACTION_GROUP_MANIFEST_SCHEMA: &str = "__lastdb_transaction_group_v2__";
const TRANSACTION_GROUP_RECORD_DIGEST_LEGACY_JSON: u32 = 0;
const TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1: u32 = 1;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TransactionGroupIndexedMutation {
    original_index: u32,
    mutation: crate::sync::log::MutationEnvelope,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct TransactionGroupShardRef {
    schema_name: String,
    shard_index: u32,
    object_key: String,
    ciphertext_sha256: String,
    operation_indexes: Vec<u32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(tag = "wire_type", rename_all = "snake_case")]
enum TransactionGroupWireV2 {
    Shard {
        format_version: u32,
        group_id: String,
        writer_id: String,
        frontier_after: u64,
        schema_name: String,
        shard_index: u32,
        shard_count: u32,
        operations: Vec<TransactionGroupIndexedMutation>,
    },
    Manifest {
        format_version: u32,
        group_id: String,
        writer_id: String,
        frontier_after: u64,
        /// Zero or absent identifies the historical raw-JSON digest.
        /// Version one sorts every JSON object key before it hashes the record.
        #[serde(default)]
        record_digest_version: u32,
        record_sha256: String,
        operation_count: u32,
        shard_count: u32,
        record_template: Box<PinLogRecord>,
        shards: Vec<TransactionGroupShardRef>,
    },
}

/// Raw fragments required to verify historical v2 record digests.
///
/// The old digest covered `HashMap` iteration order. Typed deserialization
/// creates new maps with a new order. Each shard still holds the exact JSON
/// emitted from the source record, so retain those bytes for the legacy check.
#[derive(Debug, Deserialize)]
struct TransactionGroupRawIndexedMutation {
    original_index: u32,
    mutation: Box<RawValue>,
}

#[derive(Debug, Deserialize)]
struct TransactionGroupWireV2Raw {
    wire_type: String,
    #[serde(default)]
    operations: Option<Vec<TransactionGroupRawIndexedMutation>>,
    #[serde(default)]
    record_template: Option<Box<RawValue>>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum MutationLogRecordStream {
    Legacy,
    SingleSchema(String),
    MultiSchema,
}

/// One sealed base member frozen at F0 for a pin target.
///
/// Identity is content-addressed (`sha256`) plus a stable path string used by
/// no-rewrite checks. Paths are relative when possible so status is portable.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SealedBaseMember {
    pub path: String,
    pub sha256: String,
    pub len: u64,
    pub mtime_secs: i64,
}

/// Publish descriptor for catch-up of frozen base S plus log for one target.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PinModePublishDescriptor {
    pub target_id: String,
    pub target_prefix: String,
    pub base_frontier: u64,
    pub log_from: u64,
    pub last_durable_frontier: u64,
    pub sealed_base_shas: Vec<String>,
    pub publish_counter: u64,
    /// Always true for pin-mode publish: base may be fuzzy relative to tips.
    pub base_may_be_fuzzy: bool,
}

#[derive(Debug, Clone)]
pub(crate) struct PinLogRuntime {
    pub(crate) target_id: String,
    pub(crate) target_label: String,
    pub(crate) target_prefix: String,
    /// Durable log append is on for this target (continuous MutationLog and/or pin freeze).
    pub(crate) active: bool,
    /// True only for pin-mode freeze (sealed-base no-rewrite + catch-up). Continuous
    /// mutation-log capture keeps this false so everyday multi-device progress is
    /// never frozen behind a full-home base cut.
    pub(crate) pin_freeze: bool,
    pub(crate) base_frontier: u64,
    pub(crate) last_durable_frontier: u64,
    pub(crate) entry_count: u64,
    pub(crate) byte_count: u64,
    pub(crate) last_durable_at_ms: Option<u64>,
    pub(crate) sealed_base: Vec<SealedBaseMember>,
    pub(crate) pin_entered_at_ms: Option<u64>,
    pub(crate) s_rewrite_attempts: u64,
    pub(crate) materialize_pending: bool,
    #[cfg(test)]
    pub(crate) last_publish: Option<PinModePublishDescriptor>,
    /// Highest frontier successfully sealed+uploaded across writers (status max).
    /// For multi-writer filtering, use `published_f_by_writer` (0 when absent).
    pub(crate) published_frontier: u64,
    /// Per-writer published through-seq (Phase B vector F). Empty ⇒ treat all
    /// writers as unpublished (0). Scalar `published_frontier` is always the
    /// max of these values after an upload cycle.
    pub(crate) published_f_by_writer: HashMap<String, u64>,
    /// Cloud-confirmed record timestamp for each writer's published frontier.
    /// Kept separate from local durable append time so RPO never advances on a
    /// local-only fact.
    pub(crate) published_at_ms_by_writer: HashMap<String, u64>,
    /// Segments sealed+uploaded this process for continuous MutationLog plane.
    pub(crate) segments_uploaded: u64,
    /// Pin-log MutationIntent rows skipped this process because they cannot
    /// be sealed (missing atom). One bad row must not fail-close later ones.
    pub(crate) records_quarantined: u64,
    /// Last unsealable-record reason (atom id / field), for `lastdb status`.
    pub(crate) last_quarantine_reason: Option<String>,
}

impl PinLogRuntime {
    /// Shared constructor for inactive/continuous runtime rows (enter / ensure / persist).
    fn new(
        target_id: String,
        target_label: String,
        target_prefix: String,
        base_frontier: u64,
        last_durable_frontier: u64,
        active: bool,
    ) -> Self {
        Self {
            target_id,
            target_label,
            target_prefix,
            active,
            pin_freeze: false,
            base_frontier,
            last_durable_frontier,
            entry_count: 0,
            byte_count: 0,
            last_durable_at_ms: None,
            sealed_base: Vec::new(),
            pin_entered_at_ms: None,
            s_rewrite_attempts: 0,
            materialize_pending: false,
            #[cfg(test)]
            last_publish: None,
            published_frontier: 0,
            published_f_by_writer: HashMap::new(),
            published_at_ms_by_writer: HashMap::new(),
            segments_uploaded: 0,
            records_quarantined: 0,
            last_quarantine_reason: None,
        }
    }

    /// Advance per-writer F and refresh scalar max after a cloud-confirmed put.
    fn advance_published_f(&mut self, writer_id: &str, through: u64, published_at_ms: u64) {
        let entry = self
            .published_f_by_writer
            .entry(writer_id.to_string())
            .or_insert(0);
        if through >= *entry {
            *entry = through;
            self.published_at_ms_by_writer
                .insert(writer_id.to_string(), published_at_ms);
        }
        self.published_frontier = self
            .published_f_by_writer
            .values()
            .copied()
            .max()
            .unwrap_or(0)
            .max(self.published_frontier)
            .max(through);
    }

    /// True when `path_or_sha` identifies this sealed member.
    ///
    /// Empty `path_or_sha` never matches: `str::ends_with("")` is always true in
    /// Rust, so an empty probe would otherwise hit every member.
    #[cfg(test)]
    fn matches_sealed_path_or_sha(path_or_sha: &str, member: &SealedBaseMember) -> bool {
        if path_or_sha.is_empty() {
            return false;
        }
        member.sha256 == path_or_sha
            || member.path == path_or_sha
            || member.path.ends_with(path_or_sha)
    }

    #[cfg(test)]
    fn sealed_base_contains(&self, path_or_sha: &str) -> bool {
        self.sealed_base
            .iter()
            .any(|m| Self::matches_sealed_path_or_sha(path_or_sha, m))
    }

    /// Match an observed path against a sealed member for integrity checks.
    #[cfg(test)]
    fn observed_path_matches_member(observed_path: &str, member: &SealedBaseMember) -> bool {
        if observed_path.is_empty() {
            return member.path.is_empty();
        }
        observed_path == member.path
            || (!member.path.is_empty() && observed_path.ends_with(&member.path))
    }

    fn status(&self) -> PinLogTargetStatus {
        let recovery_point_age_secs = self
            .published_at_ms_by_writer
            .values()
            .copied()
            .min()
            .map(|published_at| now_millis().saturating_sub(published_at) / 1000);
        let pin_age_secs = self
            .pin_entered_at_ms
            .map(|entered| now_millis().saturating_sub(entered) / 1000);
        let upload_backlog = self
            .last_durable_frontier
            .saturating_sub(self.published_frontier);
        PinLogTargetStatus {
            target_id: self.target_id.clone(),
            target_label: self.target_label.clone(),
            target_prefix: self.target_prefix.clone(),
            // Surface pin freeze as `active` for operators (pin-mode status).
            // Continuous capture without freeze still shows in entry counters.
            active: self.pin_freeze,
            base_frontier: self.base_frontier,
            last_durable_frontier: self.last_durable_frontier,
            entry_count: self.entry_count,
            byte_count: self.byte_count,
            last_durable_at_ms: self.last_durable_at_ms,
            sealed_base_count: self.sealed_base.len() as u64,
            pin_age_secs,
            pin_age_known: self.pin_entered_at_ms.is_some(),
            s_rewrite_attempts: self.s_rewrite_attempts,
            materialize_pending: self.materialize_pending,
            // Defensive inconsistency signal: pin freeze without an entry
            // timestamp (should not happen on the enter path; exit clears both).
            degraded: self.pin_freeze && self.pin_entered_at_ms.is_none(),
            published_frontier: self.published_frontier,
            published_through: self.published_frontier,
            recovery_point_age_secs,
            published_f_by_writer: self
                .published_f_by_writer
                .iter()
                .map(|(k, v)| (k.clone(), *v))
                .collect(),
            upload_backlog,
            segments_uploaded: self.segments_uploaded,
            records_quarantined: self.records_quarantined,
            last_quarantine_reason: self.last_quarantine_reason.clone(),
        }
    }
}

/// One durable pin-mode log record.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PinLogRecord {
    pub model_version: u32,
    /// Stable id derived from the sync target prefix (`personal` for prefix "").
    pub target_id: String,
    pub target_label: String,
    pub target_prefix: String,
    /// Writer/device that minted the underlying [`LogEntry`].
    pub writer_id: String,
    /// F after applying this record in the target stream.
    pub frontier_after: u64,
    pub timestamp_ms: u64,
    pub entry: LogEntry,
}

/// Exact cloud-publication coordinate for one required mutation-log target.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MutationLogTargetPosition {
    pub(crate) target_id: String,
    pub(crate) target_label: String,
    pub(crate) writer_id: String,
    pub(crate) frontier: u64,
}

/// Durable pin-log append receipt for one logical operation.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct MutationLogAppendReceipt {
    pub(crate) writer_id: String,
    pub(crate) frontier: u64,
    /// At least one local cloud-staging lane retained this operation durably.
    ///
    /// Legacy outbox capture has no exact mutation-log target coordinates, so
    /// `targets.is_empty()` alone cannot distinguish success from no capture.
    pub(crate) durable_capture_written: bool,
    pub(crate) targets: Vec<MutationLogTargetPosition>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum MutationPublicationWait {
    Published,
    Pending,
}

/// Count and serialized bytes of durable pin-log records, grouped by `LogOp` kind.
///
/// Pre-#1556 `Put` / `LogicalCommit` rows stay on disk until confirm + truncate
/// (same path as `MutationIntent`). This inventory is how an operator sees the
/// leftover mix without rewriting the primary.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[cfg(test)]
pub struct PinLogKindInventory {
    pub records: u64,
    pub bytes: u64,
    pub by_kind: BTreeMap<String, PinLogKindCounts>,
}

#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[cfg(test)]
pub struct PinLogKindCounts {
    pub records: u64,
    pub bytes: u64,
}

#[cfg(test)]
impl PinLogKindInventory {
    /// Fat pre-intent kinds (`Put` / `Delete` / `Batch*` / `LogicalCommit`).
    #[must_use]
    pub fn pre_intent_records(&self) -> u64 {
        [
            "put",
            "delete",
            "batch_put",
            "batch_delete",
            "logical_commit",
        ]
        .iter()
        .map(|kind| self.by_kind.get(*kind).map_or(0, |c| c.records))
        .sum()
    }

    #[must_use]
    pub fn intent_records(&self) -> u64 {
        self.by_kind.get("mutation_intent").map_or(0, |c| c.records)
    }
}

/// Operator-visible per-target pin log counters.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PinLogTargetStatus {
    pub target_id: String,
    pub target_label: String,
    pub target_prefix: String,
    pub active: bool,
    pub base_frontier: u64,
    pub last_durable_frontier: u64,
    pub entry_count: u64,
    pub byte_count: u64,
    pub last_durable_at_ms: Option<u64>,
    /// How many sealed base members were frozen for this target at F0.
    pub sealed_base_count: u64,
    /// Seconds since pin entry when known.
    pub pin_age_secs: Option<u64>,
    /// False when pin age cannot be reported honestly.
    pub pin_age_known: bool,
    /// Instrumentation: attempts to rewrite a member of S while pinned.
    pub s_rewrite_attempts: u64,
    /// True after publish until background materialize completes.
    pub materialize_pending: bool,
    /// Degraded when pin is active but age/status is unknown.
    pub degraded: bool,
    /// Published frontier F for continuous mutation-log upload (0 if none).
    /// Scalar max across writers; see [`Self::published_f_by_writer`].
    #[serde(default)]
    pub published_frontier: u64,
    /// Cloud-confirmed published frontier (operator-facing name for F).
    #[serde(default)]
    pub published_through: u64,
    /// Age in seconds of the oldest cloud-confirmed writer recovery point.
    /// `None` until this process observes a cloud-confirmed segment.
    #[serde(default)]
    pub recovery_point_age_secs: Option<u64>,
    /// Per-writer published through_seq (vector F / HWM map).
    /// Empty before any upload; single-writer is a one-entry map.
    #[serde(default)]
    pub published_f_by_writer: BTreeMap<String, u64>,
    /// Durable records not yet sealed/uploaded (`last_durable - published`).
    #[serde(default)]
    pub upload_backlog: u64,
    /// Segments sealed+uploaded this process under the continuous log plane.
    #[serde(default)]
    pub segments_uploaded: u64,
    /// MutationIntent rows skipped because they cannot be sealed.
    #[serde(default)]
    pub records_quarantined: u64,
    /// Last unsealable-record reason (includes the missing atom id).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_quarantine_reason: Option<String>,
}

/// One sealed continuous mutation-log segment ready for (or already on) cloud.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct MutationLogSegment {
    pub segment: MutationLogSegmentId,
    /// JSON-encoded [`PinLogRecord`]s covering (prev_F, through_id].
    pub payload: Vec<u8>,
}

/// Outcome of one continuous mutation-log segment seal/upload cycle.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct MutationLogUploadReport {
    pub target_id: String,
    pub writer_id: String,
    pub records_considered: usize,
    pub segments_uploaded: usize,
    pub bytes_uploaded: u64,
    pub published_frontier_before: u64,
    pub published_frontier_after: u64,
    /// Remaining durable work still above published F after this cycle, as a
    /// **frontier delta in nanoseconds** (`last_durable_frontier -
    /// published_frontier`) — not a record count. Same quantity and units as
    /// `MutationLogPlaneStatus::log_lag`.
    pub upload_backlog_after: u64,
    /// Object keys written this cycle (`log/{writer_id}/{seq}.enc`).
    pub object_keys: Vec<String>,
    /// Durable pin-log records deleted this cycle because cloud confirmed them.
    #[serde(default)]
    pub records_truncated: usize,
    /// Durable rows the cycle read off the pin-log plane to fill this batch.
    ///
    /// The cycle reads a bounded window, not the whole plane, so this is the
    /// cycle's actual read cost — not the plane's size.
    #[serde(default)]
    pub rows_scanned: usize,
    /// `true` when the bounded scan stopped before reaching the end of the
    /// plane, so [`Self::records_considered`] is a **floor**, not a total.
    ///
    /// A count that silently changed meaning from "all pending records" to
    /// "as many as this cycle happened to look at" would read as a shrinking
    /// backlog. Anything consuming `records_considered` must check this first.
    #[serde(default)]
    pub records_considered_is_lower_bound: bool,
    /// `true` when the scan stopped on the per-cycle row budget rather than on
    /// the batch target or the end of the plane. Distinct from the ordinary
    /// early stop: it means rows were skipped that this cycle never judged.
    #[serde(default)]
    pub scan_row_budget_exhausted: bool,
    /// MutationIntent rows skipped this cycle because atoms could not be loaded.
    #[serde(default)]
    pub records_quarantined: usize,
    /// Last skip reason this cycle (atom id / field).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub last_quarantine_reason: Option<String>,
}

/// Outcome of applying sealed mutation-log segments after restoring a snapshot.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct MutationLogReplayReport {
    pub segments_considered: usize,
    pub segments_applied: usize,
    pub records_applied: usize,
    pub records_skipped_at_or_below_frontier: usize,
    /// Per-writer frontier after replay. This is the cursor a restored home
    /// persists/advertises before fetching the next cloud page.
    pub frontier_after: BTreeMap<String, u64>,
}

/// Where a continuous mutation-log cycle publishes its sealed segments.
///
/// Chosen by the CALL SITE, deliberately not by config: a production node must
/// not be able to fall into the local-only path by misconfiguration. Before
/// this existed the cycle always wrote to [`MutationLogLocalCloud`] — an
/// in-process `HashMap` — so `segments_uploaded` and the published frontier
/// advanced while nothing left the machine (primary, 2026-08-08: 236
/// "uploads", 0 `log/` objects in R2, lag growing ~1 s/s forever).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MutationLogPublish {
    /// Production: presign -> PUT -> confirm under `{scope}/log/{seq}.enc`.
    /// The frontier advances only for segments cloud confirmed.
    Cloud,
    /// TEST DOUBLE ONLY: record segments in the in-process plane so unit tests
    /// and CoW harnesses can assert object geometry without a network. Provides
    /// **no** off-box durability and must never be used by a production cycle.
    ///
    /// Only ever constructed under `cfg(test)` — that is the point, and it is
    /// why the non-test build sees it as dead.
    #[cfg_attr(not(test), allow(dead_code))]
    LocalPlaneForTests,
}

/// In-process continuous log plane: sealed segments under `log/{writer_id}/{seq}`
/// plus published scalar F. Production maps this onto the account prefix; unit
/// tests and CoW harnesses use the local plane as ground truth for geometry.
#[derive(Debug, Default)]
pub struct MutationLogLocalCloud {
    /// object_key → sealed segment
    segments: std::collections::HashMap<String, MutationLogSegment>,
    /// writer_id → published through_seq (scalar F per writer; Phase A often one)
    published_f: Arc<MutationLogFrontierSnapshot>,
    /// Monotonic CAS counter for latest pointer (optional rare compact later).
    latest_counter: u64,
}

/// Read-only status projection with no dependency on the upload-plane mutex.
/// The production writer advances this only after cloud confirmation and the
/// durable published-F flush. Its lock never covers storage or network work.
#[derive(Debug, Default)]
pub(crate) struct MutationLogFrontierSnapshot {
    frontiers: std::sync::RwLock<BTreeMap<String, u64>>,
}

impl MutationLogFrontierSnapshot {
    pub(crate) fn vector_frontier(&self) -> BTreeMap<String, u64> {
        self.frontiers
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }
}

impl Clone for MutationLogLocalCloud {
    fn clone(&self) -> Self {
        // Preserve the old deep-copy geometry semantics. Only the explicit
        // status handle shares this plane's frontier; cloned planes do not.
        Self {
            segments: self.segments.clone(),
            published_f: Arc::new(MutationLogFrontierSnapshot {
                frontiers: std::sync::RwLock::new(self.vector_frontier()),
            }),
            latest_counter: self.latest_counter,
        }
    }
}

impl MutationLogLocalCloud {
    pub fn new() -> Self {
        Self::default()
    }

    pub(crate) fn frontier_snapshot(&self) -> Arc<MutationLogFrontierSnapshot> {
        Arc::clone(&self.published_f)
    }

    pub fn put_segment(&mut self, segment: &MutationLogSegment) -> Result<(), String> {
        let key = segment.segment.object_key.clone();
        if key.is_empty() {
            return Err("mutation log segment object_key is empty".to_string());
        }
        if !key.starts_with("log/") {
            return Err(format!(
                "mutation log segment key must be under log/: got {key}"
            ));
        }
        self.segments.insert(key, segment.clone());
        Ok(())
    }

    /// Advance published F for a writer after successful segment put(s).
    pub fn advance_published_f(&mut self, writer_id: &str, through: u64) {
        let mut frontiers = self
            .published_f
            .frontiers
            .write()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let entry = frontiers.entry(writer_id.to_string()).or_insert(0);
        *entry = (*entry).max(through);
        self.latest_counter = self.latest_counter.saturating_add(1);
    }

    pub fn published_f(&self, writer_id: &str) -> u64 {
        self.published_f
            .frontiers
            .read()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(writer_id)
            .copied()
            .unwrap_or(0)
    }

    pub fn segment_count(&self) -> usize {
        self.segments.len()
    }

    pub fn keys_under_writer(&self, writer_id: &str) -> Vec<String> {
        let prefix = format!("log/{writer_id}/");
        let mut keys: Vec<String> = self
            .segments
            .keys()
            .filter(|k| k.starts_with(&prefix))
            .cloned()
            .collect();
        keys.sort();
        keys
    }

    /// Distinct writer_ids that have at least one sealed segment on the plane.
    pub fn writer_ids(&self) -> Vec<String> {
        self.vector_frontier().into_keys().collect()
    }

    /// Vector frontier F as `{ writer_id → through_seq }` (design Phase B).
    pub fn vector_frontier(&self) -> BTreeMap<String, u64> {
        self.published_f.vector_frontier()
    }

    pub fn latest_counter(&self) -> u64 {
        self.latest_counter
    }

    /// Return the encrypted segments not wholly incorporated by `frontier`.
    ///
    /// A returned segment may straddle the frontier. Replay must still filter
    /// individual records; dropping the whole object would lose its newer tail.
    pub fn segments_above(&self, frontier: &Frontier) -> Vec<MutationLogSegment> {
        let mut segments = self
            .segments
            .values()
            .filter(|segment| {
                !frontier.covers_log(
                    segment.segment.writer_id.as_deref(),
                    segment.segment.through_id,
                )
            })
            .cloned()
            .collect::<Vec<_>>();
        segments.sort_by(|a, b| {
            a.segment
                .writer_id
                .cmp(&b.segment.writer_id)
                .then(a.segment.through_id.cmp(&b.segment.through_id))
        });
        segments
    }
}

/// Seal one durable pin-log record into a segment object under
/// `log/{writer_id}/{seq}.enc` (design-lastdb-cloud-sync-mutation-log-first).
///
/// Serialize, hash, encrypt — byte-for-byte the shape [`LogEntry::seal`]
/// produces, because these objects land in the SAME `log/` prefix that replay
/// and the decryptability prover read as sealed envelopes.
///
/// This function used to be `serde_json::to_vec(record)` and nothing else,
/// despite being called "seal" and writing to a `.enc` key. It took no crypto
/// provider, so there was no argument at the call site to notice was missing.
/// On 2026-08-09 that put 3,171 objects / 1.20 GB of plaintext user records
/// into production R2 — `atom:`/`aloc:` keys with values readable as
/// `{"cont…` — and simultaneously locked the engine out of its own prefix,
/// because the prover read the leading `{` (0x7B = 123) as an envelope version
/// byte and refused every subsequent cycle with "unsupported log envelope
/// version: 123". Both symptoms are this one missing encrypt.
///
/// See `papercut-lastdb-cloud-log-segments-uploaded-unencrypted-plaintext-to-prod-r2`.
pub async fn seal_mutation_log_segment(
    record: &PinLogRecord,
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<MutationLogSegment, String> {
    seal_mutation_log_segment_batch(std::slice::from_ref(record), crypto).await
}

fn mutation_log_record_schemas(record: &PinLogRecord) -> Result<Option<(Vec<&str>, u64)>, String> {
    let LogOp::MutationIntent { mutations } = &record.entry.op else {
        return Ok(None);
    };
    if mutations.is_empty() {
        return Err("mutation-log intent has no mutations".to_string());
    }
    let mut schemas = BTreeSet::new();
    for mutation in mutations {
        let schema = mutation.schema_name.trim();
        if schema.is_empty() {
            return Err("mutation-log record cannot omit schema names".to_string());
        }
        schemas.insert(schema);
    }
    let utc_nanos = mutations
        .iter()
        .map(|mutation| mutation.written_at)
        .max()
        .filter(|value| *value > 0)
        .ok_or_else(|| "mutation-log record has no positive T0".to_string())?;
    Ok(Some((schemas.into_iter().collect(), utc_nanos)))
}

fn mutation_log_record_stream(record: &PinLogRecord) -> Result<MutationLogRecordStream, String> {
    match mutation_log_record_schemas(record)? {
        None => Ok(MutationLogRecordStream::Legacy),
        Some((schemas, _)) if schemas.len() == 1 => Ok(MutationLogRecordStream::SingleSchema(
            schemas[0].to_string(),
        )),
        Some(_) => Ok(MutationLogRecordStream::MultiSchema),
    }
}

fn mutation_log_record_identity(record: &PinLogRecord) -> Result<Option<(&str, u64)>, String> {
    let Some((schemas, utc_nanos)) = mutation_log_record_schemas(record)? else {
        return Ok(None);
    };
    if schemas.len() != 1 {
        return Err("mutation-log record has more than one schema identity".to_string());
    }
    Ok(Some((schemas[0], utc_nanos)))
}

fn mutation_log_batch_identity(records: &[PinLogRecord]) -> Result<Option<(&str, u64)>, String> {
    let mut identity: Option<(&str, u64)> = None;
    let mut saw_legacy = false;
    for record in records {
        let record_identity = mutation_log_record_identity(record)?;
        if let Some((schema, utc_nanos)) = record_identity {
            if saw_legacy {
                return Err("mutation log segment cannot mix typed and legacy records".to_string());
            }
            match identity {
                Some((current_schema, _)) if current_schema != schema => {
                    return Err("mutation log segment cannot mix schema streams".to_string());
                }
                Some((_, current_t0)) => identity = Some((schema, current_t0.max(utc_nanos))),
                None => identity = Some((schema, utc_nanos)),
            }
        } else {
            if identity.is_some() {
                return Err("mutation log segment cannot mix typed and legacy records".to_string());
            }
            saw_legacy = true;
        }
    }
    Ok(identity)
}

fn sha256_hex(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn sort_json_object_keys(value: &mut serde_json::Value) {
    match value {
        serde_json::Value::Object(object) => {
            let mut entries = std::mem::take(object).into_iter().collect::<Vec<_>>();
            entries.sort_unstable_by(|left, right| left.0.cmp(&right.0));
            for (_, child) in &mut entries {
                sort_json_object_keys(child);
            }
            object.extend(entries);
        }
        serde_json::Value::Array(values) => {
            for child in values {
                sort_json_object_keys(child);
            }
        }
        _ => {}
    }
}

fn canonical_transaction_group_record_json(record: &PinLogRecord) -> Result<Vec<u8>, String> {
    let mut value = serde_json::to_value(record)
        .map_err(|error| format!("encode canonical transaction group record: {error}"))?;
    sort_json_object_keys(&mut value);
    serde_json::to_vec(&value)
        .map_err(|error| format!("serialize canonical transaction group record: {error}"))
}

fn transaction_group_record_sha256(record: &PinLogRecord) -> Result<String, String> {
    canonical_transaction_group_record_json(record).map(|json| sha256_hex(&json))
}

fn transaction_group_id(
    record: &PinLogRecord,
    record_digest_version: u32,
    record_sha256: &str,
) -> String {
    if record_digest_version == TRANSACTION_GROUP_RECORD_DIGEST_LEGACY_JSON {
        let mut group_seed = Vec::new();
        group_seed.extend_from_slice(b"lastdb-transaction-group-v2\0");
        group_seed.extend_from_slice(record.target_id.as_bytes());
        group_seed.push(0);
        group_seed.extend_from_slice(record.writer_id.as_bytes());
        group_seed.extend_from_slice(&record.frontier_after.to_be_bytes());
        group_seed.extend_from_slice(record_sha256.as_bytes());
        return sha256_hex(&group_seed);
    }

    let group_seed = crate::canonical::CanonicalWriter::new()
        .field(b"lastdb-transaction-group-v2-versioned-record-digest")
        .u64(u64::from(record_digest_version))
        .field(record.target_id.as_bytes())
        .field(record.writer_id.as_bytes())
        .u64(record.frontier_after)
        .field(record_sha256.as_bytes())
        .finish();
    sha256_hex(&group_seed)
}

fn legacy_transaction_group_record_json(
    record_template: &RawValue,
    mutations: &[Box<RawValue>],
) -> Result<Vec<u8>, String> {
    const EMPTY_MUTATIONS: &[u8] = br#""MutationIntent":{"mutations":[]}"#;

    let template = record_template.get().as_bytes();
    let matches = template
        .windows(EMPTY_MUTATIONS.len())
        .enumerate()
        .filter_map(|(offset, value)| (value == EMPTY_MUTATIONS).then_some(offset))
        .collect::<Vec<_>>();
    let [match_offset] = matches.as_slice() else {
        return Err(
            "legacy transaction group template does not contain one empty MutationIntent"
                .to_string(),
        );
    };
    let array_offset = match_offset + EMPTY_MUTATIONS.len() - 3;
    let mutation_bytes = mutations
        .iter()
        .map(|mutation| mutation.get().len())
        .sum::<usize>();
    let mut record_json =
        Vec::with_capacity(template.len() + mutation_bytes + mutations.len().saturating_sub(1));
    record_json.extend_from_slice(&template[..array_offset]);
    record_json.push(b'[');
    for (index, mutation) in mutations.iter().enumerate() {
        if index > 0 {
            record_json.push(b',');
        }
        record_json.extend_from_slice(mutation.get().as_bytes());
    }
    record_json.push(b']');
    record_json.extend_from_slice(&template[array_offset + 2..]);
    Ok(record_json)
}

async fn seal_mutation_log_json<T: Serialize + ?Sized>(
    value: &T,
    crypto: &Arc<dyn CryptoProvider>,
    label: &str,
) -> Result<Vec<u8>, String> {
    let json = serde_json::to_vec(value).map_err(|e| format!("encode {label}: {e}"))?;
    let hash = Sha256::digest(&json);
    let mut plaintext = Vec::with_capacity(MUTATION_LOG_SEGMENT_HASH_SIZE + json.len());
    plaintext.extend_from_slice(hash.as_slice());
    plaintext.extend_from_slice(&json);
    crypto
        .encrypt(&plaintext)
        .await
        .map_err(|e| format!("seal {label}: {e}"))
}

async fn open_mutation_log_json(
    sealed: &[u8],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<u8>, String> {
    let plaintext = crypto
        .decrypt(sealed)
        .await
        .map_err(|e| format!("unseal mutation log segment: {e}"))?;
    if plaintext.len() < MUTATION_LOG_SEGMENT_HASH_SIZE {
        return Err(format!(
            "mutation log segment too short to carry its hash: {} bytes",
            plaintext.len()
        ));
    }
    let (hash, json) = plaintext.split_at(MUTATION_LOG_SEGMENT_HASH_SIZE);
    let actual = Sha256::digest(json);
    if actual.as_slice() != hash {
        return Err("mutation log segment hash mismatch after decrypt".to_string());
    }
    Ok(json.to_vec())
}

/// Seal one object containing a bounded run of records from one writer.
///
/// New payloads are JSON arrays. [`unseal_mutation_log_segment`] also accepts
/// the historical single-record JSON object, so already-published objects stay
/// readable across the batching cutover.
pub async fn seal_mutation_log_segment_batch(
    records: &[PinLogRecord],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<MutationLogSegment, String> {
    let Some(last) = records.last() else {
        return Err("cannot seal an empty mutation log segment".to_string());
    };
    if records.len() > MUTATION_LOG_SEGMENT_MAX_RECORDS {
        return Err(format!(
            "mutation log segment has {} records; maximum is {MUTATION_LOG_SEGMENT_MAX_RECORDS}",
            records.len()
        ));
    }
    let writer = if last.writer_id.is_empty() {
        "unknown-writer"
    } else {
        last.writer_id.as_str()
    };
    if records.iter().any(|record| {
        let record_writer = if record.writer_id.is_empty() {
            "unknown-writer"
        } else {
            record.writer_id.as_str()
        };
        record_writer != writer
    }) {
        return Err("mutation log segment cannot mix writer streams".to_string());
    }
    if records
        .windows(2)
        .any(|pair| pair[0].frontier_after >= pair[1].frontier_after)
    {
        return Err("mutation log segment frontiers must be strictly increasing".to_string());
    }

    let identity = mutation_log_batch_identity(records)?;
    let segment = if let Some((schema, utc_nanos)) = identity {
        MutationLogSegmentId::schema_folder(
            writer,
            schema,
            utc_nanos,
            last.frontier_after,
            last.frontier_after,
        )
    } else {
        let object_key =
            MutationLogSegmentId::default_object_key(Some(writer), last.frontier_after);
        MutationLogSegmentId {
            writer_id: Some(writer.to_string()),
            schema_name: None,
            utc_nanos: None,
            sequence: None,
            through_id: last.frontier_after,
            object_key,
        }
    };

    let payload = seal_mutation_log_json(records, crypto, "mutation log segment batch").await?;

    Ok(MutationLogSegment { segment, payload })
}

async fn seal_transaction_group(
    record: &PinLogRecord,
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<MutationLogSegment>, String> {
    let LogOp::MutationIntent { mutations } = &record.entry.op else {
        return Err("transaction group requires a MutationIntent".to_string());
    };
    let Some((schemas, utc_nanos)) = mutation_log_record_schemas(record)? else {
        return Err("transaction group requires typed mutations".to_string());
    };
    if schemas.len() < 2 {
        return Err("transaction group requires more than one schema".to_string());
    }
    let operation_count = u32::try_from(mutations.len())
        .map_err(|_| "transaction group has too many operations".to_string())?;
    let shard_count = u32::try_from(schemas.len())
        .map_err(|_| "transaction group has too many schemas".to_string())?;
    let record_digest_version = TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1;
    let record_sha256 = transaction_group_record_sha256(record)?;
    let group_id = transaction_group_id(record, record_digest_version, &record_sha256);

    let writer = if record.writer_id.is_empty() {
        "unknown-writer"
    } else {
        record.writer_id.as_str()
    };
    let mut by_schema: BTreeMap<String, Vec<TransactionGroupIndexedMutation>> = BTreeMap::new();
    for (index, mutation) in mutations.iter().cloned().enumerate() {
        let original_index = u32::try_from(index)
            .map_err(|_| "transaction group operation index exceeds u32".to_string())?;
        by_schema
            .entry(mutation.schema_name.trim().to_string())
            .or_default()
            .push(TransactionGroupIndexedMutation {
                original_index,
                mutation,
            });
    }

    let mut objects = Vec::with_capacity(by_schema.len() + 1);
    let mut shard_refs = Vec::with_capacity(by_schema.len());
    for (shard_index, (schema_name, operations)) in by_schema.into_iter().enumerate() {
        let shard_index = u32::try_from(shard_index)
            .map_err(|_| "transaction group shard index exceeds u32".to_string())?;
        let shard_t0 = operations
            .iter()
            .map(|operation| operation.mutation.written_at)
            .max()
            .filter(|value| *value > 0)
            .ok_or_else(|| format!("transaction group shard {schema_name} has no positive T0"))?;
        let segment = MutationLogSegmentId::schema_folder(
            writer,
            schema_name.as_str(),
            shard_t0,
            record.frontier_after,
            record.frontier_after,
        );
        let operation_indexes = operations
            .iter()
            .map(|operation| operation.original_index)
            .collect::<Vec<_>>();
        let wire = TransactionGroupWireV2::Shard {
            format_version: TRANSACTION_GROUP_WIRE_VERSION,
            group_id: group_id.clone(),
            writer_id: writer.to_string(),
            frontier_after: record.frontier_after,
            schema_name: schema_name.clone(),
            shard_index,
            shard_count,
            operations,
        };
        let payload = seal_mutation_log_json(&wire, crypto, "transaction group shard").await?;
        shard_refs.push(TransactionGroupShardRef {
            schema_name,
            shard_index,
            object_key: segment.object_key.clone(),
            ciphertext_sha256: sha256_hex(&payload),
            operation_indexes,
        });
        objects.push(MutationLogSegment { segment, payload });
    }

    let mut record_template = record.clone();
    let LogOp::MutationIntent { mutations } = &mut record_template.entry.op else {
        return Err("transaction group template lost its MutationIntent".to_string());
    };
    mutations.clear();
    let manifest_wire = TransactionGroupWireV2::Manifest {
        format_version: TRANSACTION_GROUP_WIRE_VERSION,
        group_id,
        writer_id: writer.to_string(),
        frontier_after: record.frontier_after,
        record_digest_version,
        record_sha256,
        operation_count,
        shard_count,
        record_template: Box::new(record_template),
        shards: shard_refs,
    };
    let manifest_segment = MutationLogSegmentId::schema_folder(
        writer,
        TRANSACTION_GROUP_MANIFEST_SCHEMA,
        utc_nanos,
        record.frontier_after,
        record.frontier_after,
    );
    let manifest_payload =
        seal_mutation_log_json(&manifest_wire, crypto, "transaction group manifest").await?;
    objects.push(MutationLogSegment {
        segment: manifest_segment,
        payload: manifest_payload,
    });
    Ok(objects)
}

async fn seal_mutation_log_publish_unit(
    records: &[PinLogRecord],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<MutationLogSegment>, String> {
    if records.len() == 1
        && matches!(
            mutation_log_record_stream(&records[0])?,
            MutationLogRecordStream::MultiSchema
        )
    {
        return seal_transaction_group(&records[0], crypto).await;
    }
    Ok(vec![
        seal_mutation_log_segment_batch(records, crypto).await?,
    ])
}

/// Decrypt, verify hash, deserialize — inverse of [`seal_mutation_log_segment`].
///
/// Exists so the sealed bytes are provably openable rather than write-only
/// ciphertext. `PinLogRecord` had no cloud reader at all when the plaintext
/// defect was found, which is a large part of why nobody noticed the writer
/// was emitting bare JSON: nothing ever tried to open what it wrote.
///
/// `transfer/s3_io/fetch.rs` calls this on the production replay path to
/// recognize a mutation-log segment sharing the legacy flat `log/{seq}.enc`
/// namespace with replayable `LogEntry` objects.
pub async fn unseal_mutation_log_segment(
    sealed: &[u8],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<PinLogRecord>, String> {
    let json = open_mutation_log_json(sealed, crypto).await?;

    #[derive(Deserialize)]
    #[serde(untagged)]
    enum WirePayload {
        Batch(Vec<PinLogRecord>),
        LegacySingle(Box<PinLogRecord>),
    }

    let records = match serde_json::from_slice(&json)
        .map_err(|e| format!("decode mutation log segment: {e}"))?
    {
        WirePayload::Batch(records) => records,
        WirePayload::LegacySingle(record) => vec![*record],
    };
    if records.is_empty() {
        return Err("mutation log segment decoded to an empty record batch".to_string());
    }
    Ok(records)
}

#[derive(Debug)]
struct MutationLogReplayUnit {
    segment: MutationLogSegmentId,
    records: Vec<PinLogRecord>,
    transaction_group: bool,
}

#[derive(Debug)]
struct TransactionGroupShardObject {
    segment: MutationLogSegmentId,
    ciphertext_sha256: String,
    writer_id: String,
    frontier_after: u64,
    schema_name: String,
    shard_index: u32,
    shard_count: u32,
    operations: Vec<TransactionGroupIndexedMutation>,
    raw_operations: Vec<TransactionGroupRawIndexedMutation>,
}

#[derive(Debug)]
struct TransactionGroupManifestObject {
    segment: MutationLogSegmentId,
    writer_id: String,
    frontier_after: u64,
    record_digest_version: u32,
    record_sha256: String,
    operation_count: u32,
    shard_count: u32,
    record_template: Box<PinLogRecord>,
    raw_record_template: Box<RawValue>,
    shards: Vec<TransactionGroupShardRef>,
}

#[derive(Debug, Default)]
struct TransactionGroupAssembly {
    manifest: Option<TransactionGroupManifestObject>,
    shards: Vec<TransactionGroupShardObject>,
}

fn decode_legacy_mutation_log_records(json: &[u8]) -> Result<Vec<PinLogRecord>, String> {
    #[derive(Deserialize)]
    #[serde(untagged)]
    enum WirePayload {
        Batch(Vec<PinLogRecord>),
        LegacySingle(Box<PinLogRecord>),
    }

    let records = match serde_json::from_slice(json)
        .map_err(|e| format!("decode mutation log segment: {e}"))?
    {
        WirePayload::Batch(records) => records,
        WirePayload::LegacySingle(record) => vec![*record],
    };
    if records.is_empty() {
        return Err("mutation log segment decoded to an empty record batch".to_string());
    }
    Ok(records)
}

fn validate_transaction_group_segment_identity(
    segment: &MutationLogSegmentId,
    writer_id: &str,
    schema_name: &str,
    frontier_after: u64,
) -> Result<(), String> {
    if segment.writer_id.as_deref() != Some(writer_id)
        || segment.schema_name.as_deref() != Some(schema_name)
        || segment.sequence != Some(frontier_after)
        || segment.through_id != frontier_after
        || segment.object_key != segment.expected_object_key()
    {
        return Err(format!(
            "transaction group object identity mismatch for {}",
            segment.object_key
        ));
    }
    Ok(())
}

async fn open_mutation_log_replay_units(
    segments: &[MutationLogSegment],
    crypto: &Arc<dyn CryptoProvider>,
) -> Result<Vec<MutationLogReplayUnit>, String> {
    let mut units = Vec::new();
    let mut groups = BTreeMap::<String, TransactionGroupAssembly>::new();

    for object in segments {
        let json = open_mutation_log_json(&object.payload, crypto).await?;
        let Ok(wire) = serde_json::from_slice::<TransactionGroupWireV2>(&json) else {
            units.push(MutationLogReplayUnit {
                segment: object.segment.clone(),
                records: decode_legacy_mutation_log_records(&json)?,
                transaction_group: false,
            });
            continue;
        };
        let raw_wire = serde_json::from_slice::<TransactionGroupWireV2Raw>(&json)
            .map_err(|error| format!("decode raw transaction group wire: {error}"))?;
        match (wire, raw_wire) {
            (
                TransactionGroupWireV2::Shard {
                    format_version,
                    group_id,
                    writer_id,
                    frontier_after,
                    schema_name,
                    shard_index,
                    shard_count,
                    operations,
                },
                TransactionGroupWireV2Raw {
                    wire_type,
                    operations: Some(raw_operations),
                    record_template: None,
                },
            ) if wire_type == "shard" => {
                if format_version != TRANSACTION_GROUP_WIRE_VERSION {
                    return Err(format!(
                        "unsupported transaction group shard version {format_version}"
                    ));
                }
                validate_transaction_group_segment_identity(
                    &object.segment,
                    &writer_id,
                    &schema_name,
                    frontier_after,
                )?;
                if group_id.is_empty()
                    || operations.is_empty()
                    || operations.iter().any(|operation| {
                        operation.mutation.schema_name.trim() != schema_name
                            || operation.mutation.written_at == 0
                    })
                    || object.segment.utc_nanos
                        != operations
                            .iter()
                            .map(|operation| operation.mutation.written_at)
                            .max()
                    || operations.len() != raw_operations.len()
                    || operations
                        .iter()
                        .zip(&raw_operations)
                        .any(|(operation, raw)| operation.original_index != raw.original_index)
                {
                    return Err(format!(
                        "transaction group shard identity does not match its operations for {}",
                        object.segment.object_key
                    ));
                }
                groups
                    .entry(group_id)
                    .or_default()
                    .shards
                    .push(TransactionGroupShardObject {
                        segment: object.segment.clone(),
                        ciphertext_sha256: sha256_hex(&object.payload),
                        writer_id,
                        frontier_after,
                        schema_name,
                        shard_index,
                        shard_count,
                        operations,
                        raw_operations,
                    });
            }
            (
                TransactionGroupWireV2::Manifest {
                    format_version,
                    group_id,
                    writer_id,
                    frontier_after,
                    record_digest_version,
                    record_sha256,
                    operation_count,
                    shard_count,
                    record_template,
                    shards,
                },
                TransactionGroupWireV2Raw {
                    wire_type,
                    operations: None,
                    record_template: Some(raw_record_template),
                },
            ) if wire_type == "manifest" => {
                if format_version != TRANSACTION_GROUP_WIRE_VERSION {
                    return Err(format!(
                        "unsupported transaction group manifest version {format_version}"
                    ));
                }
                validate_transaction_group_segment_identity(
                    &object.segment,
                    &writer_id,
                    TRANSACTION_GROUP_MANIFEST_SCHEMA,
                    frontier_after,
                )?;
                if group_id.is_empty() || operation_count == 0 || shard_count == 0 {
                    return Err(format!(
                        "transaction group manifest is empty for {}",
                        object.segment.object_key
                    ));
                }
                let assembly = groups.entry(group_id.clone()).or_default();
                if assembly.manifest.is_some() {
                    return Err(format!("transaction group {group_id} has two manifests"));
                }
                assembly.manifest = Some(TransactionGroupManifestObject {
                    segment: object.segment.clone(),
                    writer_id,
                    frontier_after,
                    record_digest_version,
                    record_sha256,
                    operation_count,
                    shard_count,
                    record_template,
                    raw_record_template,
                    shards,
                });
            }
            _ => {
                return Err(format!(
                    "transaction group typed and raw wire forms disagree for {}",
                    object.segment.object_key
                ));
            }
        }
    }

    for (group_id, mut assembly) in groups {
        let manifest = assembly.manifest.ok_or_else(|| {
            format!("transaction group {group_id} has shards but no commit manifest")
        })?;
        if manifest.shard_count as usize != manifest.shards.len()
            || manifest.shard_count as usize != assembly.shards.len()
        {
            return Err(format!(
                "transaction group {group_id} shard count does not match its manifest"
            ));
        }
        if !matches!(
            manifest.record_digest_version,
            TRANSACTION_GROUP_RECORD_DIGEST_LEGACY_JSON
                | TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1
        ) {
            return Err(format!(
                "unsupported transaction group record digest version {}",
                manifest.record_digest_version
            ));
        }
        assembly.shards.sort_by_key(|shard| shard.shard_index);
        let mut operations = vec![None; manifest.operation_count as usize];
        let mut raw_operations = std::iter::repeat_with(|| None)
            .take(manifest.operation_count as usize)
            .collect::<Vec<Option<Box<RawValue>>>>();
        let mut seen_shards = BTreeSet::new();
        for shard in assembly.shards {
            if shard.writer_id != manifest.writer_id
                || shard.frontier_after != manifest.frontier_after
                || shard.shard_count != manifest.shard_count
                || !seen_shards.insert(shard.shard_index)
            {
                return Err(format!(
                    "transaction group {group_id} has inconsistent shard identity"
                ));
            }
            let reference = manifest
                .shards
                .iter()
                .find(|reference| reference.shard_index == shard.shard_index)
                .ok_or_else(|| {
                    format!(
                        "transaction group {group_id} shard {} is absent from its manifest",
                        shard.shard_index
                    )
                })?;
            let shard_indexes = shard
                .operations
                .iter()
                .map(|operation| operation.original_index)
                .collect::<Vec<_>>();
            if reference.schema_name != shard.schema_name
                || reference.object_key != shard.segment.object_key
                || reference.ciphertext_sha256 != shard.ciphertext_sha256
                || reference.operation_indexes != shard_indexes
            {
                return Err(format!(
                    "transaction group {group_id} shard {} fails manifest validation",
                    shard.shard_index
                ));
            }
            for (operation, raw_operation) in shard.operations.into_iter().zip(shard.raw_operations)
            {
                let index = operation.original_index as usize;
                let slot = operations.get_mut(index).ok_or_else(|| {
                    format!(
                        "transaction group {group_id} operation index {} is out of range",
                        operation.original_index
                    )
                })?;
                if slot.replace(operation.mutation).is_some() {
                    return Err(format!(
                        "transaction group {group_id} repeats operation index {}",
                        operation.original_index
                    ));
                }
                let raw_slot = raw_operations.get_mut(index).ok_or_else(|| {
                    format!(
                        "transaction group {group_id} raw operation index {} is out of range",
                        raw_operation.original_index
                    )
                })?;
                if raw_operation.original_index != operation.original_index
                    || raw_slot.replace(raw_operation.mutation).is_some()
                {
                    return Err(format!(
                        "transaction group {group_id} repeats or misaligns raw operation index {}",
                        raw_operation.original_index
                    ));
                }
            }
        }
        let mutations = operations
            .into_iter()
            .enumerate()
            .map(|(index, mutation)| {
                mutation.ok_or_else(|| {
                    format!("transaction group {group_id} omits operation index {index}")
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let raw_mutations = raw_operations
            .into_iter()
            .enumerate()
            .map(|(index, mutation)| {
                mutation.ok_or_else(|| {
                    format!("transaction group {group_id} omits raw operation index {index}")
                })
            })
            .collect::<Result<Vec<_>, _>>()?;
        let mut record = *manifest.record_template;
        if record.writer_id != manifest.writer_id
            || record.frontier_after != manifest.frontier_after
        {
            return Err(format!(
                "transaction group {group_id} record identity does not match its manifest"
            ));
        }
        let LogOp::MutationIntent {
            mutations: template_mutations,
        } = &mut record.entry.op
        else {
            return Err(format!(
                "transaction group {group_id} template is not a MutationIntent"
            ));
        };
        if !template_mutations.is_empty() {
            return Err(format!(
                "transaction group {group_id} template already contains operations"
            ));
        }
        *template_mutations = mutations;
        let manifest_t0 = template_mutations
            .iter()
            .map(|mutation| mutation.written_at)
            .max();
        if manifest.segment.utc_nanos != manifest_t0 {
            return Err(format!(
                "transaction group {group_id} manifest T0 does not match its operations"
            ));
        }
        let reconstructed_record_sha256 = match manifest.record_digest_version {
            TRANSACTION_GROUP_RECORD_DIGEST_LEGACY_JSON => {
                let record_json = legacy_transaction_group_record_json(
                    manifest.raw_record_template.as_ref(),
                    &raw_mutations,
                )?;
                sha256_hex(&record_json)
            }
            TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1 => {
                transaction_group_record_sha256(&record)?
            }
            _ => unreachable!("unsupported record digest versions fail before assembly"),
        };
        if reconstructed_record_sha256 != manifest.record_sha256 {
            return Err(format!(
                "transaction group {group_id} reconstructed record hash mismatch"
            ));
        }
        if transaction_group_id(
            &record,
            manifest.record_digest_version,
            &manifest.record_sha256,
        ) != group_id
        {
            return Err(format!(
                "transaction group {group_id} stable identity does not match its record"
            ));
        }
        units.push(MutationLogReplayUnit {
            segment: manifest.segment,
            records: vec![record],
            transaction_group: true,
        });
    }
    Ok(units)
}

/// Apply encrypted mutation-log segments newer than an incorporated snapshot
/// frontier, then flush every touched namespace before returning.
///
/// Snapshot restore and log replay intentionally remain separate cloud fetch
/// phases, but share this apply boundary. Segment metadata is authenticated by
/// the encrypted record payload: writer, through-id, and object key must agree
/// before any record is applied. A segment that straddles the snapshot frontier
/// replays only its newer records.
pub async fn replay_mutation_log_segments(
    engine: &SyncEngine,
    segments: &[MutationLogSegment],
    incorporated_frontier: &Frontier,
) -> SyncResult<MutationLogReplayReport> {
    replay_mutation_log_segments_with_crypto(
        engine,
        segments,
        incorporated_frontier,
        &engine.crypto,
    )
    .await
}

pub async fn replay_mutation_log_segments_with_crypto(
    engine: &SyncEngine,
    segments: &[MutationLogSegment],
    incorporated_frontier: &Frontier,
    crypto: &Arc<dyn crate::crypto::CryptoProvider>,
) -> SyncResult<MutationLogReplayReport> {
    replay_mutation_log_segments_with_progress(
        engine,
        segments,
        incorporated_frontier,
        None,
        crypto,
    )
    .await
}

async fn replay_mutation_log_segments_with_progress(
    engine: &SyncEngine,
    segments: &[MutationLogSegment],
    incorporated_frontier: &Frontier,
    progress: Option<&RestoreProgress>,
    crypto: &Arc<dyn crate::crypto::CryptoProvider>,
) -> SyncResult<MutationLogReplayReport> {
    progress::phase(progress, RestorePhase::TailReplay);
    let mut ordered = open_mutation_log_replay_units(segments, crypto)
        .await
        .map_err(SyncError::Storage)?;
    ordered.sort_by(|a, b| {
        a.segment
            .writer_id
            .cmp(&b.segment.writer_id)
            .then(a.segment.through_id.cmp(&b.segment.through_id))
    });

    let mut frontier_after = match incorporated_frontier {
        Frontier::Scalar { .. } => BTreeMap::new(),
        Frontier::Vector { through } => through.clone(),
    };
    // Only a true Scalar F (S0 cut) seeds missing writers. A one-entry Vector
    // must not: `as_scalar_through` would copy writer A's published through-id
    // onto writer B and skip B's stream whenever B's seq is <= A's F.
    let scalar_base = match incorporated_frontier {
        Frontier::Scalar { through } => Some(*through),
        Frontier::Vector { .. } => None,
    };
    let mut touched_namespaces = BTreeSet::new();
    let mut report = MutationLogReplayReport {
        segments_considered: ordered.len(),
        ..MutationLogReplayReport::default()
    };

    progress::update(progress, |p| p.replay_segments_total = Some(ordered.len()));
    for segment in ordered {
        let records = segment.records;
        let last = records.last().ok_or_else(|| {
            SyncError::Storage("mutation-log segment decoded empty during replay".to_string())
        })?;
        let writer_id = last.writer_id.as_str();
        if records.iter().any(|record| record.writer_id != writer_id) {
            return Err(SyncError::Storage(format!(
                "mutation-log segment {} mixes writer streams",
                segment.segment.object_key
            )));
        }
        if segment.segment.writer_id.as_deref() != Some(writer_id)
            || segment.segment.through_id != last.frontier_after
            || segment.segment.object_key != segment.segment.expected_object_key()
        {
            return Err(SyncError::Storage(format!(
                "mutation-log segment identity mismatch for {}",
                segment.segment.object_key
            )));
        }
        let has_typed_identity = segment.segment.schema_name.is_some()
            || segment.segment.utc_nanos.is_some()
            || segment.segment.sequence.is_some();
        if has_typed_identity && !segment.transaction_group {
            let (schema, utc_nanos) = mutation_log_batch_identity(&records)
                .map_err(SyncError::Storage)?
                .ok_or_else(|| {
                    SyncError::Storage(format!(
                        "mutation-log segment typed identity has a legacy payload for {}",
                        segment.segment.object_key
                    ))
                })?;
            if segment.segment.schema_name.as_deref() != Some(schema)
                || segment.segment.utc_nanos != Some(utc_nanos)
                || segment.segment.sequence != Some(last.frontier_after)
            {
                return Err(SyncError::Storage(format!(
                    "mutation-log segment typed identity mismatch for {}",
                    segment.segment.object_key
                )));
            }
        }
        if records
            .windows(2)
            .any(|pair| pair[0].frontier_after >= pair[1].frontier_after)
        {
            return Err(SyncError::Storage(format!(
                "mutation-log segment {} has non-monotonic records",
                segment.segment.object_key
            )));
        }

        let writer_frontier = frontier_after
            .entry(writer_id.to_string())
            .or_insert_with(|| scalar_base.unwrap_or(0));
        let before_applied = report.records_applied;
        for record in records {
            if record.frontier_after <= *writer_frontier {
                report.records_skipped_at_or_below_frontier += 1;
                continue;
            }
            let target = if record.target_prefix.is_empty() {
                None
            } else {
                Some(
                    engine
                        .pin_log
                        .sync_target_by_prefix(&record.target_prefix)
                        .await
                        .map_err(SyncError::Storage)?,
                )
            };
            engine.replay_entry(&record.entry, target.as_ref()).await?;
            touched_namespaces.insert(log_entry_namespace(&record.entry).to_string());
            *writer_frontier = record.frontier_after;
            report.records_applied += 1;
            progress::update(progress, |p| {
                p.replay_records_applied = report.records_applied;
            });
        }
        if report.records_applied > before_applied {
            report.segments_applied += 1;
            progress::update(progress, |p| {
                p.replay_segments_applied = report.segments_applied;
            });
        }
    }

    for namespace in touched_namespaces {
        engine
            .store
            .open_namespace(&namespace)
            .await?
            .flush()
            .await?;
    }
    report.frontier_after = frontier_after;
    Ok(report)
}

/// Production restore apply boundary after an S0 base is installed.
///
/// Snapshot/S0 install and continuous-log apply remain separate cloud fetch
/// phases, but product restore (LastStore home restore, device bootstrap after
/// S0) and CoW proofs share this entry so `replay_mutation_log_segments` is not
/// test-harness-only. Callers that already hold sealed segment payloads (local
/// test plane, pre-downloaded objects) pass them here; cloud listing/download
/// is [`SyncEngine::download_mutation_log_segments_above`].
pub async fn restore_mutation_log_after_s0(
    engine: &SyncEngine,
    segments: &[MutationLogSegment],
    incorporated_frontier: &Frontier,
) -> SyncResult<MutationLogReplayReport> {
    replay_mutation_log_segments(engine, segments, incorporated_frontier).await
}

/// Local-plane variant of [`restore_mutation_log_after_s0`] for tests and CoW
/// harnesses that publish sealed segments into [`MutationLogLocalCloud`].
pub async fn restore_mutation_log_after_s0_from_plane(
    engine: &SyncEngine,
    plane: &MutationLogLocalCloud,
    incorporated_frontier: &Frontier,
) -> SyncResult<MutationLogReplayReport> {
    let segments = plane.segments_above(incorporated_frontier);
    restore_mutation_log_after_s0(engine, &segments, incorporated_frontier).await
}

pub(crate) use super::helpers::parse_mutation_log_object_key;

fn mutation_log_segment_id_from_object_key(
    listed_object_key: &str,
    through_id: u64,
) -> Result<MutationLogSegmentId, String> {
    let relative =
        super::helpers::relative_mutation_log_key(listed_object_key).unwrap_or(listed_object_key);
    let body = relative
        .strip_prefix("log/")
        .ok_or_else(|| format!("mutation-log object key is outside log/: {listed_object_key}"))?;
    let parts = body.split('/').collect::<Vec<_>>();
    let segment = if let [writer, filename] = parts.as_slice() {
        let sequence = filename
            .strip_suffix(".enc")
            .and_then(|value| value.parse::<u64>().ok())
            .ok_or_else(|| format!("invalid mutation-log object key: {listed_object_key}"))?;
        MutationLogSegmentId {
            writer_id: Some((*writer).to_string()),
            schema_name: None,
            utc_nanos: None,
            sequence: None,
            through_id: sequence,
            object_key: MutationLogSegmentId::default_object_key(Some(writer), sequence),
        }
    } else if parts.len() >= 3 {
        let writer = parts[0];
        let filename = parts[parts.len() - 1];
        let schema_parts = &parts[1..parts.len() - 1];
        if writer.is_empty()
            || schema_parts
                .iter()
                .any(|component| component.is_empty() || component.contains(".."))
        {
            return Err(format!(
                "invalid mutation-log object key shape: {listed_object_key}"
            ));
        }
        let schema = schema_parts.join("/");
        let stem = filename
            .strip_suffix(".enc")
            .ok_or_else(|| format!("invalid mutation-log object key: {listed_object_key}"))?;
        let (utc_nanos, sequence) = stem
            .rsplit_once('_')
            .and_then(|(utc_nanos, sequence)| {
                Some((
                    utc_nanos.parse::<u64>().ok()?,
                    sequence.parse::<u64>().ok()?,
                ))
            })
            .ok_or_else(|| format!("invalid mutation-log object key: {listed_object_key}"))?;
        MutationLogSegmentId::schema_folder(writer, schema, utc_nanos, sequence, sequence)
    } else {
        return Err(format!(
            "invalid mutation-log object key shape: {listed_object_key}"
        ));
    };
    if segment.through_id != through_id || segment.object_key != relative {
        return Err(format!(
            "mutation-log object key {listed_object_key} does not match through-id {through_id}"
        ));
    }
    Ok(segment)
}

impl SyncEngine {
    async fn publication_positions_confirmed(
        &self,
        positions: &[MutationLogTargetPosition],
    ) -> bool {
        if positions.is_empty() {
            return false;
        }
        let state = self.pin_log.state.lock().await;
        positions.iter().all(|position| {
            state
                .get(&position.target_id)
                .and_then(|runtime| runtime.published_f_by_writer.get(&position.writer_id))
                .is_some_and(|published| *published >= position.frontier)
        })
    }

    /// Wait for cloud confirmation of every exact target/writer frontier.
    ///
    /// A scalar max never enters this predicate. A newer frontier from a
    /// different writer or target cannot satisfy the receipt.
    pub(crate) async fn wait_for_mutation_publication(
        &self,
        positions: &[MutationLogTargetPosition],
        timeout: std::time::Duration,
    ) -> MutationPublicationWait {
        let started = std::time::Instant::now();
        loop {
            if self.publication_positions_confirmed(positions).await {
                return MutationPublicationWait::Published;
            }
            let elapsed = started.elapsed();
            if elapsed >= timeout {
                return MutationPublicationWait::Pending;
            }
            let remaining = timeout.saturating_sub(elapsed);
            tokio::time::sleep(remaining.min(std::time::Duration::from_millis(25))).await;
        }
    }

    /// List + download continuous mutation-log segments from the personal cloud
    /// prefix that are not wholly covered by `incorporated_frontier`.
    ///
    /// Classic `LogEntry` objects that still share the flat `log/` namespace are
    /// skipped (unseal-as-segment fails). Fail-closed only when a listed object
    /// that *is* a mutation-log segment cannot be authenticated/decoded.
    pub async fn download_mutation_log_segments_above(
        &self,
        incorporated_frontier: &Frontier,
    ) -> SyncResult<Vec<MutationLogSegment>> {
        let target = {
            let targets = self.targets.lock().await;
            targets.first().cloned().ok_or_else(|| {
                SyncError::Storage(
                    "download mutation-log segments: no personal sync target".to_string(),
                )
            })?
        };
        self.download_mutation_log_segments_above_target(&target, incorporated_frontier)
            .await
    }

    pub(crate) async fn download_mutation_log_segments_above_target(
        &self,
        target: &SyncTarget,
        incorporated_frontier: &Frontier,
    ) -> SyncResult<Vec<MutationLogSegment>> {
        self.download_mutation_log_segments_with_progress(target, incorporated_frontier, None)
            .await
    }

    async fn download_mutation_log_segments_with_progress(
        &self,
        target: &SyncTarget,
        incorporated_frontier: &Frontier,
        progress: Option<&RestoreProgress>,
    ) -> SyncResult<Vec<MutationLogSegment>> {
        progress::phase(progress, RestorePhase::TailDownload);
        let objects = progress::measure(
            progress,
            TransferOperation::Authorization,
            self.auth.list_log_objects(target),
        )
        .await?;
        let (candidates, flat_classic_skipped) = select_peer_apply_candidates(
            objects.iter().map(|obj| obj.key.as_str()),
            incorporated_frontier,
        );
        if flat_classic_skipped > 0 {
            tracing::debug!(
                target: "fold_db::sync::mutation_log",
                flat_classic_skipped,
                candidates = candidates.len(),
                "peer-apply skipped classic flat log objects without downloading them"
            );
        }

        let candidates = candidates
            .into_iter()
            .map(|(writer, through_id, object_key)| {
                let segment = mutation_log_segment_id_from_object_key(&object_key, through_id)?;
                Ok((writer, object_key, segment))
            })
            .collect::<Result<Vec<_>, String>>()
            .map_err(SyncError::Storage)?;
        progress::update(progress, |p| p.tail_objects_total = Some(candidates.len()));
        let mut segments = Vec::with_capacity(candidates.len());
        // Reuse the ordinary presign batch size so restore does not invent a
        // second fan-out policy for the same cloud plane. Keep typed and
        // legacy requests separate. A share scope accepts server-derived typed
        // keys, while its legacy path still uses flat sequence keys.
        const BATCH: usize = 32;
        for typed in [false, true] {
            let selected = candidates
                .iter()
                .filter(|(_, _, segment)| segment.schema_name.is_some() == typed)
                .collect::<Vec<_>>();
            for chunk in selected.chunks(BATCH) {
                let segment_ids = chunk
                    .iter()
                    .map(|(_, _, segment)| segment.clone())
                    .collect::<Vec<_>>();
                let urls = progress::measure(progress, TransferOperation::Authorization, async {
                    if typed {
                        self.auth
                            .presign_download_segments(target, &segment_ids)
                            .await
                    } else {
                        let seqs = segment_ids
                            .iter()
                            .map(|segment| segment.through_id)
                            .collect::<Vec<_>>();
                        let object_keys = segment_ids
                            .iter()
                            .map(|segment| segment.object_key.clone())
                            .collect::<Vec<_>>();
                        self.auth
                            .presign_download_object_keys(target, &seqs, &object_keys)
                            .await
                    }
                })
                .await?;
                if urls.len() != chunk.len() {
                    return Err(SyncError::Auth(format!(
                        "expected {} presigned mutation-log download URLs, got {}",
                        chunk.len(),
                        urls.len()
                    )));
                }
                for (((writer_hint, object_key, _), segment_id), url) in
                    chunk.iter().copied().zip(segment_ids).zip(urls)
                {
                    let Some(bytes) = progress::measure(
                        progress,
                        TransferOperation::Download,
                        self.s3.download(&url),
                    )
                    .await?
                    else {
                        return Err(SyncError::Storage(format!(
                            "mutation-log segment {object_key} missing during restore download"
                        )));
                    };
                    progress::update(progress, |p| {
                        p.response_body_bytes =
                            p.response_body_bytes.saturating_add(bytes.len() as u64);
                        p.tail_objects_downloaded += 1;
                    });
                    let writer = segment_id.writer_id.as_deref().unwrap_or(writer_hint);
                    if incorporated_frontier.covers_log(Some(writer), segment_id.through_id) {
                        continue;
                    }
                    segments.push(MutationLogSegment {
                        segment: segment_id,
                        payload: bytes,
                    });
                }
            }
        }
        segments.sort_by(|a, b| {
            a.segment
                .writer_id
                .cmp(&b.segment.writer_id)
                .then(a.segment.through_id.cmp(&b.segment.through_id))
        });
        Ok(segments)
    }

    /// Production restore phase 2: after LastStore S0 is installed on this
    /// engine's store, download continuous mutation-log segments above F and
    /// apply them via [`restore_mutation_log_after_s0`].
    pub async fn restore_mutation_log_after_s0(
        &self,
        incorporated_frontier: &Frontier,
    ) -> SyncResult<MutationLogReplayReport> {
        self.restore_mutation_log_after_s0_with_progress(incorporated_frontier, None)
            .await
    }

    pub async fn restore_mutation_log_after_s0_with_progress(
        &self,
        incorporated_frontier: &Frontier,
        progress: Option<&RestoreProgress>,
    ) -> SyncResult<MutationLogReplayReport> {
        let target = self.targets.lock().await.first().cloned().ok_or_else(|| {
            SyncError::Storage(
                "download mutation-log segments: no personal sync target".to_string(),
            )
        })?;
        let segments = self
            .download_mutation_log_segments_with_progress(&target, incorporated_frontier, progress)
            .await?;
        replay_mutation_log_segments_with_progress(
            self,
            &segments,
            incorporated_frontier,
            progress,
            &target.crypto,
        )
        .await
    }

    /// Pin a lower bound before the LastStore snapshot enumerates any file.
    /// Published F alone is not a snapshot boundary: it can advance while
    /// mutable chunks are enumerated, after the corresponding atom chunk cut.
    /// Read F first, drain the accepted writes it covers, then persist this
    /// separate marker. Later confirmations never modify the pinned marker.
    pub(crate) async fn prepare_backup_restore_frontier(&self) -> SyncResult<()> {
        let marker = BackupRestoreFrontier {
            version: 1,
            by_writer: self
                .pin_log
                .read_published_f_strict("personal")
                .await
                .map_err(SyncError::Storage)?,
        };
        marker.validate()?;
        let barrier = self.photograph_cut_barrier.lock().await.clone();
        match barrier {
            Some(barrier) => barrier().await.map_err(SyncError::Storage)?,
            None if marker.by_writer.is_empty() => {}
            None => {
                return Err(SyncError::Storage(
                    "backup writer frontier requires a persistence barrier".into(),
                ))
            }
        }
        let store = self.backup_restore_frontier_store().await?;
        if marker.by_writer.is_empty()
            && store
                .get(BACKUP_RESTORE_F_KEY)
                .await
                .map_err(|error| {
                    SyncError::Storage(format!("read backup writer frontier: {error}"))
                })?
                .is_none()
        {
            // An absent marker already means the empty vector. Avoid a new
            // snapshot chunk for stores that never published mutation logs.
            return Ok(());
        }
        let raw = serde_json::to_vec(&marker).map_err(|error| {
            SyncError::Storage(format!("encode backup writer frontier: {error}"))
        })?;
        store
            .put(BACKUP_RESTORE_F_KEY, raw)
            .await
            .map_err(|error| {
                SyncError::Storage(format!("persist backup writer frontier: {error}"))
            })?;
        store
            .flush()
            .await
            .map_err(|error| SyncError::Storage(format!("flush backup writer frontier: {error}")))
    }

    /// Read only the cut marker from the freshly restored S0 store.
    /// Never substitute a storage CSN, the current owner's published F, or the
    /// ordinary published-F row restored from a later mutable-chunk cut.
    /// Legacy snapshots without this marker conservatively replay all writers.
    pub async fn restored_backup_mutation_frontier(&self) -> SyncResult<Frontier> {
        let store = self.backup_restore_frontier_store().await?;
        let Some(raw) = store
            .get(BACKUP_RESTORE_F_KEY)
            .await
            .map_err(|error| SyncError::Storage(format!("read backup writer frontier: {error}")))?
        else {
            return Ok(Frontier::from_writer_hwm(BTreeMap::new()));
        };
        let marker: BackupRestoreFrontier = serde_json::from_slice(&raw).map_err(|error| {
            SyncError::Storage(format!("decode backup writer frontier: {error}"))
        })?;
        marker.validate()?;
        Ok(Frontier::from_writer_hwm(marker.by_writer))
    }

    async fn backup_restore_frontier_store(
        &self,
    ) -> SyncResult<Arc<dyn crate::storage::traits::KvStore>> {
        if let Some(source) = &self.laststore_backup_source {
            return source
                .open_namespace(PIN_LOG_NAMESPACE)
                .await
                .map_err(|error| {
                    SyncError::Storage(format!("open backup frontier namespace: {error}"))
                });
        }
        self.pin_log
            .pin_log_store()
            .await
            .map_err(SyncError::Storage)
    }

    pub(crate) async fn restore_mutation_log_after_photograph(
        &self,
        target: &SyncTarget,
        incorporated_frontier: &Frontier,
    ) -> SyncResult<MutationLogReplayReport> {
        let segments = self
            .download_mutation_log_segments_above_target(target, incorporated_frontier)
            .await?;
        replay_mutation_log_segments_with_crypto(
            self,
            &segments,
            incorporated_frontier,
            &target.crypto,
        )
        .await
    }

    /// Regular `do_sync` peer apply: download writer-scoped mutation-log
    /// segments not covered by this node's published vector F, skip the local
    /// writer (self-echo), apply via [`restore_mutation_log_after_s0`], then
    /// persist applied HWMs so the next cycle does not re-fetch them.
    ///
    /// Compact photograph S is not required. LastStore S0 restore stays on
    /// [`Self::restore_mutation_log_after_s0`]; this path is the live Mini.
    ///
    /// Walks every configured target. Catalog membership for a named org DB is
    /// published on the org-hash head, not the personal prefix. Listing only
    /// `targets.first()` left a granted member Mini with zero org segments
    /// and `catalog_membership_denied` on the shared schema.
    pub async fn run_mutation_log_peer_apply_cycle(&self) -> SyncResult<MutationLogReplayReport> {
        let mut incorporated = self.pin_log.incorporated_frontier().await;
        let targets = self.targets.lock().await.clone();
        let mut combined = MutationLogReplayReport::default();
        let mut first_err: Option<SyncError> = None;
        for target in &targets {
            match self
                .peer_apply_mutation_log_on_target(target, &incorporated)
                .await
            {
                Ok(report) => {
                    combined.segments_considered = combined
                        .segments_considered
                        .saturating_add(report.segments_considered);
                    combined.segments_applied = combined
                        .segments_applied
                        .saturating_add(report.segments_applied);
                    combined.records_applied = combined
                        .records_applied
                        .saturating_add(report.records_applied);
                    combined.records_skipped_at_or_below_frontier = combined
                        .records_skipped_at_or_below_frontier
                        .saturating_add(report.records_skipped_at_or_below_frontier);
                    for (writer, through) in report.frontier_after {
                        let entry = combined.frontier_after.entry(writer).or_insert(0);
                        if through > *entry {
                            *entry = through;
                        }
                    }
                    if !combined.frontier_after.is_empty() {
                        incorporated = Frontier::from_writer_hwm(combined.frontier_after.clone());
                    }
                }
                Err(e) => {
                    tracing::warn!(
                        target: "fold_db::sync::mutation_log",
                        target_label = %target.label,
                        error = %redact_sync_error_text(&e.to_string()),
                        "mutation-log peer apply failed for target (continuing remaining targets)"
                    );
                    if first_err.is_none() {
                        first_err = Some(e);
                    }
                }
            }
        }
        if combined.segments_considered == 0 {
            if let Some(e) = first_err {
                return Err(e);
            }
        }
        // Count before the frontier persist: the segments were applied to the
        // store either way, and a failed HWM persist is a re-apply risk, not a
        // reason to under-report what this process already replayed.
        if combined.segments_applied > 0 {
            self.mutation_log_peer_segments_applied.fetch_add(
                combined.segments_applied as u64,
                std::sync::atomic::Ordering::Relaxed,
            );
        }
        if combined.records_applied > 0 {
            self.mutation_log_peer_records_applied.fetch_add(
                combined.records_applied as u64,
                std::sync::atomic::Ordering::Relaxed,
            );
        }
        if !combined.frontier_after.is_empty() {
            if let Err(e) = self
                .pin_log
                .incorporate_applied_frontier(&combined.frontier_after)
                .await
            {
                tracing::warn!(
                    target: "fold_db::sync::mutation_log",
                    error = %e,
                    "durable incorporated-F persist failed; peer segments may be re-applied after restart"
                );
            }
        }
        Ok(combined)
    }

    async fn peer_apply_mutation_log_on_target(
        &self,
        target: &SyncTarget,
        incorporated: &Frontier,
    ) -> SyncResult<MutationLogReplayReport> {
        let mut segments = self
            .download_mutation_log_segments_above_target(target, incorporated)
            .await?;
        if !self.device_id.is_empty() {
            segments.retain(|segment| {
                segment.segment.writer_id.as_deref() != Some(self.device_id.as_str())
            });
        }
        replay_mutation_log_segments_with_crypto(self, &segments, incorporated, &target.crypto)
            .await
    }
}

/// Pure helper: pick the writer-scoped mutation-log segment objects one
/// peer-apply / restore cycle must actually download.
///
/// Returns `(candidates, flat_classic_skipped)`, where each candidate is
/// `(writer_id, through_id, listed_object_key)`, sorted by writer then
/// through_id.
///
/// Only `log/{writer}/{seq}.enc` keys name a mutation-log segment. Every
/// segment upload keys itself with `default_object_key(Some(writer), ..)`, so
/// the flat `log/{seq}.enc` shape -- which `parse_mutation_log_object_key`
/// also accepts -- is always classic `LogEntry` ciphertext owned by the
/// ordinary download cursor, never a segment.
///
/// Dropping flat keys *before* the presign+download fan-out is the fix for a
/// cycle-time defect. They used to reach the fan-out and were rejected only
/// afterwards, when `unseal_mutation_log_segment` failed and the loop hit
/// `continue`, so every cycle re-downloaded the whole flat log prefix and threw
/// it away. Measured on the primary 2026-08-26 with `remote_log_entries=11358`:
/// one `do_sync` spent ~38 minutes inside this download for
/// `segments_considered=1`, so the configured 30s `sync_interval_ms` was never
/// observable and `rpo_secs` climbed at wall-clock rate. The returned segment
/// set is unchanged -- those objects could never unseal as segments -- only the
/// wasted downloads are gone.
pub(crate) fn select_peer_apply_candidates<'a, I>(
    listed_keys: I,
    incorporated_frontier: &Frontier,
) -> (Vec<(String, u64, String)>, u64)
where
    I: IntoIterator<Item = &'a str>,
{
    let mut candidates: Vec<(String, u64, String)> = Vec::new();
    let mut flat_classic_skipped: u64 = 0;
    for key in listed_keys {
        let Some((writer, through_id)) = parse_mutation_log_object_key(key) else {
            continue;
        };
        let Some(writer) = writer else {
            flat_classic_skipped = flat_classic_skipped.saturating_add(1);
            continue;
        };
        if incorporated_frontier.covers_log(Some(writer.as_str()), through_id) {
            continue;
        }
        candidates.push((writer, through_id, key.to_string()));
    }
    candidates.sort_by(|a, b| a.0.cmp(&b.0).then(a.1.cmp(&b.1)));
    (candidates, flat_classic_skipped)
}

fn log_entry_namespace(entry: &LogEntry) -> &str {
    match &entry.op {
        crate::sync::log::LogOp::Put { namespace, .. }
        | crate::sync::log::LogOp::Delete { namespace, .. }
        | crate::sync::log::LogOp::BatchPut { namespace, .. }
        | crate::sync::log::LogOp::BatchDelete { namespace, .. } => namespace,
        crate::sync::log::LogOp::LogicalCommit { .. } => "logical_commit",
        crate::sync::log::LogOp::MutationIntent { .. } => "mutation_intent",
        crate::sync::log::LogOp::PhysicalDigest { .. } => "physical_digest",
        crate::sync::log::LogOp::Unknown { .. } => "unknown",
    }
}

#[cfg(test)]
fn log_op_kind_name(op: &crate::sync::log::LogOp) -> &'static str {
    match op {
        crate::sync::log::LogOp::Put { .. } => "put",
        crate::sync::log::LogOp::Delete { .. } => "delete",
        crate::sync::log::LogOp::BatchPut { .. } => "batch_put",
        crate::sync::log::LogOp::BatchDelete { .. } => "batch_delete",
        crate::sync::log::LogOp::LogicalCommit { .. } => "logical_commit",
        crate::sync::log::LogOp::MutationIntent { .. } => "mutation_intent",
        crate::sync::log::LogOp::PhysicalDigest { .. } => "physical_digest",
        crate::sync::log::LogOp::Unknown { .. } => "unknown",
    }
}

/// In-process catch-up cloud plane (S + log + CAS latest) for pin-mode publish
/// and restore proofs. Production maps this onto laststore/S3 object keys under
/// the target's prefix; tests and the CoW harness use this local plane.
#[derive(Debug, Default, Clone)]
pub struct PinModeLocalCloud {
    published: std::collections::HashMap<String, PinModePublishedTarget>,
}

#[derive(Debug, Clone)]
struct PinModePublishedTarget {
    desc: PinModePublishDescriptor,
    sealed_objects: std::collections::HashMap<String, Vec<u8>>,
    log: Vec<PinLogRecord>,
}

/// Outcome of restoring a fresh home from a pin-mode published plane.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct PinModeRestoreReport {
    pub target_id: String,
    pub include_log: bool,
    pub base_objects: usize,
    pub log_entries: usize,
    pub app_keys_restored: usize,
    pub latest_counter: u64,
}

impl PinModeLocalCloud {
    pub fn new() -> Self {
        Self::default()
    }

    #[cfg(test)]
    fn upload_base_and_log(
        &mut self,
        desc: &PinModePublishDescriptor,
        sealed_objects: std::collections::HashMap<String, Vec<u8>>,
        log: Vec<PinLogRecord>,
    ) -> Result<(), String> {
        if sealed_objects.len() != desc.sealed_base_shas.len() {
            return Err(format!(
                "upload base object count {} != sealed_base_shas {}",
                sealed_objects.len(),
                desc.sealed_base_shas.len()
            ));
        }
        for sha in &desc.sealed_base_shas {
            if !sealed_objects.contains_key(sha) {
                return Err(format!("missing uploaded object for sealed base sha {sha}"));
            }
        }
        self.published.insert(
            desc.target_id.clone(),
            PinModePublishedTarget {
                desc: desc.clone(),
                sealed_objects,
                log,
            },
        );
        Ok(())
    }

    #[cfg(test)]
    fn cas_latest(&mut self, desc: &PinModePublishDescriptor) -> Result<(), String> {
        let entry = self
            .published
            .get_mut(&desc.target_id)
            .ok_or_else(|| "CAS latest: nothing uploaded for target".to_string())?;
        if entry.desc.publish_counter > desc.publish_counter {
            return Err(format!(
                "CAS latest rejected: plane counter {} > proposed {}",
                entry.desc.publish_counter, desc.publish_counter
            ));
        }
        entry.desc = desc.clone();
        Ok(())
    }

    #[cfg(test)]
    fn get(&self, target_id: &str) -> Option<&PinModePublishedTarget> {
        self.published.get(target_id)
    }

    pub fn latest(&self, target_id: &str) -> Option<&PinModePublishDescriptor> {
        self.published.get(target_id).map(|p| &p.desc)
    }

    pub fn log_len(&self, target_id: &str) -> usize {
        self.published.get(target_id).map_or(0, |p| p.log.len())
    }

    pub fn base_object_count(&self, target_id: &str) -> usize {
        self.published
            .get(target_id)
            .map_or(0, |p| p.sealed_objects.len())
    }
}

/// Target-scoped pin-mode / mutation-log state, extracted from `SyncEngine`.
///
/// Owns the durable pin-log runtime map. `store`, `config` and `targets` are
/// shared handles from the engine — `config` is `Clone` and never mutated after
/// construction, the other two are already `Arc` — so this observes the same
/// state the engine does rather than a divergent copy.
///
/// A few operations still need engine collaborators (cloud-plane gating, entry
/// replay, target config). Those take `engine: &SyncEngine` explicitly rather
/// than reaching for it, which keeps the remaining coupling visible instead of
/// hiding it behind a back-reference.
pub(crate) struct PinLog {
    state: Arc<Mutex<std::collections::HashMap<String, PinLogRuntime>>>,
    /// Serializes append-floor max-merge with its pin-log record batch.
    append_lock: Arc<Mutex<()>>,
    /// Serializes read/max-merge/write of whole published-F maps.
    published_f_lock: Arc<Mutex<()>>,
    store: Arc<dyn NamespacedStore>,
    config: SyncConfig,
    targets: Arc<Mutex<Vec<SyncTarget>>>,
    /// Confirmed pin-log rows deleted since the plane was last compacted.
    ///
    /// A `LastStore` delete is an append, so truncation alone never returns a
    /// byte — see [`Self::maybe_compact_pin_log_plane`]. This counter is the
    /// trigger for the rewrite that does.
    truncated_since_compact: Arc<std::sync::atomic::AtomicU64>,
    /// Truncated rows that must accumulate before the plane is compacted.
    ///
    /// Read from the environment once at construction rather than per cycle:
    /// the value cannot change under a running daemon, and a per-cycle
    /// `env::var` on the publish path buys nothing.
    compact_after_rows: u64,
    /// On-disk plane bytes above which the plane is compacted regardless of how
    /// many rows *this process* happened to truncate. `0` disables.
    ///
    /// See [`Self::maybe_compact_pin_log_plane`] for why the row counter alone
    /// is not a retention policy.
    compact_max_plane_bytes: u64,
    /// Unix seconds of the last bloat probe, so the stat walk is rate-limited.
    ///
    /// `0` means "never probed", which is deliberately due immediately: the
    /// first publish cycle after a start is exactly when an inherited bloated
    /// plane needs to be noticed.
    last_bloat_probe_unix_s: Arc<std::sync::atomic::AtomicU64>,
    /// Minimum seconds between bloat probes.
    compact_bloat_probe_interval_s: u64,
    /// Size the plane must exceed for the *next* size-triggered compaction,
    /// raised after each one so a legitimately large live set cannot turn the
    /// cap into a rewrite treadmill. See
    /// [`Self::raise_size_trigger_floor`]. `0` means "use the cap".
    size_trigger_floor_bytes: Arc<std::sync::atomic::AtomicU64>,
    /// Trigger for the most recent successful physical rewrite.
    last_compact_trigger: Arc<Mutex<Option<String>>>,
    /// Photograph packing lock, shared with [`SyncEngine`]. Held across the
    /// physical rewrite so a backup cut cannot start (or continue) while this
    /// plane's sealed files are being rewritten.
    backup_publish_target: Arc<Mutex<Option<super::backup_uploader::BackupPublishTarget>>>,
    /// Test-only: force the next Cloud upload cycle to return Err so callers
    /// (e.g. `do_sync`) can assert transfer failure is not swallowed while
    /// downloads remain healthy.
    #[cfg(test)]
    pub(crate) force_next_upload_cycle_err: std::sync::atomic::AtomicBool,
    /// Test-only: fail the next durable published-F write before any row can
    /// use that confirmation for truncation.
    #[cfg(test)]
    force_next_published_f_persist_err: std::sync::atomic::AtomicBool,
}

impl PinLog {
    #[cfg(test)]
    pub(crate) fn new(
        store: Arc<dyn NamespacedStore>,
        config: SyncConfig,
        targets: Arc<Mutex<Vec<SyncTarget>>>,
    ) -> Self {
        Self::new_with_packing_lock(store, config, targets, Arc::new(Mutex::new(None)))
    }

    /// Same as [`Self::new`], sharing the engine's photograph packing lock.
    pub(crate) fn new_with_packing_lock(
        store: Arc<dyn NamespacedStore>,
        config: SyncConfig,
        targets: Arc<Mutex<Vec<SyncTarget>>>,
        backup_publish_target: Arc<Mutex<Option<super::backup_uploader::BackupPublishTarget>>>,
    ) -> Self {
        Self {
            state: Arc::new(Mutex::new(std::collections::HashMap::new())),
            append_lock: Arc::new(Mutex::new(())),
            published_f_lock: Arc::new(Mutex::new(())),
            store,
            config,
            targets,
            truncated_since_compact: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            compact_after_rows: pin_log_compact_after_rows(),
            compact_max_plane_bytes: pin_log_compact_max_plane_bytes(),
            last_bloat_probe_unix_s: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            compact_bloat_probe_interval_s: pin_log_compact_bloat_probe_interval_s(),
            size_trigger_floor_bytes: Arc::new(std::sync::atomic::AtomicU64::new(0)),
            last_compact_trigger: Arc::new(Mutex::new(None)),
            backup_publish_target,
            #[cfg(test)]
            force_next_upload_cycle_err: std::sync::atomic::AtomicBool::new(false),
            #[cfg(test)]
            force_next_published_f_persist_err: std::sync::atomic::AtomicBool::new(false),
        }
    }

    /// Override the self-compaction threshold without touching process env.
    ///
    /// Tests assert the trigger, not the default, and `std::env::set_var` in a
    /// threaded test binary races every other test that reads the same knob.
    #[cfg(test)]
    pub(crate) fn with_compact_after_rows(mut self, rows: u64) -> Self {
        self.compact_after_rows = rows;
        self
    }

    #[cfg(test)]
    pub(crate) fn fail_next_published_f_persist(&self) {
        self.force_next_published_f_persist_err
            .store(true, std::sync::atomic::Ordering::SeqCst);
    }

    /// Override the on-disk bloat cap. Same reasoning as
    /// [`Self::with_compact_after_rows`].
    #[cfg(test)]
    pub(crate) fn with_compact_max_plane_bytes(mut self, bytes: u64) -> Self {
        self.compact_max_plane_bytes = bytes;
        self
    }

    /// Override the probe rate limit. Same reasoning as
    /// [`Self::with_compact_after_rows`].
    #[cfg(test)]
    pub(crate) fn with_compact_bloat_probe_interval_s(mut self, secs: u64) -> Self {
        self.compact_bloat_probe_interval_s = secs;
        self
    }
}

impl PinLog {
    // Pin mode is a toolkit-only surface. It is deliberately unwired, not
    // pending work: `design-lastdb-cloud-sync-mutation-log-first` (approved
    // 2026-08-04) demoted freeze-as-sync. On the continuous snapshot+log
    // cadence the freeze buys nothing, because chunks are content-addressed
    // and immutable, S is a manifest rather than a copy, and publish is a
    // single CAS -- see `lastdb-snapshot-needs-no-freeze-immutable-chunks-plus-one-cas`.
    // So "zero production callers" below is the decision, not a gap; do not
    // wire a caller or delete the surface on that finding alone.
    //
    // What survives the demotion is the write-path guard: rewriting a member
    // of a frozen S while an upload is in flight must still fail closed. That
    // is the packing lock `design-lastdb-backup-photograph-freeze-in-place`
    // (Tom, 2026-08-19) needs, and `guard_sealed_base_write` below proves it.
    //
    // Keep these helpers out of production builds; the continuous mutation-log
    // methods below are the live product surface.
    #[cfg(test)]
    /// Enter pin mode for one sync target, addressed by its cloud prefix.
    ///
    /// Use `target_prefix == ""` for the personal target. Org/share targets use
    /// their configured storage prefix (`{org_hash}/...` owner prefix). The log
    /// is not node-global: only entries partitioning to this target are appended.
    ///
    /// `sealed_base` freezes membership S_T at F0. This convenience form is a
    /// toolkit entry point for the proof harness; there is no product caller by
    /// design (see the toolkit-only note on this `impl` block).
    pub async fn enter_pin_mode_for_target(
        &self,
        target_prefix: &str,
        base_frontier: u64,
    ) -> Result<PinLogTargetStatus, String> {
        self.enter_pin_mode_for_target_with_sealed_base(target_prefix, base_frontier, Vec::new())
            .await
    }

    #[cfg(test)]
    pub async fn enter_pin_mode_for_target_with_sealed_base(
        &self,
        target_prefix: &str,
        base_frontier: u64,
        sealed_base: Vec<SealedBaseMember>,
    ) -> Result<PinLogTargetStatus, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let mut state = self.state.lock().await;
        let runtime = state.entry(target_id.clone()).or_insert_with(|| {
            PinLogRuntime::new(
                target_id,
                target.label.clone(),
                target.prefix.clone(),
                base_frontier,
                base_frontier,
                false,
            )
        });
        runtime.target_label = target.label;
        runtime.target_prefix = target.prefix;
        runtime.active = true;
        runtime.pin_freeze = true;
        runtime.base_frontier = base_frontier;
        runtime.last_durable_frontier = runtime.last_durable_frontier.max(base_frontier);
        runtime.sealed_base = sealed_base;
        runtime.pin_entered_at_ms = Some(now_millis());
        runtime.s_rewrite_attempts = 0;
        runtime.materialize_pending = false;
        Ok(runtime.status())
    }

    #[cfg(test)]
    pub async fn exit_pin_mode_for_target(
        &self,
        target_prefix: &str,
    ) -> Result<PinLogTargetStatus, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let mut state = self.state.lock().await;
        let runtime = state
            .get_mut(&target_id)
            .ok_or_else(|| format!("pin log target '{}' is not active", target.label))?;
        runtime.pin_freeze = false;
        // Keep continuous MutationLog capture active when that mode is on.
        runtime.active = matches!(self.config.capture_mode, CaptureMode::MutationLog);
        if !runtime.active {
            runtime.sealed_base.clear();
            runtime.pin_entered_at_ms = None;
        }
        Ok(runtime.status())
    }

    /// Activate the already-linearized target snapshot used by one append.
    ///
    /// The caller holds `SyncEngine::target_config_lock`, so this helper must
    /// not ask the engine for a second snapshot and deadlock on the same lock.
    pub(crate) async fn ensure_continuous_mutation_log_for_targets(
        &self,
        targets: &[SyncTarget],
    ) -> Result<(), String> {
        let mut state = self.state.lock().await;
        for target in targets {
            let target_id = target_id_for_prefix(&target.prefix);
            let runtime = state.entry(target_id.clone()).or_insert_with(|| {
                PinLogRuntime::new(
                    target_id,
                    target.label.clone(),
                    target.prefix.clone(),
                    0,
                    0,
                    true,
                )
            });
            runtime.target_label = target.label.clone();
            runtime.target_prefix = target.prefix.clone();
            runtime.active = true;
            // Never upgrade continuous ensure into a freeze.
        }
        Ok(())
    }

    /// Whether continuous full-home sealed-chunk re-upload is demoted because
    /// the mutation-log plane is the active continuous durability engine.
    ///
    /// Snapshots remain allowed for bootstrap / rare compact only — never as
    /// the steady-state publish loop (design-lastdb-cloud-sync-mutation-log-first).
    ///
    /// Held incomplete cuts are the one continuous exception: the uploader still
    /// drains + CASes an already-held target so demotion cannot strand a mid-
    /// drain publish (see `backup_uploader` continuous loop).
    pub fn continuous_sealed_home_backup_demoted(&self) -> bool {
        matches!(self.config.capture_mode, CaptureMode::MutationLog)
            && !self.config.legacy_personal_cloud_sync
    }

    /// Seal durable pin-log records above **per-writer** published F into
    /// segments under `log/{writer_id}/{seq}.enc`, put them on `plane`, and
    /// advance that writer's F (Phase B multi-writer).
    ///
    /// Never blocks local R/W (callers must not await this on the write path).
    /// Caps work per cycle via `max_segments` (0 = unlimited for tests).
    /// Does not require a snapshot lock or continuous full-home re-snapshot.
    pub async fn run_mutation_log_segment_upload_cycle(
        &self,
        engine: &SyncEngine,
        target_prefix: &str,
        plane: &mut MutationLogLocalCloud,
        max_segments: usize,
        publish: MutationLogPublish,
    ) -> Result<MutationLogUploadReport, String> {
        if !matches!(self.config.capture_mode, CaptureMode::MutationLog) {
            return Ok(MutationLogUploadReport::default());
        }
        if !engine.cloud_plane_allows_upload().await {
            return Ok(MutationLogUploadReport::default());
        }
        #[cfg(test)]
        if matches!(publish, MutationLogPublish::Cloud)
            && self
                .force_next_upload_cycle_err
                .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            return Err("injected mutation-log upload cycle failure".to_string());
        }
        if matches!(publish, MutationLogPublish::Cloud)
            && self.continuous_sealed_home_backup_demoted()
            && !engine
                .mutation_log_snapshot_base_committed()
                .map_err(|err| err.to_string())?
        {
            tracing::info!(
                target: "fold_db::sync::mutation_log",
                "mutation-log publish deferred until durable snapshot base S0 commits"
            );
            return Ok(MutationLogUploadReport::default());
        }
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let (published_before_max, runtime_per_writer_before) = {
            let state = self.state.lock().await;
            match state.get(&target_id) {
                Some(r) => (r.published_frontier, r.published_f_by_writer.clone()),
                None => (0, HashMap::new()),
            }
        };
        let durable_per_writer_before = self.read_published_f(&target_id).await;
        let mut visible_per_writer_before = runtime_per_writer_before;
        // Local-plane geometry can use volatile process state. The production
        // cloud path cannot: only the flushed durable map may classify a row as
        // confirmed and authorize its deletion.
        for (writer_id, through) in &durable_per_writer_before {
            let entry = visible_per_writer_before
                .entry(writer_id.clone())
                .or_insert(0);
            *entry = (*entry).max(*through);
        }
        // Phase B: filter by each record's writer HWM, not a single scalar.
        // Phase A single-writer homes still work (one key in the map / 0).
        //
        // Applied DURING the durable scan, not after it. Filtering after a full
        // read is what made the plane's size the cycle's memory cost; the
        // predicate needs only the one record it is handed, so the scan can
        // stop as soon as the batch is full.
        //
        // Scoped so the predicate's shared borrow of `plane` ends before the
        // publish loop below takes it mutably.
        let page = {
            let is_pending = |r: &PinLogRecord| {
                let writer_hwm = if matches!(publish, MutationLogPublish::Cloud) {
                    durable_per_writer_before
                        .get(&r.writer_id)
                        .copied()
                        .unwrap_or(0)
                } else {
                    visible_per_writer_before
                        .get(&r.writer_id)
                        .copied()
                        .unwrap_or(0)
                        .max(plane.published_f(&r.writer_id))
                };
                // Backward-compat: if map empty but scalar advanced (old process
                // state), fall back to scalar only when writer_id is the sole
                // known stream on this engine.
                let fallback = if !matches!(publish, MutationLogPublish::Cloud)
                    && visible_per_writer_before.is_empty()
                    && published_before_max > 0
                {
                    published_before_max
                } else {
                    0
                };
                let hwm = writer_hwm.max(fallback);
                r.frontier_after > hwm
            };
            let record_cap = if max_segments == 0 {
                0
            } else {
                max_segments.saturating_mul(MUTATION_LOG_SEGMENT_MAX_RECORDS)
            };
            self.read_pending_pin_log_records_paged(
                &target,
                &is_pending,
                record_cap,
                self.config.max_upload_bytes_per_cycle,
                pin_log_scan_row_budget(),
            )
            .await?
        };
        if page.row_budget_exhausted {
            tracing::warn!(
                target: "fold_db::sync::mutation_log",
                target_id = %target_id,
                rows_scanned = page.rows_scanned,
                pending_found = page.records.len(),
                "pin-log scan hit its per-cycle row budget before filling the batch; \
                 the front of the log is a long run of already-published records whose \
                 truncation delete did not land — set LASTDB_PIN_LOG_SCAN_ROW_BUDGET higher \
                 to walk further per cycle"
            );
        }
        // A prior cloud publish can succeed while its best-effort local delete
        // fails. Those rows are no longer pending, so retry their exact deletes
        // while the bounded scan has them in hand. Without this retry they stay
        // at the front of the log forever and every cycle pays to skip them.
        // LocalPlaneForTests frontiers are not cloud confirmation and must never
        // authorize deletion.
        let retry_confirmed = page.not_pending_frontiers.clone();
        // Quarantine drops are deliberately NOT added here. `records_truncated`
        // is documented as "records deleted this cycle because cloud confirmed
        // them", and a quarantined record is the one thing cloud never saw.
        // Its count is `records_quarantined`.
        let retried_truncations = if matches!(publish, MutationLogPublish::Cloud) {
            self.truncate_confirmed_pin_log_records(&target_id, &retry_confirmed)
                .await
        } else {
            0
        };
        // `(frontier, seal error)`. The error carries the missing atom id and
        // field name, and is the only surviving description of the hole once
        // the durable row is gone — so it is tombstoned with the frontier, not
        // collapsed into a single `last_reason`.
        let mut quarantined: Vec<(u64, String)> = Vec::new();
        let mut last_quarantine_reason = None;
        let mut batch = Vec::with_capacity(page.records.len());
        for mut record in page.records {
            if let crate::sync::log::LogOp::MutationIntent { mutations } = &mut record.entry.op {
                match engine
                    .materialize_mutation_intent(std::mem::take(mutations))
                    .await
                {
                    Ok(ready) => *mutations = ready,
                    Err(err) if crate::sync::mutation_intent::pin_log_record_cannot_seal(&err) => {
                        tracing::warn!(
                            target: "fold_db::sync::mutation_log",
                            target_prefix = %target_prefix,
                            writer_id = %record.writer_id,
                            frontier_after = record.frontier_after,
                            error = %err,
                            "quarantined unsealable MutationIntent (missing atom); later records still upload"
                        );
                        last_quarantine_reason = Some(err.clone());
                        quarantined.push((record.frontier_after, err));
                        continue;
                    }
                    Err(err) => return Err(err),
                }
            }
            batch.push(record);
        }
        let records_quarantined = quarantined.len();
        let page_record_count = batch.len();
        if records_quarantined > 0 {
            let mut state = self.state.lock().await;
            if let Some(runtime) = state.get_mut(&target_id) {
                runtime.records_quarantined = runtime
                    .records_quarantined
                    .saturating_add(records_quarantined as u64);
                runtime.last_quarantine_reason = last_quarantine_reason.clone();
            }
        }
        if matches!(publish, MutationLogPublish::Cloud) && !quarantined.is_empty() {
            self.drop_unsealable_pin_log_records(engine, &target_id, target_prefix, &quarantined)
                .await;
        }

        // Build request-sized objects, preserving writer boundaries. Flush at
        // 1,000 records or 4 MiB of plaintext, whichever comes first. A single
        // oversized record is still emitted alone so it cannot wedge the
        // frontier forever.
        let segment_byte_target = if self.config.max_upload_bytes_per_cycle == 0 {
            MUTATION_LOG_SEGMENT_TARGET_BYTES
        } else {
            MUTATION_LOG_SEGMENT_TARGET_BYTES.min(self.config.max_upload_bytes_per_cycle)
        };
        let mut record_batches: Vec<Vec<PinLogRecord>> = Vec::new();
        let mut current: Vec<PinLogRecord> = Vec::new();
        let mut current_json_bytes = 2usize; // `[]`
        for record in batch {
            let record_stream = mutation_log_record_stream(&record)?;
            if matches!(record_stream, MutationLogRecordStream::MultiSchema) {
                if !current.is_empty() {
                    record_batches.push(std::mem::take(&mut current));
                    current_json_bytes = 2;
                    if max_segments > 0 && record_batches.len() >= max_segments {
                        break;
                    }
                }
                record_batches.push(vec![record]);
                if max_segments > 0 && record_batches.len() >= max_segments {
                    break;
                }
                continue;
            }
            let encoded_len = serde_json::to_vec(&record)
                .map_err(|e| format!("size mutation log record for batching: {e}"))?
                .len();
            let record_writer = if record.writer_id.is_empty() {
                "unknown-writer"
            } else {
                record.writer_id.as_str()
            };
            let current_writer = current.first().map(|first| {
                if first.writer_id.is_empty() {
                    "unknown-writer"
                } else {
                    first.writer_id.as_str()
                }
            });
            let current_stream = current
                .first()
                .map(mutation_log_record_stream)
                .transpose()?;
            let added_bytes = encoded_len + usize::from(!current.is_empty());
            let must_flush = !current.is_empty()
                && (current_writer != Some(record_writer)
                    || current_stream.as_ref() != Some(&record_stream)
                    || current.len() >= MUTATION_LOG_SEGMENT_MAX_RECORDS
                    || current_json_bytes.saturating_add(added_bytes) > segment_byte_target);
            if must_flush {
                record_batches.push(std::mem::take(&mut current));
                current_json_bytes = 2;
                if max_segments > 0 && record_batches.len() >= max_segments {
                    break;
                }
            }
            current_json_bytes =
                current_json_bytes.saturating_add(encoded_len + usize::from(!current.is_empty()));
            current.push(record);
        }
        if !current.is_empty() && (max_segments == 0 || record_batches.len() < max_segments) {
            record_batches.push(current);
        }
        let records_selected: usize = record_batches.iter().map(Vec::len).sum();

        let mut report = MutationLogUploadReport {
            target_id: target_id.clone(),
            writer_id: String::new(),
            records_considered: records_selected,
            segments_uploaded: 0,
            bytes_uploaded: 0,
            published_frontier_before: published_before_max,
            published_frontier_after: published_before_max,
            upload_backlog_after: 0,
            object_keys: Vec::new(),
            records_truncated: retried_truncations,
            records_quarantined,
            last_quarantine_reason: last_quarantine_reason.clone(),
            rows_scanned: page.rows_scanned,
            records_considered_is_lower_bound: !page.scan_complete
                || records_selected < page_record_count,
            scan_row_budget_exhausted: page.row_budget_exhausted,
        };

        // Seal first, then publish to cloud, and only then advance F.
        //
        // Ordering is the whole point. This loop used to seal a record, insert
        // it into `plane` (an in-process HashMap) and immediately advance the
        // published frontier — so `segments_uploaded` and F both moved on a
        // local map write while **nothing left the machine**. On the primary
        // that read as 236 "uploads" against 0 `log/` objects in R2, with lag
        // growing ~1 s/s forever because the frontier was advancing over
        // records that were never durable off-box.
        //
        // A durability counter must be sourced from a cloud-side confirmation,
        // never a local write. If the upload fails we advance nothing, keep the
        // records pending, and let the next cycle retry — local R/W is never
        // blocked either way.
        let mut sealed_units: Vec<Vec<MutationLogSegment>> =
            Vec::with_capacity(record_batches.len());
        let mut confirmed_frontiers = Vec::with_capacity(records_selected);
        for records in &record_batches {
            // Keep first writer_id for the single-field report; plane + runtime
            // still track every writer (typical multi-device = one writer/process).
            if report.writer_id.is_empty() {
                report.writer_id = records[0].writer_id.clone();
            }
            confirmed_frontiers.extend(records.iter().map(|record| record.frontier_after));
            // Seal with the *target* crypto provider. Personal uses
            // engine.crypto (same as target.crypto for index 0); org/share
            // destinations must not be sealed under the personal key or peers
            // with only the scoped E2E key cannot open the segment.
            sealed_units.push(seal_mutation_log_publish_unit(records, &target.crypto).await?);
        }

        // writer_id → (through, record timestamp) confirmed this cycle.
        let mut advanced: HashMap<String, (u64, u64)> = HashMap::new();
        if !sealed_units.is_empty() {
            let bytes_uploaded = match publish {
                MutationLogPublish::Cloud => {
                    let mut uploaded = 0u64;
                    for unit in &sealed_units {
                        let manifest_last = unit.len() > 1
                            && unit.last().is_some_and(|object| {
                                object.segment.schema_name.as_deref()
                                    == Some(TRANSACTION_GROUP_MANIFEST_SCHEMA)
                            });
                        if manifest_last {
                            uploaded = uploaded.saturating_add(
                                engine
                                    .upload_mutation_log_segments(&target, &unit[..unit.len() - 1])
                                    .await
                                    .map_err(|e| {
                                        format!("mutation-log group shard upload failed: {e}")
                                    })?,
                            );
                            uploaded = uploaded.saturating_add(
                                engine
                                    .upload_mutation_log_segments(&target, &unit[unit.len() - 1..])
                                    .await
                                    .map_err(|e| {
                                        format!("mutation-log group manifest upload failed: {e}")
                                    })?,
                            );
                        } else {
                            uploaded = uploaded.saturating_add(
                                engine
                                    .upload_mutation_log_segments(&target, unit)
                                    .await
                                    .map_err(|e| {
                                        format!("mutation-log segment upload failed: {e}")
                                    })?,
                            );
                        }
                    }
                    uploaded
                }
                MutationLogPublish::LocalPlaneForTests => sealed_units
                    .iter()
                    .flatten()
                    .map(|s| s.payload.len() as u64)
                    .sum(),
            };

            for (unit, records) in sealed_units.iter().zip(&record_batches) {
                let last = records.last().ok_or_else(|| {
                    "sealed mutation-log unit lost its source records".to_string()
                })?;
                let wid = if last.writer_id.is_empty() {
                    "unknown-writer".to_string()
                } else {
                    last.writer_id.clone()
                };
                let published_at_ms = records.last().map_or(0, |record| record.timestamp_ms);
                let e = advanced.entry(wid).or_insert((0, 0));
                if last.frontier_after >= e.0 {
                    *e = (last.frontier_after, published_at_ms);
                }
                report.segments_uploaded = report.segments_uploaded.saturating_add(unit.len());
            }
            report.bytes_uploaded = report.bytes_uploaded.saturating_add(bytes_uploaded);

            // The cloud PUT is not yet a crash-safe confirmation. First
            // max-merge and flush the per-writer HWM. If this fails, return an
            // error without advancing any volatile frontier or deleting a row;
            // the next cycle safely uploads the same cloud object again.
            if matches!(publish, MutationLogPublish::Cloud) {
                let confirmed = advanced
                    .iter()
                    .map(|(writer_id, (through, _))| (writer_id.clone(), *through))
                    .collect::<BTreeMap<_, _>>();
                self.persist_published_f(&target_id, &confirmed).await?;
            }

            // Local mirror is geometry/bookkeeping only. Update it only after
            // the durable Cloud HWM exists, so a failed HWM flush cannot make a
            // later cycle suppress an unconfirmed local row.
            for (unit, records) in sealed_units.iter().zip(&record_batches) {
                for sealed in unit {
                    plane.put_segment(sealed)?;
                    report.object_keys.push(sealed.segment.object_key.clone());
                }
                let last = records.last().ok_or_else(|| {
                    "sealed mutation-log unit lost its source records".to_string()
                })?;
                let writer_id = if last.writer_id.is_empty() {
                    "unknown-writer"
                } else {
                    last.writer_id.as_str()
                };
                plane.advance_published_f(writer_id, last.frontier_after);
            }

            // Only the flushed HWM above authorizes deletion. Drop exact rows,
            // never a range. LocalPlaneForTests keeps every record because it
            // provides no off-box confirmation.
            if matches!(publish, MutationLogPublish::Cloud) {
                report.records_truncated = report.records_truncated.saturating_add(
                    self.truncate_confirmed_pin_log_records(&target_id, &confirmed_frontiers)
                        .await,
                );
            }
        }

        if report.segments_uploaded > 0 {
            {
                let mut state = self.state.lock().await;
                if let Some(runtime) = state.get_mut(&target_id) {
                    for (wid, (through, published_at_ms)) in &advanced {
                        // Only the production cloud path may advance RPO. The
                        // local plane is a geometry test double, not durability.
                        if matches!(publish, MutationLogPublish::Cloud) {
                            runtime.advance_published_f(wid, *through, *published_at_ms);
                        } else {
                            let entry = runtime
                                .published_f_by_writer
                                .entry(wid.clone())
                                .or_insert(0);
                            *entry = (*entry).max(*through);
                            runtime.published_frontier = runtime.published_frontier.max(*through);
                        }
                    }
                    runtime.segments_uploaded = runtime
                        .segments_uploaded
                        .saturating_add(report.segments_uploaded as u64);
                    report.published_frontier_after = runtime.published_frontier;
                    report.upload_backlog_after = runtime
                        .last_durable_frontier
                        .saturating_sub(runtime.published_frontier);
                } else {
                    report.published_frontier_after = advanced
                        .values()
                        .map(|(through, _)| *through)
                        .max()
                        .unwrap_or(0);
                }
            }
            // Vector F geometry is recorded on plane/runtime maps; status still
            // surfaces scalar max. Log writer count so multi-writer cycles are
            // visible without constructing an unused Frontier value.
            tracing::info!(
                target: "fold_db::sync::mutation_log",
                target_id = %target_id,
                writer_id = %report.writer_id,
                writers = advanced.len(),
                segments = report.segments_uploaded,
                bytes = report.bytes_uploaded,
                published_f = report.published_frontier_after,
                backlog = report.upload_backlog_after,
                "continuous mutation-log segment upload cycle"
            );
        } else {
            let state = self.state.lock().await;
            if let Some(runtime) = state.get(&target_id) {
                report.published_frontier_after = runtime.published_frontier;
                report.upload_backlog_after = runtime
                    .last_durable_frontier
                    .saturating_sub(runtime.published_frontier);
            }
        }
        Ok(report)
    }

    /// Return the frozen sealed-base membership S_T for a target, if any.
    #[cfg(test)]
    pub async fn sealed_base_for_target(
        &self,
        target_prefix: &str,
    ) -> Result<Vec<SealedBaseMember>, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let state = self.state.lock().await;
        let runtime = state
            .get(&target_id)
            .ok_or_else(|| format!("pin log target '{}' is not active", target.label))?;
        Ok(runtime.sealed_base.clone())
    }

    /// Hard write-path guard: refuse rewriting a frozen sealed-base member while
    /// any pin is active for that member. Increments `s_rewrite_attempts` and
    /// returns `Err` so callers cannot rewrite S mid-pin.
    #[cfg(test)]
    pub async fn guard_sealed_base_write(&self, path_or_sha: &str) -> Result<(), String> {
        let mut state = self.state.lock().await;
        let mut hit_target: Option<String> = None;
        for runtime in state.values_mut() {
            // Freeze guards only apply under pin-mode freeze, not continuous capture.
            if !runtime.pin_freeze {
                continue;
            }
            if runtime.sealed_base_contains(path_or_sha) {
                runtime.s_rewrite_attempts = runtime.s_rewrite_attempts.saturating_add(1);
                hit_target = Some(runtime.target_id.clone());
                break;
            }
        }
        if let Some(target_id) = hit_target {
            return Err(format!(
                "pin-mode sealed base refuse: cannot rewrite member '{path_or_sha}' while pin active on target {target_id}"
            ));
        }
        Ok(())
    }

    /// Product write-path entry for reseal/rewrite of a sealed chunk path or digest.
    ///
    /// Guard-only: refuses when `path_or_sha` is in any active pin's frozen S.
    /// `new_bytes` is accepted for the product call shape (caller supplies the
    /// intended payload) but is **not** persisted here — the caller writes after
    /// this returns `Ok(())`.
    #[cfg(test)]
    pub async fn attempt_sealed_base_member_rewrite(
        &self,
        path_or_sha: &str,
        _new_bytes: &[u8],
    ) -> Result<(), String> {
        self.guard_sealed_base_write(path_or_sha).await?;
        Ok(())
    }

    /// Target-scoped rewrite attempt. Returns Err when the member is in S
    /// (fail-closed write path), Ok(false) when not a member.
    #[cfg(test)]
    pub async fn note_sealed_base_rewrite_attempt(
        &self,
        target_prefix: &str,
        path_or_sha: &str,
    ) -> Result<bool, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let mut state = self.state.lock().await;
        let runtime = state
            .get_mut(&target_id)
            .ok_or_else(|| format!("pin log target '{}' is not active", target.label))?;
        if !runtime.pin_freeze {
            return Ok(false);
        }
        if runtime.sealed_base_contains(path_or_sha) {
            runtime.s_rewrite_attempts = runtime.s_rewrite_attempts.saturating_add(1);
            return Err(format!(
                "pin-mode sealed base refuse: cannot rewrite member '{path_or_sha}' while pin active on target {}",
                runtime.target_id
            ));
        }
        Ok(false)
    }

    /// Verify frozen members still match their recorded (sha256, len) identity.
    #[cfg(test)]
    pub async fn check_sealed_base_integrity(
        &self,
        target_prefix: &str,
        observed: &[(String, String, u64)],
    ) -> Result<Vec<SealedBaseMember>, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let mut state = self.state.lock().await;
        let runtime = state
            .get_mut(&target_id)
            .ok_or_else(|| format!("pin log target '{}' is not active", target.label))?;
        let mut broken = Vec::new();
        for member in &runtime.sealed_base {
            let Some((_, sha, len)) = observed
                .iter()
                .find(|(path, _, _)| PinLogRuntime::observed_path_matches_member(path, member))
            else {
                // Fully missing from observed is the worst-case integrity miss.
                broken.push(member.clone());
                continue;
            };
            if sha != &member.sha256 || *len != member.len {
                broken.push(member.clone());
            }
        }
        if !broken.is_empty() {
            runtime.s_rewrite_attempts = runtime
                .s_rewrite_attempts
                .saturating_add(broken.len() as u64);
        }
        Ok(broken)
    }

    /// Build a catch-up publish descriptor for this target (base S + log range).
    #[cfg(test)]
    pub async fn build_pin_mode_publish_descriptor(
        &self,
        target_prefix: &str,
        publish_counter: u64,
    ) -> Result<PinModePublishDescriptor, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let state = self.state.lock().await;
        let runtime = state
            .get(&target_id)
            .ok_or_else(|| format!("pin log target '{}' is not active", target.label))?;
        if !runtime.pin_freeze {
            return Err(format!(
                "pin mode for '{}' is not active; cannot publish catch-up",
                target.label
            ));
        }
        let mut sealed_base_shas: Vec<String> = runtime
            .sealed_base
            .iter()
            .map(|m| m.sha256.clone())
            .collect();
        sealed_base_shas.sort();
        sealed_base_shas.dedup();
        Ok(PinModePublishDescriptor {
            target_id: runtime.target_id.clone(),
            target_prefix: runtime.target_prefix.clone(),
            base_frontier: runtime.base_frontier,
            log_from: runtime.base_frontier,
            last_durable_frontier: runtime.last_durable_frontier,
            sealed_base_shas,
            publish_counter,
            base_may_be_fuzzy: true,
        })
    }

    /// Catch-up upload of frozen base S + durable pin log, then CAS `latest`
    /// on the given local cloud plane (stand-in for S3/CAS under the target prefix).
    #[cfg(test)]
    pub async fn publish_pin_mode_catchup(
        &self,
        target_prefix: &str,
        plane: &mut PinModeLocalCloud,
        sealed_payloads: &[(String, Vec<u8>)],
        publish_counter: u64,
    ) -> Result<PinModePublishDescriptor, String> {
        let desc = self
            .build_pin_mode_publish_descriptor(target_prefix, publish_counter)
            .await?;
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let records = self
            .read_pin_log_records_for_target_after(&target, Some(desc.log_from))
            .await?;
        let payload_map: std::collections::HashMap<&str, &[u8]> = sealed_payloads
            .iter()
            .map(|(s, b)| (s.as_str(), b.as_slice()))
            .collect();
        let mut objects = std::collections::HashMap::new();
        for sha in &desc.sealed_base_shas {
            let bytes = payload_map.get(sha.as_str()).ok_or_else(|| {
                format!("catch-up missing sealed base object payload for sha {sha}")
            })?;
            objects.insert(sha.clone(), bytes.to_vec());
        }
        plane.upload_base_and_log(&desc, objects, records)?;
        plane.cas_latest(&desc)?;
        let mut state = self.state.lock().await;
        if let Some(runtime) = state.get_mut(&desc.target_id) {
            runtime.last_publish = Some(desc.clone());
            runtime.materialize_pending = true;
        }
        Ok(desc)
    }

    /// Background materialize: apply durable pin log into the local store, then
    /// clear `materialize_pending`.
    #[cfg(test)]
    pub async fn materialize_pin_log_for_target(
        &self,
        engine: &SyncEngine,
        target_prefix: &str,
    ) -> Result<PinLogTargetStatus, String> {
        let n = self
            .replay_pin_log_for_target(engine, target_prefix)
            .await
            .map_err(|e| e.to_string())?;
        let target = self.sync_target_by_prefix(target_prefix).await?;
        let target_id = target_id_for_prefix(&target.prefix);
        let mut state = self.state.lock().await;
        let runtime = state
            .get_mut(&target_id)
            .ok_or_else(|| format!("pin log target '{}' is not active", target.label))?;
        runtime.materialize_pending = false;
        tracing::info!(
            target: "fold_db::sync::pin_log",
            target_id = %runtime.target_id,
            replayed = n,
            "pin-mode background materialize complete"
        );
        Ok(runtime.status())
    }

    /// Restore a **fresh** home from a published pin-mode plane.
    ///
    /// - `include_log = false`: install sealed base objects only (no log apply).
    /// - `include_log = true`: install base + persist log + replay into this store.
    #[cfg(test)]
    pub async fn restore_pin_mode_from_local_cloud(
        &self,
        engine: &SyncEngine,
        plane: &PinModeLocalCloud,
        target_id: &str,
        include_log: bool,
    ) -> Result<PinModeRestoreReport, String> {
        let published = plane
            .get(target_id)
            .ok_or_else(|| format!("no published pin for target {target_id}"))?;
        let base_objects = published.sealed_objects.len();
        let log_entries = published.log.len();
        let restore_ns = self
            .store
            .open_namespace("pin_restore_base")
            .await
            .map_err(|e| format!("open pin_restore_base: {e}"))?;
        for (sha, bytes) in &published.sealed_objects {
            restore_ns
                .put(sha.as_bytes(), bytes.clone())
                .await
                .map_err(|e| format!("install sealed base object: {e}"))?;
        }
        // Durability boundary for the sealed-base-object namespace (mirrors the
        // pin-log-record restore path below). Without this, a crash right after
        // Ok(...) can drop the just-restored base objects.
        restore_ns
            .flush()
            .await
            .map_err(|e| format!("flush restored sealed base objects: {e}"))?;
        let mut app_keys_restored = 0usize;
        if include_log {
            let items: Vec<(Vec<u8>, Vec<u8>)> = published
                .log
                .iter()
                .map(|record| {
                    let key = pin_log_entry_key(&record.target_id, record.frontier_after);
                    let val = serde_json::to_vec(record)
                        .map_err(|e| format!("encode restore pin log: {e}"))?;
                    Ok((key, val))
                })
                .collect::<Result<Vec<_>, String>>()?;
            let pin_store = self.pin_log_store().await?;
            pin_store
                .batch_put(items)
                .await
                .map_err(|e| format!("persist restored pin log: {e}"))?;
            pin_store
                .flush()
                .await
                .map_err(|e| format!("flush restored pin log: {e}"))?;
            let prefix = published.desc.target_prefix.as_str();
            let n = self
                .replay_pin_log_for_target(engine, prefix)
                .await
                .map_err(|e| e.to_string())?;
            app_keys_restored = n;
        }
        Ok(PinModeRestoreReport {
            target_id: target_id.to_string(),
            include_log,
            base_objects,
            log_entries,
            app_keys_restored,
            latest_counter: published.desc.publish_counter,
        })
    }

    pub async fn pin_log_statuses(&self) -> Vec<PinLogTargetStatus> {
        let mut statuses: Vec<_> = self
            .state
            .lock()
            .await
            .values()
            .map(PinLogRuntime::status)
            .collect();
        statuses.sort_by(|a, b| a.target_id.cmp(&b.target_id));
        statuses
    }

    /// Incorporated vector F for peer mutation-log apply.
    ///
    /// Merges in-memory `published_f_by_writer` with the durable map so a
    /// restart still covers already-uploaded (and already-applied) writers.
    /// A missing writer is not covered — that is what lets a second Mini
    /// fetch `log/{peer}/{F}.enc`. Scalar F must not be used here: it would
    /// skip a peer stream whose through_id is <= this node's published max.
    pub(crate) async fn incorporated_frontier(&self) -> Frontier {
        let mut by_writer = BTreeMap::new();
        let target_ids = {
            let state = self.state.lock().await;
            for runtime in state.values() {
                for (writer, through) in &runtime.published_f_by_writer {
                    let entry = by_writer.entry(writer.clone()).or_insert(0);
                    *entry = (*entry).max(*through);
                }
            }
            let mut ids: Vec<String> = state.keys().cloned().collect();
            if !ids.iter().any(|id| id == "personal") {
                ids.push("personal".to_string());
            }
            ids
        };
        for target_id in target_ids {
            for (writer, through) in self.read_published_f(&target_id).await {
                let entry = by_writer.entry(writer).or_insert(0);
                *entry = (*entry).max(through);
            }
        }
        Frontier::from_writer_hwm(by_writer)
    }

    /// Max-merge applied peer HWMs into published F so the next cycle does
    /// not re-download those writer-scoped objects. Does not lower any writer.
    pub(crate) async fn incorporate_applied_frontier(
        &self,
        applied: &BTreeMap<String, u64>,
    ) -> Result<(), String> {
        if applied.is_empty() {
            return Ok(());
        }
        let published_at_ms = now_millis();
        let target_id = "personal";
        // A waiter reads the runtime map. Persist the max-merged HWM first so
        // peer apply cannot satisfy an exact receipt from volatile state that
        // disappears after a failed flush.
        self.persist_published_f(target_id, applied).await?;
        {
            let mut state = self.state.lock().await;
            if let Some(runtime) = state.get_mut(target_id) {
                for (writer, through) in applied {
                    runtime.advance_published_f(writer, *through, published_at_ms);
                }
            }
        }
        Ok(())
    }

    #[cfg(test)]
    pub async fn pin_log_records_for_target(
        &self,
        target_prefix: &str,
    ) -> Result<Vec<PinLogRecord>, String> {
        let target = self.sync_target_by_prefix(target_prefix).await?;
        self.read_pin_log_records_for_target(&target).await
    }

    /// Replay the target's durable pin log in order. A corrupt final row is
    /// treated as an interrupted trailing append and ignored; a corrupt row with
    /// later records is not safe to skip and returns an error.
    #[cfg(test)]
    pub async fn replay_pin_log_for_target(
        &self,
        engine: &SyncEngine,
        target_prefix: &str,
    ) -> SyncResult<usize> {
        let target = self
            .sync_target_by_prefix(target_prefix)
            .await
            .map_err(SyncError::Storage)?;
        let target_id = target_id_for_prefix(&target.prefix);
        let materialized_frontier = self
            .read_materialized_frontier(&target_id)
            .await
            .map_err(SyncError::Storage)?;
        let records = self
            .read_pin_log_records_for_target_after(&target, materialized_frontier)
            .await
            .map_err(SyncError::Storage)?;
        let replay_target = (!target.prefix.is_empty()).then_some(&target);
        for record in &records {
            engine.replay_entry(&record.entry, replay_target).await?;
        }
        if let Some(frontier) = records.iter().map(|record| record.frontier_after).max() {
            self.persist_materialized_frontier(&target_id, frontier)
                .await
                .map_err(SyncError::Storage)?;
        }
        Ok(records.len())
    }

    pub(crate) async fn append_entry_to_active_pin_logs(
        &self,
        entry: &LogEntry,
        targets: &[SyncTarget],
        partitioner: &Option<SyncPartitioner>,
    ) -> Result<Vec<MutationLogTargetPosition>, String> {
        let mutation_log = matches!(self.config.capture_mode, CaptureMode::MutationLog);
        let active_ids: std::collections::HashSet<String> = {
            let state = self.state.lock().await;
            state
                .values()
                .filter(|runtime| runtime.active)
                .map(|runtime| runtime.target_id.clone())
                .collect()
        };
        if active_ids.is_empty() {
            // Pin-mode: nothing frozen → no-op. MutationLog continuous plane
            // must never claim success with zero active runtimes after ensure.
            if mutation_log {
                return Err(
                    "mutation-log capture has no active continuous target runtimes".to_string(),
                );
            }
            return Ok(Vec::new());
        }

        let partitioned = SyncEngine::partition_entry(partitioner, entry, targets)
            .map_err(|e| format!("partition pin log entry: {e}"))?;
        let mut records = Vec::new();
        for (target_idx, sub_entry) in partitioned {
            let Some(target) = targets.get(target_idx) else {
                return Err(format!("pin log target index {target_idx} is out of range"));
            };
            let target_id = target_id_for_prefix(&target.prefix);
            if !active_ids.contains(&target_id) {
                // Pin-mode intentionally freezes a subset of targets and may
                // drop partitions for inactive ones. Continuous MutationLog
                // must not silently hole scoped destinations: ensure already
                // activated every configured target, so an inactive hit is a
                // real defect — fail closed.
                if mutation_log {
                    return Err(format!(
                        "mutation-log capture dropped inactive target_id={target_id} \
                         prefix='{}' label='{}' (configured destination without continuous runtime)",
                        target.prefix, target.label
                    ));
                }
                continue;
            }
            records.push(PinLogRecord {
                model_version: PIN_LOG_MODEL_VERSION,
                target_id,
                target_label: target.label.clone(),
                target_prefix: target.prefix.clone(),
                writer_id: sub_entry.device_id.clone(),
                frontier_after: sub_entry.seq,
                timestamp_ms: sub_entry.timestamp_ms,
                entry: sub_entry,
            });
        }

        if records.is_empty() {
            return Ok(Vec::new());
        }
        let positions = records
            .iter()
            .map(|record| MutationLogTargetPosition {
                target_id: record.target_id.clone(),
                target_label: record.target_label.clone(),
                writer_id: record.writer_id.clone(),
                frontier: record.frontier_after,
            })
            .collect();
        self.persist_pin_log_records(&records).await?;
        Ok(positions)
    }

    async fn persist_pin_log_records(&self, records: &[PinLogRecord]) -> Result<(), String> {
        let _append = self.append_lock.lock().await;
        let store = self.pin_log_store().await?;
        let mut items = Vec::with_capacity(records.len() + usize::from(!records.is_empty()));
        if let Some(mut frontier) = records.iter().map(|record| record.frontier_after).max() {
            if let Some(raw) = store
                .get(PIN_LOG_APPENDED_F_KEY)
                .await
                .map_err(|e| format!("read durable pin-log allocation floor: {e}"))?
            {
                let bytes: [u8; 8] = raw.try_into().map_err(|raw: Vec<u8>| {
                    format!(
                        "decode durable pin-log allocation floor: expected 8 bytes, got {}",
                        raw.len()
                    )
                })?;
                frontier = frontier.max(u64::from_be_bytes(bytes));
            }
            items.push((
                PIN_LOG_APPENDED_F_KEY.to_vec(),
                frontier.to_be_bytes().to_vec(),
            ));
        }
        let mut stats = Vec::with_capacity(records.len());
        for record in records {
            let bytes = serde_json::to_vec(record)
                .map_err(|e| format!("encode durable pin log entry: {e}"))?;
            stats.push((
                record.target_id.clone(),
                record.target_label.clone(),
                record.target_prefix.clone(),
                record.frontier_after,
                record.timestamp_ms,
                bytes.len() as u64,
            ));
            items.push((
                pin_log_entry_key(&record.target_id, record.frontier_after),
                bytes,
            ));
        }
        store
            .batch_put(items)
            .await
            .map_err(|e| format!("persist durable pin log entries: {e}"))?;
        // Group-commit durability boundary: one flush after the batch, never a
        // per-record flush.
        store
            .flush()
            .await
            .map_err(|e| format!("flush durable pin log group: {e}"))?;

        let mut state = self.state.lock().await;
        for (target_id, target_label, target_prefix, frontier, ts, bytes) in stats {
            let runtime = state.entry(target_id.clone()).or_insert_with(|| {
                PinLogRuntime::new(
                    target_id,
                    target_label.clone(),
                    target_prefix.clone(),
                    0,
                    0,
                    false,
                )
            });
            runtime.target_label = target_label;
            runtime.target_prefix = target_prefix;
            runtime.last_durable_frontier = runtime.last_durable_frontier.max(frontier);
            runtime.entry_count += 1;
            runtime.byte_count += bytes;
            runtime.last_durable_at_ms = Some(ts);
        }
        Ok(())
    }

    /// Read **at most `want`** pending pin-log records for `target`, paging the
    /// durable scan so the plane's size never becomes the cycle's memory cost.
    ///
    /// # Why this exists
    ///
    /// [`Self::read_pin_log_records_for_target`] materialises the whole target
    /// prefix — every key *and every value* — before anything filters it. The
    /// upload cycle then applied its `max_segments` cap to the decoded result,
    /// so the cap bounded how much the cycle *published* and bounded nothing
    /// about what it *read*.
    ///
    /// On Tom's primary the `sync_pin_log` plane reached **12.33 GiB** (capture
    /// on, publish failing, so nothing was ever truncated). Every boot with
    /// `cloud_sync.json` present therefore drove RSS from 0 to 13–15 GiB inside
    /// ~3 minutes and the memory guard SIGKILLed the daemon — three consecutive
    /// cycles on 2026-08-08, after which cloud sync was switched off and the
    /// brain was left with no off-machine backup at all.
    ///
    /// This is the same defect [`KvStore::scan_prefix_keys`] was added for in
    /// 2026-07: `outbox_meta` called `scan_prefix` and pinned every outbox
    /// payload in RAM. That fix landed one caller; this is the other one.
    ///
    /// # Bounds
    ///
    /// Memory is `O(page × record size)`, independent of the plane. Time is
    /// bounded by `row_budget`: a long run of already-published-but-not-yet-
    /// deleted records at the front of the log cannot make one cycle walk the
    /// whole plane. Stopping early is reported, never inferred — see
    /// [`PendingPinLogPage::scan_complete`].
    ///
    /// `want == 0` means "no batch cap" (the test/local-plane callers): the
    /// scan still pages, so the double buffering of raw rows plus decoded
    /// records is gone there too.
    async fn read_pending_pin_log_records_paged(
        &self,
        target: &SyncTarget,
        // `Sync` so the returned future stays `Send` — this runs inside the
        // spawned sync-coordinator task.
        is_pending: &(dyn Fn(&PinLogRecord) -> bool + Sync),
        want: usize,
        pending_byte_budget: usize,
        row_budget: usize,
    ) -> Result<PendingPinLogPage, String> {
        let target_id = target_id_for_prefix(&target.prefix);
        let prefix = pin_log_target_prefix(&target_id).into_bytes();
        let end = prefix_upper_bound(&prefix).ok_or_else(|| {
            format!(
                "pin log prefix {} has no finite range upper bound",
                String::from_utf8_lossy(&prefix)
            )
        })?;
        let store = self.pin_log_store().await?;
        let page_size = pin_log_scan_page_size();
        let want = if want == 0 { usize::MAX } else { want };

        let mut page = PendingPinLogPage {
            records: Vec::new(),
            not_pending_frontiers: Vec::new(),
            rows_scanned: 0,
            scan_complete: true,
            row_budget_exhausted: false,
        };
        let mut cursor = prefix.clone();
        let mut pending_bytes = 0usize;

        loop {
            let rows = store
                .scan_range_paged(&cursor, &end, page_size)
                .await
                .map_err(|e| format!("scan durable pin log: {e}"))?;
            if rows.is_empty() {
                return Ok(page);
            }
            // A short page means the range is exhausted, which is also the only
            // situation in which a decode failure is a legitimately truncated
            // trailing append rather than corruption with live records behind it.
            let final_page = rows.len() < page_size;
            let last_idx = rows.len() - 1;
            let mut next_cursor = None;

            for (idx, (key, value)) in rows.into_iter().enumerate() {
                page.rows_scanned += 1;
                next_cursor = Some(key_after(&key));
                match serde_json::from_slice::<PinLogRecord>(&value) {
                    Ok(record) => {
                        if is_pending(&record) {
                            if pending_byte_budget > 0
                                && pending_bytes > 0
                                && pending_bytes.saturating_add(value.len()) > pending_byte_budget
                            {
                                page.scan_complete = false;
                                return Ok(page);
                            }
                            pending_bytes = pending_bytes.saturating_add(value.len());
                            page.records.push(record);
                            if page.records.len() >= want {
                                page.scan_complete = false;
                                return Ok(page);
                            }
                        } else {
                            page.not_pending_frontiers.push(record.frontier_after);
                        }
                    }
                    Err(e) if final_page && idx == last_idx => {
                        tracing::warn!(
                            target: "fold_db::sync::pin_log",
                            key = %String::from_utf8_lossy(&key),
                            error = %e,
                            "ignoring corrupt trailing durable pin log record"
                        );
                    }
                    Err(e) => {
                        return Err(format!(
                            "decode durable pin log record {}: {e}",
                            String::from_utf8_lossy(&key)
                        ));
                    }
                }
                if page.rows_scanned >= row_budget {
                    page.scan_complete = false;
                    page.row_budget_exhausted = true;
                    return Ok(page);
                }
            }

            if final_page {
                return Ok(page);
            }
            match next_cursor {
                Some(next) => cursor = next,
                // Defensive: a non-final page always sets the cursor. Returning
                // here rather than looping keeps a backend that violated the
                // ordering contract from spinning forever on the same page.
                None => return Ok(page),
            }
        }
    }

    /// Read **every** record for a target into memory.
    ///
    /// Cost is `O(plane)` in both time and RAM. Use
    /// [`Self::read_pending_pin_log_records_paged`] on any path that runs on a
    /// timer; this one is for bounded, one-shot uses (replay, explicit
    /// inspection) where the caller genuinely needs the whole log.
    #[cfg(test)]
    async fn read_pin_log_records_for_target(
        &self,
        target: &SyncTarget,
    ) -> Result<Vec<PinLogRecord>, String> {
        self.read_pin_log_records_for_target_after(target, None)
            .await
    }

    /// Read records strictly newer than `after_frontier`, or the complete
    /// target log when no lower bound is supplied.
    ///
    /// Materialize/replay and pin-mode catch-up use the bounded form so their
    /// cost is proportional to new work rather than the lifetime log size.
    #[cfg(test)]
    async fn read_pin_log_records_for_target_after(
        &self,
        target: &SyncTarget,
        after_frontier: Option<u64>,
    ) -> Result<Vec<PinLogRecord>, String> {
        let target_id = target_id_for_prefix(&target.prefix);
        let store = self.pin_log_store().await?;
        let rows = match after_frontier {
            Some(u64::MAX) => Vec::new(),
            Some(frontier) => {
                let prefix = pin_log_target_prefix(&target_id).into_bytes();
                let end = prefix_upper_bound(&prefix).ok_or_else(|| {
                    format!(
                        "pin log prefix {} has no finite range upper bound",
                        String::from_utf8_lossy(&prefix)
                    )
                })?;
                let start = pin_log_entry_key(&target_id, frontier + 1);
                store
                    .scan_range(&start, &end)
                    .await
                    .map_err(|e| format!("scan durable pin log after frontier {frontier}: {e}"))?
            }
            None => {
                let prefix = pin_log_target_prefix(&target_id);
                store
                    .scan_prefix(prefix.as_bytes())
                    .await
                    .map_err(|e| format!("scan durable pin log: {e}"))?
            }
        };
        let last_idx = rows.len().saturating_sub(1);
        let mut records = Vec::with_capacity(rows.len());
        for (idx, (key, value)) in rows.into_iter().enumerate() {
            match serde_json::from_slice::<PinLogRecord>(&value) {
                Ok(record) => {
                    if after_frontier.is_none_or(|frontier| record.frontier_after > frontier) {
                        records.push(record);
                    }
                }
                Err(e) if idx == last_idx => {
                    tracing::warn!(
                        target: "fold_db::sync::pin_log",
                        key = %String::from_utf8_lossy(&key),
                        error = %e,
                        "ignoring corrupt trailing durable pin log record"
                    );
                }
                Err(e) => {
                    return Err(format!(
                        "decode durable pin log record {}: {e}",
                        String::from_utf8_lossy(&key)
                    ));
                }
            }
        }
        Ok(records)
    }

    /// Inventory durable pin-log records for `target_id` by `LogOp` kind.
    ///
    /// Used to prove pre-intent `Put` / `LogicalCommit` rows are still
    /// truncatable after confirm, and to report leftover mix on a throwaway
    /// home. Does not rewrite the plane.
    #[cfg(test)]
    pub(crate) async fn inventory_pin_log_kinds(
        &self,
        target_id: &str,
    ) -> Result<PinLogKindInventory, String> {
        let store = self.pin_log_store().await?;
        let prefix = pin_log_target_prefix(target_id);
        let rows = store
            .scan_prefix(prefix.as_bytes())
            .await
            .map_err(|e| format!("scan pin log for kind inventory: {e}"))?;
        let mut inventory = PinLogKindInventory::default();
        for (_key, value) in rows {
            let bytes = value.len() as u64;
            inventory.records += 1;
            inventory.bytes += bytes;
            let kind = match serde_json::from_slice::<PinLogRecord>(&value) {
                Ok(record) => log_op_kind_name(&record.entry.op).to_string(),
                Err(_) => "undecodable".to_string(),
            };
            let slot = inventory.by_kind.entry(kind).or_default();
            slot.records += 1;
            slot.bytes += bytes;
        }
        Ok(inventory)
    }

    /// Read the durable per-writer published high-water mark for `target_id`.
    ///
    /// Absent means "this home has never completed an upload cycle", which is
    /// the same conservative starting point as an empty in-memory map: every
    /// record reads as pending, so nothing is deleted on a guess.
    ///
    /// A decode failure is downgraded to "unknown" rather than propagated. The
    /// only consequence of losing this value is re-uploading records that are
    /// already in cloud; the only consequence of *trusting a bad one* is
    /// deleting a record no peer can recover. Failing safe here is not
    /// optional.
    async fn read_published_f(&self, target_id: &str) -> BTreeMap<String, u64> {
        let store = match self.pin_log_store().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    target: "fold_db::sync::pin_log",
                    error = %e,
                    "durable published-F read skipped: cannot open durable pin log"
                );
                return BTreeMap::new();
            }
        };
        let key = pin_log_published_f_key(target_id);
        let raw = match store.get(&key).await {
            Ok(Some(raw)) => raw,
            Ok(None) => return BTreeMap::new(),
            Err(e) => {
                tracing::warn!(
                    target: "fold_db::sync::pin_log",
                    target_id = %target_id,
                    error = %e,
                    "durable published-F read failed; treating every record as pending"
                );
                return BTreeMap::new();
            }
        };
        match serde_json::from_slice::<BTreeMap<String, u64>>(&raw) {
            Ok(map) => map,
            Err(e) => {
                tracing::warn!(
                    target: "fold_db::sync::pin_log",
                    target_id = %target_id,
                    error = %e,
                    "durable published-F is undecodable; treating every record as pending"
                );
                BTreeMap::new()
            }
        }
    }

    /// Read a published-F map when the caller intends to advance it.
    ///
    /// A failed or undecodable read must not become an empty map followed by a
    /// successful overwrite. That sequence can regress another writer's
    /// durable confirmation and later reuse its frontier.
    async fn read_published_f_strict(
        &self,
        target_id: &str,
    ) -> Result<BTreeMap<String, u64>, String> {
        let store = self.pin_log_store().await?;
        let Some(raw) = store
            .get(&pin_log_published_f_key(target_id))
            .await
            .map_err(|e| format!("read durable pin-log published-F: {e}"))?
        else {
            return Ok(BTreeMap::new());
        };
        serde_json::from_slice(&raw).map_err(|e| format!("decode durable pin-log published-F: {e}"))
    }

    /// Strict startup floor for this writer's next mutation-log frontier.
    ///
    /// Unlike the conservative status/truncation reader above, this path must
    /// fail when the durable HWM is unreadable. Treating an unknown HWM as zero
    /// can mint a reused frontier that an old cloud confirmation immediately
    /// and falsely satisfies.
    pub(crate) async fn durable_frontier_floor_for_writer(
        &self,
        writer_id: &str,
        targets: &[SyncTarget],
        validate_all_pin_rows: bool,
    ) -> Result<u64, String> {
        let target_ids = targets
            .iter()
            .map(|target| target_id_for_prefix(&target.prefix))
            .collect::<BTreeSet<_>>();
        let store = self
            .pin_log_store()
            .await
            .map_err(|error| format!("open durable pin log for writer frontier seed: {error}"))?;

        // The home-wide point row is the steady-state path. The first frontier
        // allocation in each process also checks every historical pin-row key.
        // That bounded, keys-only fold detects rows written by an older binary
        // during a rollback interval because that binary cannot advance the new
        // point row. Later target generations skip the fold and use point reads.
        let stored_frontier = match store
            .get(PIN_LOG_APPENDED_F_KEY)
            .await
            .map_err(|error| format!("read durable pin-log allocation floor: {error}"))?
        {
            Some(raw) => {
                let bytes: [u8; 8] = raw.try_into().map_err(|raw: Vec<u8>| {
                    format!(
                        "decode durable pin-log allocation floor: expected 8 bytes, got {}",
                        raw.len()
                    )
                })?;
                u64::from_be_bytes(bytes)
            }
            None => 0,
        };
        let mut frontier = stored_frontier;
        if validate_all_pin_rows || stored_frontier == 0 {
            frontier = frontier.max(
                store
                    .max_key_u64_after_marker(PIN_LOG_ENTRY_PREFIX.as_bytes(), b":entry:")
                    .await
                    .map_err(|error| {
                        format!("fold legacy durable pin-log allocation floor: {error}")
                    })?
                    .unwrap_or(0),
            );
        }
        for target_id in target_ids {
            // A removed and re-added target can retain a cloud HWM above this
            // home's floor. Reconfiguration reads each current target's one
            // durable HWM point row before the next frontier is minted.
            let key = pin_log_published_f_key(&target_id);
            let Some(raw) = store.get(&key).await.map_err(|error| {
                format!("read durable published-F for target '{target_id}': {error}")
            })?
            else {
                continue;
            };
            let published =
                serde_json::from_slice::<BTreeMap<String, u64>>(&raw).map_err(|error| {
                    format!("decode durable published-F for target '{target_id}': {error}")
                })?;
            frontier = frontier.max(published.get(writer_id).copied().unwrap_or(0));
        }
        Ok(frontier)
    }

    /// Persist the per-writer published high-water mark for `target_id`.
    ///
    /// The flushed HWM is the authorization barrier. A cloud upload cycle must
    /// persist it before it advances a runtime/plane frontier or truncates any
    /// confirmed pin row. A failure returns an error and keeps every row. The
    /// whole-map max merge is serialized so concurrent peer-apply and upload
    /// updates cannot regress another writer's durable confirmation.
    async fn persist_published_f(
        &self,
        target_id: &str,
        by_writer: &BTreeMap<String, u64>,
    ) -> Result<(), String> {
        let _published_f = self.published_f_lock.lock().await;
        #[cfg(test)]
        if self
            .force_next_published_f_persist_err
            .swap(false, std::sync::atomic::Ordering::SeqCst)
        {
            return Err("injected durable published-F persist failure".to_string());
        }
        let mut merged = self.read_published_f_strict(target_id).await?;
        for (writer_id, through) in by_writer {
            let durable = merged.entry(writer_id.clone()).or_insert(0);
            *durable = (*durable).max(*through);
        }
        let store = self.pin_log_store().await?;
        let bytes = serde_json::to_vec(&merged)
            .map_err(|e| format!("encode durable pin-log published-F: {e}"))?;
        store
            .put(&pin_log_published_f_key(target_id), bytes)
            .await
            .map_err(|e| format!("persist durable pin-log published-F: {e}"))?;
        store
            .flush()
            .await
            .map_err(|e| format!("flush durable pin-log published-F: {e}"))
    }

    #[cfg(test)]
    async fn read_materialized_frontier(&self, target_id: &str) -> Result<Option<u64>, String> {
        let store = self.pin_log_store().await?;
        let key = pin_log_materialized_frontier_key(target_id);
        let Some(raw) = store
            .get(&key)
            .await
            .map_err(|e| format!("read durable pin-log materialized frontier: {e}"))?
        else {
            return Ok(None);
        };
        let bytes: [u8; 8] = raw.try_into().map_err(|raw: Vec<u8>| {
            format!(
                "decode durable pin-log materialized frontier: expected 8 bytes, got {}",
                raw.len()
            )
        })?;
        Ok(Some(u64::from_be_bytes(bytes)))
    }

    #[cfg(test)]
    async fn persist_materialized_frontier(
        &self,
        target_id: &str,
        frontier: u64,
    ) -> Result<(), String> {
        let store = self.pin_log_store().await?;
        store
            .put(
                &pin_log_materialized_frontier_key(target_id),
                frontier.to_be_bytes().to_vec(),
            )
            .await
            .map_err(|e| format!("persist durable pin-log materialized frontier: {e}"))?;
        store
            .flush()
            .await
            .map_err(|e| format!("flush durable pin-log materialized frontier: {e}"))
    }

    async fn sync_target_by_prefix(&self, target_prefix: &str) -> Result<SyncTarget, String> {
        self.targets
            .lock()
            .await
            .iter()
            .find(|target| target.prefix == target_prefix)
            .cloned()
            .ok_or_else(|| format!("sync target prefix '{target_prefix}' is not configured"))
    }

    /// Delete durable pin-log records that were **dropped from the outgoing
    /// stream and never published**, after tombstoning each one.
    ///
    /// This is deliberately NOT
    /// [`Self::truncate_confirmed_pin_log_records`]. That function deletes only
    /// frontiers cloud has confirmed, and its contract says why: "anything
    /// weaker risks dropping a record no peer can recover." A quarantined
    /// frontier is the exact opposite of a confirmed one — cloud never saw it —
    /// so routing the drop through a parameter named `confirmed_frontiers` made
    /// the call site read as safe while doing the thing that doc comment warns
    /// about. Same delete, opposite justification, and it needs its own name.
    ///
    /// The record still has to go. An unsealable row can never be uploaded (its
    /// atom is gone), and leaving it durable means every later cycle pays to
    /// scan past it forever. What was missing is the receipt.
    ///
    /// **Tombstone first, then delete.** If the tombstone write fails the row is
    /// left in place and retried next cycle: an untraced hole is worse than a
    /// row that costs one scan slot. Skipping the row is already decided by the
    /// caller, so the cycle makes progress either way — only the reclaim waits.
    async fn drop_unsealable_pin_log_records(
        &self,
        engine: &SyncEngine,
        target_id: &str,
        target_prefix: &str,
        quarantined: &[(u64, String)],
    ) -> usize {
        if quarantined.is_empty() {
            return 0;
        }
        let store = match self.pin_log_store().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    target: "fold_db::sync::mutation_log",
                    error = %e,
                    "quarantine drop skipped: cannot open durable pin log"
                );
                return 0;
            }
        };
        let mut removed = 0usize;
        for (frontier, reason) in quarantined {
            if let Err(e) = engine
                .save_upload_quarantine_tombstone(target_prefix, *frontier, reason)
                .await
            {
                tracing::warn!(
                    target: "fold_db::sync::mutation_log",
                    error = %e,
                    frontier = *frontier,
                    "quarantine tombstone failed; keeping the durable row so the hole stays traceable (retried next cycle)"
                );
                continue;
            }
            let key = pin_log_entry_key(target_id, *frontier);
            match store.delete(&key).await {
                Ok(true) => removed += 1,
                Ok(false) => {}
                Err(e) => {
                    tracing::warn!(
                        target: "fold_db::sync::mutation_log",
                        error = %e,
                        frontier = *frontier,
                        "quarantine drop: delete failed (retried next cycle)"
                    );
                }
            }
        }
        self.maybe_compact_pin_log_plane(removed).await;
        removed
    }

    /// Delete durable pin-log records that cloud has **confirmed**.
    ///
    /// Called only after a successful cloud publish, and only for the exact
    /// frontiers that were confirmed — never a range inferred from a
    /// high-water mark. Anything weaker risks dropping a record no peer can
    /// recover.
    ///
    /// Why this exists: capture appends a durable record per commit, and
    /// nothing ever removed them. On the primary the pin log grew
    /// **138 MiB -> 10.45 GiB in about a day** (store 13.70 -> 25.67 GiB),
    /// feeding the memory pressure that was SIGKILLing the daemon. Capture was
    /// on, publish was a stub, and truncation was gated on publish — so the log
    /// had no exit path at all.
    ///
    /// Best-effort: a delete failure is logged and retried next cycle. It must
    /// never fail a publish that already succeeded, and never block local R/W.
    async fn truncate_confirmed_pin_log_records(
        &self,
        target_id: &str,
        confirmed_frontiers: &[u64],
    ) -> usize {
        if confirmed_frontiers.is_empty() {
            return 0;
        }
        let store = match self.pin_log_store().await {
            Ok(s) => s,
            Err(e) => {
                tracing::warn!(
                    target: "fold_db::sync::mutation_log",
                    error = %e,
                    "pin-log truncate skipped: cannot open durable pin log"
                );
                return 0;
            }
        };
        let mut removed = 0usize;
        for frontier in confirmed_frontiers {
            let key = pin_log_entry_key(target_id, *frontier);
            match store.delete(&key).await {
                Ok(true) => removed += 1,
                Ok(false) => {}
                Err(e) => {
                    tracing::warn!(
                        target: "fold_db::sync::mutation_log",
                        error = %e,
                        frontier = *frontier,
                        "pin-log truncate: delete failed (retried next cycle)"
                    );
                }
            }
        }
        self.maybe_compact_pin_log_plane(removed).await;
        removed
    }

    /// Return the bytes the deletes above only *logically* freed.
    ///
    /// `LastStore` is append-structured: `delete` writes a delete line and
    /// leaves the original record in the segment, so a truncation cycle makes
    /// the plane's files **larger**, not smaller. Measured on the primary with
    /// sync fully healthy and truncation firing every cycle, `sync_pin_log`
    /// grew 21,389 -> 21,621 MiB in 91 minutes — about 3.7 GiB/day — while the
    /// whole store held 1.65 GB of real record content.
    ///
    /// Compaction rewrites only the keys still live in the shard index, which
    /// is exactly the set of records cloud has *not* confirmed, and deletes the
    /// superseded segment files. Running it here rather than leaving it to
    /// `lastdb db compact --collection sync_pin_log --execute` is the whole
    /// point: an operator command that nobody runs unattended is not a
    /// retention policy.
    ///
    /// Safety and cost:
    /// - Best-effort. The publish that led here already succeeded; a compaction
    ///   failure is logged and retried once the counter refills. It must never
    ///   fail a publish and never block local reads or writes.
    /// - `compact_collection` locks one shard of one collection at a time, so
    ///   only pin-log writes wait, and only per shard. `main`, `atoms`, and
    ///   `tips` are untouched.
    /// - The plane is capture-skipped (`SYNC_INTERNAL_NAMESPACES`), so this
    ///   rewrite produces no mutation-log records. Compacting a *captured*
    ///   plane is what turned the 2026-08-08 `tips` compaction into 11.58 GiB
    ///   of new pin log; this cannot repeat that.
    ///
    /// # Why a row counter alone is not a retention policy
    ///
    /// `truncated_since_compact` counts rows deleted by **this process**. It is
    /// an in-memory `AtomicU64`, so every restart throws the accumulated budget
    /// away — the same process-local-state bug that made truncate-after-confirm
    /// never survive a restart in the first place. Measured on the primary
    /// 2026-08-17T06:52Z, 43 minutes after a healthy start with `degraded=false`
    /// and `log_lag=0`:
    ///
    /// ```text
    /// lastdb db compact --collection sync_pin_log   (dry run)
    ///   live_keys      1
    ///   bytes_before   21_951_142_027      # 20.4 GiB, 52% of a 39 GiB store
    ///   never_compact  false
    ///   skipped_reason null
    /// grep -ci 'pin.log' lastdbd.err.log  ->  0
    /// ```
    ///
    /// Compaction was permitted, would have collapsed the plane to one record,
    /// and had not been attempted once: 1,359 segment files from nine days
    /// earlier were still on disk. The row trigger never armed because the
    /// primary restarts (safe upgrades, memory guard) more often than a publish
    /// stream refills 20,000 confirmed rows.
    ///
    /// So the second trigger reads the **plane's on-disk size**, which is state,
    /// not session history. A bloated plane inherited from a previous process is
    /// noticed on the first publish cycle after start, and the plane is bounded
    /// by construction rather than by how long this process has been up.
    async fn maybe_compact_pin_log_plane(&self, removed: usize) {
        // Packing lock: hold through the rewrite. A boolean pre-check would
        // race a new BackupPublishTarget cut, retiring chunks under an
        // uncommitted manifest. Same shape as the capture-worker compactors.
        let backup_target = self.backup_publish_target.lock().await;
        if backup_target.is_some() {
            tracing::debug!(
                target: "fold_db::sync::mutation_log",
                "skipping pin-log compaction while a backup publish target is held"
            );
            return;
        }
        let rows_due = self.rows_due_for_compaction(removed);
        // Probe even when `removed == 0`: bloat left by an earlier process is
        // exactly the case the row counter cannot see.
        let bytes_due = if rows_due.is_some() {
            None
        } else {
            self.bloated_plane_bytes()
        };
        let (pending, trigger) = match (rows_due, bytes_due) {
            (Some(pending), _) => (pending, "row_budget"),
            (None, Some(bytes)) => {
                tracing::info!(
                    target: "fold_db::sync::mutation_log",
                    plane_bytes = bytes,
                    max_plane_bytes = self.compact_max_plane_bytes,
                    "pin-log plane is over its on-disk cap; compacting without \
                     waiting for the row budget"
                );
                // A size-triggered rewrite reclaims whatever the pending rows
                // would have, so their budget is spent too.
                let pending = self
                    .truncated_since_compact
                    .swap(0, std::sync::atomic::Ordering::SeqCst);
                (pending, "plane_bytes")
            }
            (None, None) => return,
        };

        let options = crate::storage::laststore::CollectionCompactOptions {
            collection: PIN_LOG_NAMESPACE.to_string(),
            dry_run: false,
            seed_committed_history: false,
        };
        match self.store.compact_collection(options).await {
            Ok(report) => {
                if let Some(reason) = report.skipped_reason.as_deref() {
                    tracing::warn!(
                        target: "fold_db::sync::mutation_log",
                        reason,
                        "pin-log compaction refused; plane keeps growing until this is fixed"
                    );
                    return;
                }
                let reclaimed = report
                    .bytes_after
                    .map(|after| report.bytes_before.saturating_sub(after));
                self.raise_size_trigger_floor(report.bytes_after);
                *self.last_compact_trigger.lock().await = Some(trigger.to_string());
                tracing::info!(
                    target: "fold_db::sync::mutation_log",
                    trigger,
                    truncated_rows = pending,
                    live_keys = report.live_keys,
                    bytes_before = report.bytes_before,
                    bytes_after = report.bytes_after,
                    reclaimed_bytes = reclaimed,
                    "pin-log plane compacted after confirmed truncation"
                );
            }
            Err(e) => {
                tracing::warn!(
                    target: "fold_db::sync::mutation_log",
                    error = %e,
                    trigger,
                    truncated_rows = pending,
                    "pin-log compaction failed (retried on a later cycle)"
                );
            }
        }
    }

    /// Has this process truncated enough confirmed rows to pay for a rewrite?
    ///
    /// Returns the pending row count and *claims* it, so two concurrent publish
    /// cycles cannot both start a compaction of the same plane.
    fn rows_due_for_compaction(&self, removed: usize) -> Option<u64> {
        if removed == 0 {
            return None;
        }
        let threshold = self.compact_after_rows;
        if threshold == 0 {
            return None;
        }
        let before = self
            .truncated_since_compact
            .fetch_add(removed as u64, std::sync::atomic::Ordering::Relaxed);
        let pending = before.saturating_add(removed as u64);
        if pending < threshold {
            return None;
        }
        // Claim the budget before the caller awaits.
        self.truncated_since_compact
            .compare_exchange(
                pending,
                0,
                std::sync::atomic::Ordering::SeqCst,
                std::sync::atomic::Ordering::Relaxed,
            )
            .ok()
            .map(|_| pending)
    }

    /// Raise the size trigger's floor so a legitimately large live set cannot
    /// turn the cap into a rewrite treadmill.
    ///
    /// The cap assumes the plane's live content is near zero, which is true when
    /// sync is healthy — the live set is the unconfirmed publish backlog. During
    /// a long sync outage it is not: nothing is confirmed, so nothing can be
    /// truncated, and the plane can hold more than the cap in records that must
    /// be kept. Without a floor the size trigger would then fire on every probe
    /// interval and rewrite an over-cap plane every few minutes, reclaiming
    /// nothing.
    ///
    /// Doubling the post-compaction size means the next size-triggered rewrite
    /// waits for the plane to double again — so growth stays bounded while the
    /// rewrite rate falls with the live set's size. The floor never drops below
    /// the cap, and a compaction that genuinely emptied the plane leaves the
    /// floor at the cap.
    fn raise_size_trigger_floor(&self, bytes_after: Option<u64>) {
        let Some(after) = bytes_after else {
            return;
        };
        let floor = after.saturating_mul(2).max(self.compact_max_plane_bytes);
        self.size_trigger_floor_bytes
            .store(floor, std::sync::atomic::Ordering::Relaxed);
    }

    /// Plane bytes, if the plane is over its cap and a probe is due.
    ///
    /// Rate-limited because this runs on the publish path: the probe is a stat
    /// walk of one collection directory (no shard loads, no index rebuild — see
    /// [`crate::storage::traits::NamespacedStore::collection_disk_bytes`]), but
    /// a healthy primary publishes every few tens of seconds and there is no
    /// reason to walk 2,600 files that often.
    ///
    /// Returns `None` when the cap is disabled, a probe is not yet due, the
    /// backend cannot measure bytes, or the plane is within its cap. Claiming
    /// the probe slot before measuring means a concurrent cycle sees "not due"
    /// rather than racing into a second compaction.
    fn bloated_plane_bytes(&self) -> Option<u64> {
        let cap = self.compact_max_plane_bytes;
        if cap == 0 {
            return None;
        }
        let now_s = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_secs());
        let last = self
            .last_bloat_probe_unix_s
            .load(std::sync::atomic::Ordering::Relaxed);
        if last != 0 && now_s.saturating_sub(last) < self.compact_bloat_probe_interval_s {
            return None;
        }
        if self
            .last_bloat_probe_unix_s
            .compare_exchange(
                last,
                now_s.max(1),
                std::sync::atomic::Ordering::SeqCst,
                std::sync::atomic::Ordering::Relaxed,
            )
            .is_err()
        {
            return None;
        }
        let bytes = self.store.collection_disk_bytes(PIN_LOG_NAMESPACE)?;
        let floor = self
            .size_trigger_floor_bytes
            .load(std::sync::atomic::Ordering::Relaxed)
            .max(cap);
        (bytes > floor).then_some(bytes)
    }

    pub(crate) async fn last_compact_trigger(&self) -> Option<String> {
        self.last_compact_trigger.lock().await.clone()
    }

    /// Every atom uuid a still-durable pin-log record references.
    ///
    /// `strip_sot_field_values` drops a record's inline bodies once every
    /// field carries an id, so an unpublished record is only as durable as the
    /// atoms it names. `gc-atoms` builds its reference set from `mk:` (current
    /// head only), `tv:`, `history:`, `conflict:` and `ref:` — none of which
    /// can see this plane. One ordinary update moves the head off a captured
    /// atom, and the next GC pass reads that body as an orphan and frees it.
    /// The record is then unsealable forever, and the upload path quarantines
    /// and drops it — so a write that was acked locally never reaches the
    /// cloud, with no tombstone and no retry.
    ///
    /// Measured on the primary as `quarantined` 21 → 111 in bursts that line
    /// up with GC passes, dominated by the fields a board rewrites most
    /// (`position`, `created_at`, `branch`). Record
    /// `papercut-lastdb-capture-mints-atom-ids-for-fields-the-write-path-never-stores`.
    ///
    /// Scans every target's entries rather than one target's: an atom is
    /// content addressed by `(schema, value)`, so the body one target still
    /// needs can be the body another target already published.
    pub(crate) async fn pending_pin_log_atom_uuids(
        &self,
    ) -> Result<std::collections::HashSet<String>, String> {
        let mut refs = std::collections::HashSet::new();
        let mut after_key = None;
        loop {
            let page = self
                .pending_pin_log_atom_uuids_page(after_key.as_deref(), 4096)
                .await?;
            refs.extend(page.atom_uuids);
            if page.scan_complete {
                return Ok(refs);
            }
            after_key = page.next_after_key;
        }
    }

    /// Read one strict, bounded page of atom references from the durable log.
    ///
    /// Only a field without an inline body depends on its atom. New
    /// self-contained records therefore add no GC roots, while legacy
    /// reference-only rows remain protected until upload removes them.
    pub(crate) async fn pending_pin_log_atom_uuids_page(
        &self,
        after_key: Option<&[u8]>,
        limit: usize,
    ) -> Result<crate::db_operations::AutomaticGcAtomsPinLogReferencePage, String> {
        let store = self.pin_log_store().await?;
        let prefix = PIN_LOG_ENTRY_PREFIX.as_bytes();
        let start = after_key.map_or_else(|| prefix.to_vec(), key_after);
        let end = prefix_upper_bound(prefix)
            .ok_or_else(|| "pin-log entry prefix has no upper bound".to_string())?;
        let limit = limit.max(1);
        let mut rows = store
            .scan_range_paged(&start, &end, limit.saturating_add(1))
            .await
            .map_err(|e| format!("scan pin log page for atom references: {e}"))?;
        let scan_complete = rows.len() <= limit;
        if !scan_complete {
            rows.truncate(limit);
        }
        let last_idx = rows.len().saturating_sub(1);
        let mut refs = std::collections::HashSet::new();
        for (idx, (key, value)) in rows.iter().enumerate() {
            match serde_json::from_slice::<PinLogRecord>(value) {
                Ok(record) => {
                    if let crate::sync::log::LogOp::MutationIntent { mutations } = &record.entry.op
                    {
                        for envelope in mutations {
                            refs.extend(
                                envelope
                                    .field_atom_uuids
                                    .iter()
                                    .filter(|(field, _)| {
                                        !envelope.fields_and_values.contains_key(*field)
                                    })
                                    .map(|(_, uuid)| uuid.clone()),
                            );
                        }
                    }
                }
                Err(error) if scan_complete && idx == last_idx => {
                    tracing::warn!(
                        target: "fold_db::sync::pin_log",
                        key = %String::from_utf8_lossy(key),
                        %error,
                        "ignoring corrupt trailing durable pin log record while collecting atom references"
                    );
                }
                Err(error) => {
                    return Err(format!(
                        "decode durable pin log record {} for atom references: {error}",
                        String::from_utf8_lossy(key)
                    ));
                }
            }
        }
        Ok(crate::db_operations::AutomaticGcAtomsPinLogReferencePage {
            atom_uuids: refs,
            next_after_key: (!scan_complete)
                .then(|| rows.last().map(|(key, _)| key.clone()))
                .flatten(),
            rows_scanned: rows.len() as u64,
            scan_complete,
        })
    }

    async fn pin_log_store(
        &self,
    ) -> Result<std::sync::Arc<dyn crate::storage::traits::KvStore>, String> {
        self.store
            .open_namespace(PIN_LOG_NAMESPACE)
            .await
            .map_err(|e| format!("open durable pin log: {e}"))
    }
}

fn target_id_for_prefix(prefix: &str) -> String {
    if prefix.is_empty() {
        return "personal".to_string();
    }
    let digest = Sha256::digest(prefix.as_bytes());
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

fn pin_log_target_prefix(target_id: &str) -> String {
    format!("{PIN_LOG_ENTRY_PREFIX}{target_id}:entry:")
}

fn pin_log_entry_key(target_id: &str, frontier: u64) -> Vec<u8> {
    format!("{}{frontier:020}", pin_log_target_prefix(target_id)).into_bytes()
}

#[cfg(test)]
fn pin_log_materialized_frontier_key(target_id: &str) -> Vec<u8> {
    format!("{PIN_LOG_MATERIALIZED_FRONTIER_PREFIX}{target_id}").into_bytes()
}

fn pin_log_published_f_key(target_id: &str) -> Vec<u8> {
    format!("{PIN_LOG_PUBLISHED_F_PREFIX}{target_id}").into_bytes()
}

/// Confirmed rows that must be truncated before the pin-log plane is compacted.
///
/// This is the reclaim/throughput knob. Compaction rewrites every live record
/// in the plane, so firing it after a handful of deletes would pay a full
/// rewrite for a few kilobytes; letting it never fire costs ~3.7 GiB/day of
/// dead segment bytes on a busy primary. The default amortises one rewrite
/// across a meaningful truncation batch while still bounding how far the plane
/// can drift from its live content.
///
/// Set `LASTDB_PIN_LOG_COMPACT_AFTER_ROWS=0` to disable self-compaction and
/// leave reclaim entirely to `lastdb db compact --collection sync_pin_log`.
fn pin_log_compact_after_rows() -> u64 {
    std::env::var("LASTDB_PIN_LOG_COMPACT_AFTER_ROWS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(20_000u64)
}

/// On-disk bytes above which the pin-log plane is compacted regardless of the
/// row budget — the trigger that actually bounds the plane.
///
/// The row counter is process-local and a restart zeroes it, so on a primary
/// that restarts for safe upgrades and memory-guard events it can arm slower
/// than the plane bloats. On 2026-08-17 that left `sync_pin_log` holding
/// **20.4 GiB behind one live record**, 52% of the store, with compaction
/// permitted and never attempted. A size cap cannot drift that way: it is read
/// off the disk, so an inherited bloated plane is noticed on the first publish
/// cycle after start.
///
/// The primary's measured healthy live set is 5 rows / 620 KiB. A 16 MiB cap
/// leaves ample headroom while reaching the measured 11.6 MiB/hour churn in
/// roughly 1.4 hours, inside a normal daemon session; the previous 512 MiB cap
/// needed about 44 hours. Set
/// `LASTDB_PIN_LOG_COMPACT_MAX_BYTES=0` to disable the size trigger and keep
/// only the row budget.
fn pin_log_compact_max_plane_bytes() -> u64 {
    std::env::var("LASTDB_PIN_LOG_COMPACT_MAX_BYTES")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(16 * 1024 * 1024)
}

/// Minimum seconds between on-disk bloat probes.
///
/// The probe is a directory stat walk, cheap next to a publish cycle, but it
/// runs on the publish path and there is nothing to gain from walking the same
/// files every cycle. Override with
/// `LASTDB_PIN_LOG_COMPACT_PROBE_INTERVAL_SECS`.
fn pin_log_compact_bloat_probe_interval_s() -> u64 {
    std::env::var("LASTDB_PIN_LOG_COMPACT_PROBE_INTERVAL_SECS")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(300u64)
}

/// Rows read per durable page by the bounded pin-log scan.
///
/// This is the cycle's RAM knob: peak is roughly this many records' worth of
/// raw bytes plus their decoded forms, regardless of how large the plane is.
/// Override with `LASTDB_PIN_LOG_SCAN_PAGE`.
fn pin_log_scan_page_size() -> usize {
    std::env::var("LASTDB_PIN_LOG_SCAN_PAGE")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(256usize)
        .clamp(1, 4096)
}

/// Durable rows one upload cycle may examine before giving up and retrying next
/// cycle.
///
/// Only binds when the front of the log is a long run of records this cycle
/// judges not pending — published records whose truncation delete failed. Those
/// still have to be read to be skipped, so without a budget a single cycle can
/// walk the entire plane (bounded RAM, unbounded time) and starve the rest of
/// the sync loop. Override with `LASTDB_PIN_LOG_SCAN_ROW_BUDGET`.
fn pin_log_scan_row_budget() -> usize {
    std::env::var("LASTDB_PIN_LOG_SCAN_ROW_BUDGET")
        .ok()
        .and_then(|v| v.parse().ok())
        .unwrap_or(50_000usize)
        .clamp(1, 10_000_000)
}

/// Exclusive upper bound for a byte-prefix range scan.
///
/// Increments the last byte that is not `0xFF`, dropping the `0xFF` tail.
///
/// Returns `None` for an empty or all-`0xFF` prefix, which have no finite
/// successor. `None` rather than a sentinel because every fallback here is
/// wrong in a way the caller must not silently inherit: returning the prefix
/// unchanged gives `start >= end`, which the range-scan contract answers with
/// an empty result — a scan that reads nothing while reporting success. Pin-log
/// prefixes always end in `:`, so this is unreachable for the real key format;
/// the caller still handles it rather than assuming.
fn prefix_upper_bound(prefix: &[u8]) -> Option<Vec<u8>> {
    let mut end = prefix.to_vec();
    while let Some(last) = end.pop() {
        if last != u8::MAX {
            end.push(last + 1);
            return Some(end);
        }
    }
    None
}

/// Smallest key strictly greater than `key`, for keyset pagination.
fn key_after(key: &[u8]) -> Vec<u8> {
    let mut next = key.to_vec();
    next.push(0);
    next
}

/// One bounded window of pending records off a target's durable pin log.
#[derive(Debug, Default)]
pub(crate) struct PendingPinLogPage {
    /// Pending records found, in ascending frontier order, capped at `want`.
    pub(crate) records: Vec<PinLogRecord>,
    /// Exact frontiers the caller classified as already published while
    /// scanning. Cloud cycles retry their best-effort local deletes; test-plane
    /// cycles keep them because a local mirror is not cloud confirmation.
    pub(crate) not_pending_frontiers: Vec<u64>,
    /// Durable rows actually read — the cycle's read cost.
    pub(crate) rows_scanned: usize,
    /// `false` when the scan stopped before the end of the plane, so
    /// `records.len()` is a floor on what is pending, not the total.
    pub(crate) scan_complete: bool,
    /// `true` when the stop was the row budget rather than a filled batch.
    pub(crate) row_budget_exhausted: bool,
}

fn now_millis() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64
}

// ---------------------------------------------------------------------------
// Operator pin-log audit
//
// `sync_pin_log` is the largest plane on the primary (21 GiB / 51% of the store
// at measurement time). This read-only verb makes its confirmed-vs-pending
// split measurable from the durable published-F map (#1511). Reclaim is owned
// by confirmed truncation plus plane compaction; the audit never deletes.
// ---------------------------------------------------------------------------

/// Default entry rows one audit daemon call examines before returning a
/// resume cursor. Matches the per-cycle pin-log scan row budget so a single
/// call cannot monopolise the owner socket on a multi-GiB plane.
pub const PIN_LOG_OPERATOR_KEYS_PER_CALL: usize = 50_000;

/// Per-writer slice of a pin-log audit page.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct PinLogWriterStat {
    pub target_id: String,
    pub writer_id: String,
    /// Durable published high-water mark for this writer (0 if absent).
    pub durable_published_f: u64,
    pub confirmed_rows: u64,
    pub confirmed_bytes: u64,
    pub pending_rows: u64,
    pub pending_bytes: u64,
}

/// Bounded, resumable, read-only pin-log plane report.
#[derive(Debug, Clone, Serialize, Deserialize, Default, PartialEq, Eq)]
pub struct PinLogPlaneReport {
    pub keys_scanned: u64,
    pub entry_rows: u64,
    pub entry_bytes: u64,
    pub confirmed_rows: u64,
    pub confirmed_bytes: u64,
    pub pending_rows: u64,
    pub pending_bytes: u64,
    pub unreadable_rows: u64,
    /// Distinct targets represented by entry rows on this page.
    pub targets_seen: u64,
    pub writers: Vec<PinLogWriterStat>,
    pub more_remaining: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub next_after_key: Option<String>,
}

/// Point-read one target's durable published-F map.
///
/// An absent or undecodable map is treated as empty, so its rows classify as
/// pending. The audit deliberately does not scan the published-F namespace.
async fn load_durable_published_f_map(
    store: &dyn crate::storage::traits::KvStore,
    target_id: &str,
) -> Result<BTreeMap<String, u64>, String> {
    let value = store
        .get(&pin_log_published_f_key(target_id))
        .await
        .map_err(|error| format!("read durable pin-log published-F map: {error}"))?;
    let Some(value) = value else {
        return Ok(BTreeMap::new());
    };
    match serde_json::from_slice(&value) {
        Ok(map) => Ok(map),
        Err(error) => {
            tracing::warn!(
                target: "fold_db::sync::pin_log",
                target_id = %target_id,
                error = %error,
                "durable published-F map undecodable during operator audit; treating as empty"
            );
            Ok(BTreeMap::new())
        }
    }
}

fn writer_hwm(
    maps: &BTreeMap<String, BTreeMap<String, u64>>,
    target_id: &str,
    writer_id: &str,
) -> u64 {
    maps.get(target_id)
        .and_then(|m| m.get(writer_id).copied())
        .unwrap_or(0)
}

fn bump_writer_stat(
    writers: &mut BTreeMap<(String, String), PinLogWriterStat>,
    target_id: &str,
    writer_id: &str,
    hwm: u64,
    confirmed: bool,
    bytes: u64,
) {
    let key = (target_id.to_string(), writer_id.to_string());
    let row = writers.entry(key).or_insert_with(|| PinLogWriterStat {
        target_id: target_id.to_string(),
        writer_id: writer_id.to_string(),
        durable_published_f: hwm,
        ..Default::default()
    });
    row.durable_published_f = row.durable_published_f.max(hwm);
    if confirmed {
        row.confirmed_rows += 1;
        row.confirmed_bytes = row.confirmed_bytes.saturating_add(bytes);
    } else {
        row.pending_rows += 1;
        row.pending_bytes = row.pending_bytes.saturating_add(bytes);
    }
}

/// Bounded, resumable, read-only pin-log plane audit.
///
/// Classification predicate for "confirmed":
/// `record.frontier_after <= durable_published_f[target][writer]`
/// (missing map/writer ⇒ 0 ⇒ every row pending). Durable maps are point-read
/// lazily for only the targets represented on the bounded entry page.
pub async fn audit_pin_log_plane(
    store: &dyn crate::storage::traits::KvStore,
    max_keys: usize,
    after_key: Option<&str>,
) -> Result<PinLogPlaneReport, crate::schema::SchemaError> {
    let max_keys = max_keys.clamp(1, 10_000_000);
    let mut published_maps: BTreeMap<String, BTreeMap<String, u64>> = BTreeMap::new();

    let entry_prefix = PIN_LOG_ENTRY_PREFIX.as_bytes();
    let end = prefix_upper_bound(entry_prefix).ok_or_else(|| {
        crate::schema::SchemaError::InvalidData(
            "pin-log entry prefix has no finite range upper bound".to_string(),
        )
    })?;
    let mut cursor = match after_key {
        Some(s) => {
            let bytes = s.as_bytes().to_vec();
            // Resume must stay inside the entry keyspace.
            if !bytes.starts_with(entry_prefix) {
                return Err(crate::schema::SchemaError::InvalidCursor(format!(
                    "after_key must be a pin-log entry key under '{PIN_LOG_ENTRY_PREFIX}'"
                )));
            }
            bytes
        }
        None => entry_prefix.to_vec(),
    };

    let mut report = PinLogPlaneReport::default();
    let mut writers: BTreeMap<(String, String), PinLogWriterStat> = BTreeMap::new();

    let page_size = pin_log_scan_page_size();
    let mut more_remaining = false;
    let mut next_after: Option<String> = None;

    loop {
        let rows = store
            .scan_range_paged(&cursor, &end, page_size)
            .await
            .map_err(|e| {
                crate::schema::SchemaError::InvalidData(format!("scan pin-log entries: {e}"))
            })?;
        if rows.is_empty() {
            break;
        }
        let final_page = rows.len() < page_size;
        let last_idx = rows.len() - 1;
        let mut page_next = None;

        for (idx, (key, value)) in rows.into_iter().enumerate() {
            page_next = Some(key_after(&key));
            report.keys_scanned += 1;
            let key_str = String::from_utf8_lossy(&key);

            // Non-entry keys under the target prefix should not appear, but
            // skip defensively while still charging the bounded key budget.
            if !key_str.contains(":entry:") {
                if report.keys_scanned as usize >= max_keys {
                    more_remaining = true;
                    next_after = page_next
                        .as_ref()
                        .map(|k| String::from_utf8_lossy(k).into_owned());
                    break;
                }
                continue;
            }

            match serde_json::from_slice::<PinLogRecord>(&value) {
                Ok(record) => {
                    let bytes = value.len() as u64;
                    report.entry_rows += 1;
                    report.entry_bytes = report.entry_bytes.saturating_add(bytes);
                    if !published_maps.contains_key(&record.target_id) {
                        let map = load_durable_published_f_map(store, &record.target_id)
                            .await
                            .map_err(crate::schema::SchemaError::InvalidData)?;
                        published_maps.insert(record.target_id.clone(), map);
                    }
                    let hwm = writer_hwm(&published_maps, &record.target_id, &record.writer_id);
                    let confirmed = record.frontier_after <= hwm;
                    if confirmed {
                        report.confirmed_rows += 1;
                        report.confirmed_bytes = report.confirmed_bytes.saturating_add(bytes);
                    } else {
                        report.pending_rows += 1;
                        report.pending_bytes = report.pending_bytes.saturating_add(bytes);
                    }
                    bump_writer_stat(
                        &mut writers,
                        &record.target_id,
                        &record.writer_id,
                        hwm,
                        confirmed,
                        bytes,
                    );
                }
                Err(e) if final_page && idx == last_idx => {
                    tracing::warn!(
                        target: "fold_db::sync::pin_log",
                        key = %key_str,
                        error = %e,
                        "ignoring corrupt trailing pin-log entry during operator walk"
                    );
                    report.unreadable_rows += 1;
                }
                Err(e) => {
                    return Err(crate::schema::SchemaError::InvalidData(format!(
                        "decode pin-log entry {key_str}: {e}"
                    )));
                }
            }

            if report.keys_scanned as usize >= max_keys {
                more_remaining = true;
                next_after = page_next
                    .as_ref()
                    .map(|k| String::from_utf8_lossy(k).into_owned());
                break;
            }
        }

        if more_remaining {
            break;
        }
        if final_page {
            break;
        }
        match page_next {
            Some(next) => cursor = next,
            None => break,
        }
    }

    let mut target_ids: BTreeSet<String> = BTreeSet::new();
    for (tid, _) in writers.keys() {
        target_ids.insert(tid.clone());
    }
    report.targets_seen = target_ids.len() as u64;
    report.writers = writers.into_values().collect();
    report.writers.sort_by(|a, b| {
        a.target_id
            .cmp(&b.target_id)
            .then_with(|| a.writer_id.cmp(&b.writer_id))
    });
    report.more_remaining = more_remaining;
    report.next_after_key = next_after;

    Ok(report)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::crypto::provider::LocalCryptoProvider;
    use crate::crypto::CryptoProvider;
    use crate::security::Ed25519KeyPair;
    use crate::storage::inmemory_backend::InMemoryNamespacedStore;
    use crate::storage::traits::NamespacedStore;
    use crate::sync::auth::{AuthClient, SyncAuth};
    use crate::sync::org_sync::SyncTarget;
    use crate::sync::s3::S3Client;
    use base64::Engine as _;
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn parse_mutation_log_object_key_accepts_legacy_and_schema_folder_paths() {
        assert_eq!(
            parse_mutation_log_object_key("log/42.enc"),
            Some((None, 42))
        );
        assert_eq!(
            parse_mutation_log_object_key("log/device-a/99.enc"),
            Some((Some("device-a".to_string()), 99))
        );
        assert_eq!(
            parse_mutation_log_object_key("log/device-a/Card/1700000000000000042_7.enc"),
            Some((Some("device-a".to_string()), 7))
        );
        assert!(parse_mutation_log_object_key("log/not_a_number.enc").is_none());
        assert!(parse_mutation_log_object_key("snapshots/1.enc").is_none());
    }

    /// Regression: one peer-apply cycle must not presign+download the flat
    /// classic `log/{seq}.enc` prefix just to throw it away after a failed
    /// unseal. That is what made a single `do_sync` on the primary take ~38
    /// minutes against `remote_log_entries=11358` while reporting
    /// `segments_considered=1`, so the 30s `sync_interval_ms` was never
    /// observable. The bound is on *downloads issued*, not on wall clock.
    #[test]
    fn peer_apply_candidates_exclude_classic_flat_log_objects() {
        // A realistic listing: a large flat classic prefix plus a couple of
        // genuine writer-scoped segments.
        let mut keys: Vec<String> = (1..=11_358).map(|seq| format!("log/{seq}.enc")).collect();
        keys.push("log/device-a/500.enc".to_string());
        keys.push("log/device-b/700.enc".to_string());
        let borrowed: Vec<&str> = keys.iter().map(String::as_str).collect();

        let (candidates, flat_classic_skipped) =
            select_peer_apply_candidates(borrowed, &Frontier::vector(BTreeMap::new()));

        // Every flat object is rejected before any download is issued.
        assert_eq!(flat_classic_skipped, 11_358);
        // Only the writer-scoped segments survive to the presign/download loop.
        assert_eq!(
            candidates
                .iter()
                .map(|(writer, through, _)| (writer.as_str(), *through))
                .collect::<Vec<_>>(),
            vec![("device-a", 500), ("device-b", 700)]
        );
    }

    /// The incorporated vector F still suppresses already-applied writer
    /// segments, and the flat filter does not disturb that.
    #[test]
    fn peer_apply_candidates_still_honor_incorporated_frontier() {
        let keys = [
            "log/9.enc",
            "log/device-a/10.enc",
            "log/device-a/20.enc",
            "log/device-b/5.enc",
        ];
        let frontier = Frontier::vector(BTreeMap::from([("device-a".to_string(), 10u64)]));

        let (candidates, flat_classic_skipped) = select_peer_apply_candidates(keys, &frontier);

        assert_eq!(flat_classic_skipped, 1);
        assert_eq!(
            candidates
                .iter()
                .map(|(writer, through, _)| (writer.as_str(), *through))
                .collect::<Vec<_>>(),
            vec![("device-a", 20), ("device-b", 5)]
        );
    }

    #[tokio::test]
    async fn incorporated_frontier_is_per_writer_vector_not_scalar() {
        let engine = test_engine(SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        engine
            .pin_log
            .incorporate_applied_frontier(&BTreeMap::from([
                ("writer-a".to_string(), 42),
                ("test-device".to_string(), 99),
            ]))
            .await
            .expect("persist applied vector F");
        let frontier = engine.pin_log.incorporated_frontier().await;
        assert!(
            matches!(frontier, Frontier::Vector { .. }),
            "peer apply must not use scalar F; got {frontier:?}"
        );
        assert!(frontier.covers_log(Some("writer-a"), 42));
        assert!(!frontier.covers_log(Some("writer-a"), 43));
        assert!(
            !frontier.covers_log(Some("peer-device"), 1),
            "missing writer must not be covered (scalar 0 would skip this)"
        );
        assert!(frontier.covers_log(Some("test-device"), 99));
    }

    #[tokio::test]
    async fn backup_restore_frontier_pins_before_barrier_and_excludes_covered_downloads() {
        let engine = Arc::new(test_engine(SyncConfig::default()));
        let through = 1_788_888_880_232_765_000;
        engine
            .pin_log
            .persist_published_f(
                "personal",
                &BTreeMap::from([("writer-a".to_string(), through)]),
            )
            .await
            .unwrap();
        let weak = Arc::downgrade(&engine);
        engine
            .set_photograph_cut_barrier(Arc::new(move || {
                let engine = weak.upgrade().unwrap();
                Box::pin(async move {
                    let store = engine.pin_log.pin_log_store().await?;
                    assert!(store.get(BACKUP_RESTORE_F_KEY).await.unwrap().is_none());
                    // A confirmation during the barrier must not raise this cut's F.
                    engine
                        .pin_log
                        .persist_published_f(
                            "personal",
                            &BTreeMap::from([("writer-a".to_string(), through + 100)]),
                        )
                        .await
                })
            }))
            .await;
        engine.prepare_backup_restore_frontier().await.unwrap();
        let frontier = engine.restored_backup_mutation_frontier().await.unwrap();
        let keys = [
            format!("log/writer-a/{through}.enc"),
            format!("log/writer-a/{}.enc", through + 1),
            "log/unknown-writer/1.enc".to_string(),
        ];
        let (requests, _) =
            select_peer_apply_candidates(keys.iter().map(String::as_str), &frontier);
        assert_eq!(
            requests
                .iter()
                .map(|(w, f, _)| (w.as_str(), *f))
                .collect::<Vec<_>>(),
            vec![("unknown-writer", 1), ("writer-a", through + 1)]
        );
        assert!(frontier.covers_log(Some("writer-a"), through));
        assert!(!frontier.covers_log(Some("writer-a"), through + 100));
    }

    #[tokio::test]
    async fn backup_restore_frontier_never_uses_an_unpinned_published_map() {
        let engine = test_engine(SyncConfig::default());
        engine
            .pin_log
            .persist_published_f(
                "personal",
                &BTreeMap::from([("writer-a".to_string(), u64::MAX)]),
            )
            .await
            .unwrap();
        let frontier = engine.restored_backup_mutation_frontier().await.unwrap();
        assert!(!frontier.covers_log(Some("writer-a"), 1));
        assert!(
            engine.prepare_backup_restore_frontier().await.is_err(),
            "a nonempty frontier needs a real persistence barrier"
        );
    }

    #[tokio::test]
    async fn backup_restore_frontier_failed_barrier_keeps_the_prior_marker() {
        let engine = test_engine(SyncConfig::default());
        engine.prepare_backup_restore_frontier().await.unwrap();
        let store = engine.pin_log.pin_log_store().await.unwrap();
        let before = store.get(BACKUP_RESTORE_F_KEY).await.unwrap();
        engine
            .pin_log
            .persist_published_f("personal", &BTreeMap::from([("writer-a".to_string(), 10)]))
            .await
            .unwrap();
        engine
            .set_photograph_cut_barrier(Arc::new(|| {
                Box::pin(async { Err("injected pending-write barrier failure".to_string()) })
            }))
            .await;
        assert!(engine.prepare_backup_restore_frontier().await.is_err());
        assert_eq!(store.get(BACKUP_RESTORE_F_KEY).await.unwrap(), before);
    }

    #[tokio::test]
    async fn backup_restore_frontier_rejects_malformed_or_unknown_markers() {
        let engine = test_engine(SyncConfig::default());
        let store = engine.pin_log.pin_log_store().await.unwrap();
        for raw in [
            b"not-json".as_slice(),
            br#"{"version":2,"by_writer":{}}"#,
            br#"{"version":1,"by_writer":{"":7}}"#,
        ] {
            store.put(BACKUP_RESTORE_F_KEY, raw.to_vec()).await.unwrap();
            assert!(engine.restored_backup_mutation_frontier().await.is_err());
        }
    }

    #[tokio::test]
    async fn failed_peer_hwm_persist_cannot_advance_runtime_or_exact_wait() {
        let engine = test_engine(SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        let (targets, _) = engine.target_config_snapshot().await;
        engine
            .pin_log
            .ensure_continuous_mutation_log_for_targets(&targets)
            .await
            .unwrap();
        let positions = vec![MutationLogTargetPosition {
            target_id: "personal".to_string(),
            target_label: "personal".to_string(),
            writer_id: "peer-writer".to_string(),
            frontier: 42,
        }];
        engine
            .pin_log
            .force_next_published_f_persist_err
            .store(true, std::sync::atomic::Ordering::SeqCst);

        let error = engine
            .pin_log
            .incorporate_applied_frontier(&BTreeMap::from([("peer-writer".to_string(), 42)]))
            .await
            .expect_err("the injected HWM barrier must fail");
        assert!(error.contains("injected durable published-F"));
        assert_eq!(
            engine
                .pin_log
                .state
                .lock()
                .await
                .get("personal")
                .and_then(|runtime| runtime.published_f_by_writer.get("peer-writer"))
                .copied(),
            None,
            "a failed durable HWM write advanced the volatile waiter state"
        );
        assert_eq!(
            engine
                .wait_for_mutation_publication(&positions, Duration::ZERO)
                .await,
            MutationPublicationWait::Pending,
            "the exact waiter observed a frontier that never crossed the durable HWM barrier"
        );

        engine
            .pin_log
            .incorporate_applied_frontier(&BTreeMap::from([("peer-writer".to_string(), 42)]))
            .await
            .expect("the retry must persist before it advances runtime");
        assert_eq!(
            engine
                .wait_for_mutation_publication(&positions, Duration::ZERO)
                .await,
            MutationPublicationWait::Published
        );
    }

    #[tokio::test]
    async fn publication_receipt_requires_the_exact_writer_on_every_target() {
        let engine = test_engine(SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        let positions = vec![
            MutationLogTargetPosition {
                target_id: "personal".to_string(),
                target_label: "personal".to_string(),
                writer_id: "writer-a".to_string(),
                frontier: 42,
            },
            MutationLogTargetPosition {
                target_id: "org-target".to_string(),
                target_label: "org".to_string(),
                writer_id: "writer-a".to_string(),
                frontier: 42,
            },
        ];
        {
            let mut state = engine.pin_log.state.lock().await;
            for (target_id, label) in [("personal", "personal"), ("org-target", "org")] {
                state.insert(
                    target_id.to_string(),
                    PinLogRuntime::new(
                        target_id.to_string(),
                        label.to_string(),
                        String::new(),
                        0,
                        0,
                        true,
                    ),
                );
            }
            state
                .get_mut("personal")
                .unwrap()
                .advance_published_f("writer-b", 999, 1);
        }
        assert_eq!(
            engine
                .wait_for_mutation_publication(&positions, Duration::ZERO)
                .await,
            MutationPublicationWait::Pending,
            "another writer's larger frontier must not satisfy the receipt"
        );

        engine
            .pin_log
            .state
            .lock()
            .await
            .get_mut("personal")
            .unwrap()
            .advance_published_f("writer-a", 42, 2);
        assert_eq!(
            engine
                .wait_for_mutation_publication(&positions, Duration::ZERO)
                .await,
            MutationPublicationWait::Pending,
            "one confirmed target must not stand in for every required target"
        );

        engine
            .pin_log
            .state
            .lock()
            .await
            .get_mut("org-target")
            .unwrap()
            .advance_published_f("writer-a", 42, 3);
        assert_eq!(
            engine
                .wait_for_mutation_publication(&positions, Duration::ZERO)
                .await,
            MutationPublicationWait::Published
        );
    }

    #[test]
    fn exact_publication_wait_has_no_engine_wide_failure_gate() {
        let source = include_str!("pin_log.rs");
        let start = source
            .find("pub(crate) async fn wait_for_mutation_publication")
            .expect("exact publication wait function");
        let tail = &source[start..];
        let end = tail
            .find("/// List + download continuous mutation-log segments")
            .expect("next pin-log function section");
        let wait_body = &tail[..end];

        for unrelated in ["consecutive_sync_failures", "last_error"] {
            assert!(
                !wait_body.contains(unrelated),
                "exact target publication wait consulted engine-wide state: {unrelated}"
            );
        }
    }

    #[tokio::test]
    async fn restart_mints_writer_frontier_above_every_durable_published_hwm() {
        use crate::sync::log::LogOp;

        let store: Arc<dyn NamespacedStore> = Arc::new(InMemoryNamespacedStore::new());
        let config = SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            legacy_personal_cloud_sync: false,
            ..SyncConfig::default()
        };
        let before_restart = test_engine_with_store(Arc::clone(&store), config.clone());
        let wall_clock = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        let durable_hwm = wall_clock.saturating_add(1_000_000_000);
        before_restart
            .pin_log
            .persist_published_f(
                "personal",
                &BTreeMap::from([("test-device".to_string(), durable_hwm)]),
            )
            .await
            .unwrap();
        drop(before_restart);

        let restarted = test_engine_with_store(store, config);
        let entry = restarted
            .make_entry(LogOp::Delete {
                namespace: "main".to_string(),
                key: LogOp::encode_bytes(b"after-restart"),
            })
            .await
            .expect("mint frontier after restart");
        assert!(
            entry.seq > durable_hwm,
            "frontier {} reused a cloud-confirmed HWM {durable_hwm}",
            entry.seq
        );
    }

    #[tokio::test]
    async fn restart_mints_above_removed_target_pending_row_without_allocation_floor() {
        use crate::sync::log::{LogEntry, LogOp};

        let store: Arc<dyn NamespacedStore> = Arc::new(InMemoryNamespacedStore::new());
        let config = SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            legacy_personal_cloud_sync: false,
            ..SyncConfig::default()
        };
        let wall_clock = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        let pending_frontier = wall_clock.saturating_add(1_000_000_000);
        let pending_entry = LogEntry {
            seq: pending_frontier,
            timestamp_ms: 1,
            device_id: "older-writer".to_string(),
            op: LogOp::Delete {
                namespace: "main".to_string(),
                key: LogOp::encode_bytes(b"older-pending-delete"),
            },
        };
        let pending_record = PinLogRecord {
            model_version: PIN_LOG_MODEL_VERSION,
            target_id: "removed-target".to_string(),
            target_label: "removed target".to_string(),
            target_prefix: "removed-prefix".to_string(),
            writer_id: pending_entry.device_id.clone(),
            frontier_after: pending_frontier,
            timestamp_ms: pending_entry.timestamp_ms,
            entry: pending_entry,
        };
        let pin_store = store.open_namespace(PIN_LOG_NAMESPACE).await.unwrap();
        let pending_key = pin_log_entry_key("removed-target", pending_frontier);
        pin_store
            .put(&pending_key, serde_json::to_vec(&pending_record).unwrap())
            .await
            .unwrap();
        pin_store.flush().await.unwrap();
        assert!(
            pin_store
                .get(PIN_LOG_APPENDED_F_KEY)
                .await
                .unwrap()
                .is_none(),
            "the fixture must model an old home without an allocation floor"
        );

        let restarted = test_engine_with_store(store, config);
        let minted = restarted
            .record_delete("main", b"new-delete-after-clock-rollback")
            .await
            .expect("seed from the legacy pending-row fold and append");
        assert!(
            minted > pending_frontier,
            "new frontier {minted} collided with old pending frontier {pending_frontier}"
        );
        assert!(
            pin_store.get(&pending_key).await.unwrap().is_some(),
            "the new personal append overwrote a removed target's pending row"
        );
        assert!(
            pin_store
                .get(&pin_log_entry_key("personal", minted))
                .await
                .unwrap()
                .is_some(),
            "the new personal append did not persist its own pin row"
        );
        let allocation_floor = pin_store.get(PIN_LOG_APPENDED_F_KEY).await.unwrap();
        let allocation_floor = u64::from_be_bytes(
            allocation_floor
                .expect("the first upgraded append must persist its allocation floor")
                .try_into()
                .unwrap(),
        );
        assert_eq!(allocation_floor, minted);
    }

    #[tokio::test]
    async fn restart_after_rollback_revalidates_stale_global_allocation_floor() {
        use crate::sync::log::{LogEntry, LogOp};

        let store: Arc<dyn NamespacedStore> = Arc::new(InMemoryNamespacedStore::new());
        let config = SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            legacy_personal_cloud_sync: false,
            ..SyncConfig::default()
        };
        let wall_clock = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        let stale_floor = wall_clock.saturating_sub(1_000_000_000);
        let rollback_frontier = wall_clock.saturating_add(1_000_000_000);
        let rollback_entry = LogEntry {
            seq: rollback_frontier,
            timestamp_ms: 1,
            device_id: "rollback-writer".to_string(),
            op: LogOp::Delete {
                namespace: "main".to_string(),
                key: LogOp::encode_bytes(b"delete-written-by-older-binary"),
            },
        };
        let rollback_record = PinLogRecord {
            model_version: PIN_LOG_MODEL_VERSION,
            target_id: "removed-rollback-target".to_string(),
            target_label: "removed rollback target".to_string(),
            target_prefix: "removed-rollback-prefix".to_string(),
            writer_id: rollback_entry.device_id.clone(),
            frontier_after: rollback_frontier,
            timestamp_ms: rollback_entry.timestamp_ms,
            entry: rollback_entry,
        };
        let pin_store = store.open_namespace(PIN_LOG_NAMESPACE).await.unwrap();
        let rollback_key = pin_log_entry_key("removed-rollback-target", rollback_frontier);

        // A new binary wrote the point row, then an older binary ran during a
        // rollback interval and appended a higher pin row without updating it.
        pin_store
            .put(PIN_LOG_APPENDED_F_KEY, stale_floor.to_be_bytes().to_vec())
            .await
            .unwrap();
        pin_store.flush().await.unwrap();
        pin_store
            .put(&rollback_key, serde_json::to_vec(&rollback_record).unwrap())
            .await
            .unwrap();
        pin_store.flush().await.unwrap();

        let upgraded_again = test_engine_with_store(store, config);
        let minted = upgraded_again
            .record_delete("main", b"delete-after-re-upgrade")
            .await
            .expect("first re-upgrade append must validate the stale point floor");
        assert!(
            minted > rollback_frontier,
            "re-upgrade trusted stale appended-F {stale_floor} and minted {minted} at or below rollback row {rollback_frontier}"
        );
        assert!(
            pin_store.get(&rollback_key).await.unwrap().is_some(),
            "re-upgrade must retain the older binary's pending row"
        );
        let repaired_floor = pin_store
            .get(PIN_LOG_APPENDED_F_KEY)
            .await
            .unwrap()
            .expect("re-upgrade append must repair the global floor");
        assert_eq!(
            u64::from_be_bytes(repaired_floor.try_into().unwrap()),
            minted
        );
    }

    #[tokio::test]
    async fn readded_target_hwm_reseeds_the_writer_frontier() {
        let engine = test_engine(SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            legacy_personal_cloud_sync: false,
            ..SyncConfig::default()
        });
        engine
            .record_put("main", b"seed-initial-generation", b"v")
            .await
            .unwrap();
        let target_prefix = "a".repeat(64);
        let target = SyncTarget {
            label: "readded-target".to_string(),
            prefix: target_prefix.clone(),
            crypto: Arc::new(LocalCryptoProvider::from_key([0x44u8; 32])),
        };
        engine
            .configure_targets(SyncPartitioner::empty(), vec![target.clone()])
            .await;
        engine
            .configure_targets(SyncPartitioner::empty(), Vec::new())
            .await;
        let wall_clock = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        let durable_hwm = wall_clock.saturating_add(1_000_000_000);
        engine
            .pin_log
            .persist_published_f(
                &target_id_for_prefix(&target_prefix),
                &BTreeMap::from([("test-device".to_string(), durable_hwm)]),
            )
            .await
            .unwrap();
        engine
            .configure_targets(SyncPartitioner::empty(), vec![target])
            .await;

        let minted = engine
            .record_put("main", b"after-target-readd", b"v")
            .await
            .expect("re-added target HWM must seed allocation");
        assert!(
            minted > durable_hwm,
            "re-added target HWM {durable_hwm} falsely covered frontier {minted}"
        );
    }

    #[tokio::test]
    async fn target_reconfigure_waits_until_frontier_and_pin_row_are_durable() {
        let engine = Arc::new(test_engine(SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            legacy_personal_cloud_sync: false,
            ..SyncConfig::default()
        }));
        let target_prefix = "b".repeat(64);
        let target_id = target_id_for_prefix(&target_prefix);
        let wall_clock = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos() as u64;
        let future_hwm = wall_clock.saturating_add(1_000_000_000);
        engine
            .pin_log
            .persist_published_f(
                &target_id,
                &BTreeMap::from([("test-device".to_string(), future_hwm)]),
            )
            .await
            .unwrap();
        let append_guard = engine.pin_log.append_lock.lock().await;
        let writer = {
            let engine = Arc::clone(&engine);
            tokio::spawn(
                async move { engine.record_put("main", b"before-reconfigure", b"v").await },
            )
        };

        let mut writer_holds_config = false;
        for _ in 0..1_000 {
            if engine.target_config_lock.try_lock().is_err() {
                writer_holds_config = true;
                break;
            }
            tokio::task::yield_now().await;
        }
        assert!(
            writer_holds_config,
            "the writer did not reach the append barrier while it held target configuration"
        );
        let target = SyncTarget {
            label: "concurrent-target".to_string(),
            prefix: target_prefix,
            crypto: Arc::new(LocalCryptoProvider::from_key([0x55u8; 32])),
        };
        let reconfigure = {
            let engine = Arc::clone(&engine);
            tokio::spawn(async move {
                engine
                    .configure_targets(SyncPartitioner::empty(), vec![target])
                    .await;
            })
        };
        for _ in 0..32 {
            tokio::task::yield_now().await;
        }
        assert!(
            !reconfigure.is_finished(),
            "target configuration changed before the old snapshot's pin row was durable"
        );

        drop(append_guard);
        writer.await.unwrap().unwrap();
        reconfigure.await.unwrap();
        let after_reconfigure = engine
            .record_put("main", b"after-concurrent-reconfigure", b"v")
            .await
            .unwrap();
        assert!(
            after_reconfigure > future_hwm,
            "the first write under the new target set did not seed its durable HWM"
        );
    }

    #[tokio::test]
    async fn vector_f_does_not_seed_missing_writer_from_peer_hwm() {
        use crate::sync::log::{LogEntry, LogOp};

        let engine = test_engine(SyncConfig {
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        let sealed = seal_mutation_log_segment(
            &PinLogRecord {
                model_version: 1,
                target_id: "personal".to_string(),
                target_label: "personal".to_string(),
                target_prefix: String::new(),
                writer_id: "peer-device".to_string(),
                frontier_after: 2,
                timestamp_ms: 1,
                entry: LogEntry {
                    seq: 2,
                    timestamp_ms: 1,
                    device_id: "peer-device".to_string(),
                    op: LogOp::Put {
                        namespace: "main".to_string(),
                        key: LogOp::encode_bytes(b"peer-key"),
                        value: LogOp::encode_bytes(b"peer-value"),
                    },
                },
            },
            &engine.crypto,
        )
        .await
        .unwrap();
        // One-entry vector F used to be treated as scalar: writer-a's 99 would
        // seed peer-device and skip through_id=2. Missing writers stay at 0.
        let incorporated = Frontier::from_writer_hwm([("writer-a".to_string(), 99)]);
        let report = restore_mutation_log_after_s0(&engine, &[sealed], &incorporated)
            .await
            .expect("replay peer segment");
        assert_eq!(report.segments_applied, 1, "{report:?}");
        assert_eq!(report.records_applied, 1, "{report:?}");
        assert_eq!(report.records_skipped_at_or_below_frontier, 0);
        let main = engine.store.open_namespace("main").await.unwrap();
        assert_eq!(
            main.get(b"peer-key").await.unwrap().as_deref(),
            Some(b"peer-value".as_slice())
        );
    }

    fn test_engine(config: SyncConfig) -> SyncEngine {
        test_engine_with_device("test-device", config)
    }

    /// Phase B multi-writer harness: each device id becomes the durable
    /// `writer_id` on pin-log records and `log/{writer_id}/` segment keys.
    fn test_engine_with_device(device_id: &str, config: SyncConfig) -> SyncEngine {
        let http = Arc::new(reqwest::Client::new());
        let auth = AuthClient::new(
            Arc::clone(&http),
            "http://127.0.0.1:1".to_string(),
            SyncAuth::ApiKey("test-key".to_string()),
        );
        let s3 = S3Client::new(http);
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x77u8; 32]));
        let store: Arc<dyn NamespacedStore> = Arc::new(InMemoryNamespacedStore::new());
        let signer = Arc::new(Ed25519KeyPair::generate().unwrap());
        SyncEngine::new(
            device_id.to_string(),
            crypto,
            s3,
            auth,
            store,
            config,
            signer,
        )
    }

    #[test]
    fn non_personal_target_id_is_stable_hash_not_raw_prefix() {
        let prefix = "a".repeat(64);
        let id = target_id_for_prefix(&prefix);
        assert_eq!(id.len(), 64);
        assert_ne!(id, prefix);
        assert_eq!(target_id_for_prefix(""), "personal");
    }

    /// `NamespacedStore` that records which collections were compacted.
    ///
    /// `InMemoryNamespacedStore` inherits the trait's "unsupported" default for
    /// `compact_collection`, which is the right default for a backend with no
    /// segments — but it makes "did we ask?" indistinguishable from "did it
    /// work?". This wrapper answers the first question.
    struct CompactRecordingStore {
        inner: InMemoryNamespacedStore,
        compacted: Arc<std::sync::Mutex<Vec<String>>>,
        /// What `collection_disk_bytes` reports, and how many times it was
        /// asked. `None` models a backend with no per-collection placement.
        disk_bytes: Option<u64>,
        disk_bytes_probes: Arc<std::sync::atomic::AtomicU64>,
        /// `bytes_after` this store's compaction reports. Non-zero models a
        /// plane whose content is genuinely live, so a rewrite reclaims nothing.
        compact_bytes_after: u64,
    }

    impl CompactRecordingStore {
        fn recording_pair() -> (Arc<dyn NamespacedStore>, Arc<std::sync::Mutex<Vec<String>>>) {
            let (store, compacted, _) = Self::recording_triple(None);
            (store, compacted)
        }

        /// Recording store that also answers the on-disk bloat probe.
        ///
        /// Returns the probe counter as well, so a test can assert the stat walk
        /// is rate-limited rather than run every publish cycle.
        #[allow(clippy::type_complexity)]
        fn recording_triple(
            disk_bytes: Option<u64>,
        ) -> (
            Arc<dyn NamespacedStore>,
            Arc<std::sync::Mutex<Vec<String>>>,
            Arc<std::sync::atomic::AtomicU64>,
        ) {
            Self::recording_triple_reclaiming_to(disk_bytes, 0)
        }

        /// As above, but the compaction reports `compact_bytes_after` instead of
        /// collapsing the plane to nothing.
        #[allow(clippy::type_complexity)]
        fn recording_triple_reclaiming_to(
            disk_bytes: Option<u64>,
            compact_bytes_after: u64,
        ) -> (
            Arc<dyn NamespacedStore>,
            Arc<std::sync::Mutex<Vec<String>>>,
            Arc<std::sync::atomic::AtomicU64>,
        ) {
            let compacted = Arc::new(std::sync::Mutex::new(Vec::new()));
            let probes = Arc::new(std::sync::atomic::AtomicU64::new(0));
            let store: Arc<dyn NamespacedStore> = Arc::new(Self {
                inner: InMemoryNamespacedStore::new(),
                compacted: Arc::clone(&compacted),
                disk_bytes,
                disk_bytes_probes: Arc::clone(&probes),
                compact_bytes_after,
            });
            (store, compacted, probes)
        }
    }

    #[async_trait::async_trait]
    impl NamespacedStore for CompactRecordingStore {
        async fn open_namespace(
            &self,
            name: &str,
        ) -> crate::storage::error::StorageResult<Arc<dyn crate::storage::traits::KvStore>>
        {
            self.inner.open_namespace(name).await
        }

        async fn list_namespaces(&self) -> crate::storage::error::StorageResult<Vec<String>> {
            self.inner.list_namespaces().await
        }

        async fn delete_namespace(&self, name: &str) -> crate::storage::error::StorageResult<bool> {
            self.inner.delete_namespace(name).await
        }

        async fn compact_collection(
            &self,
            options: crate::storage::laststore::CollectionCompactOptions,
        ) -> crate::storage::error::StorageResult<crate::storage::laststore::CollectionCompactReport>
        {
            self.compacted
                .lock()
                .unwrap()
                .push(options.collection.clone());
            Ok(crate::storage::laststore::CollectionCompactReport {
                collection: options.collection,
                dry_run: options.dry_run,
                live_keys: 0,
                bytes_before: 0,
                bytes_after: Some(self.compact_bytes_after),
                never_compact: false,
                compactable_here: true,
                executed: !options.dry_run,
                skipped_reason: None,
                live_bytes: None,
                dead_bytes: None,
                residue_unknown_bytes: None,
            })
        }

        fn collection_disk_bytes(&self, _collection: &str) -> Option<u64> {
            self.disk_bytes_probes
                .fetch_add(1, std::sync::atomic::Ordering::Relaxed);
            self.disk_bytes
        }
    }

    async fn pin_log_with_seeded_rows(
        compact_after_rows: u64,
        target_id: &str,
        frontiers: &[u64],
    ) -> (PinLog, Arc<std::sync::Mutex<Vec<String>>>) {
        let (store, compacted) = CompactRecordingStore::recording_pair();
        let namespace = store.open_namespace(PIN_LOG_NAMESPACE).await.unwrap();
        for frontier in frontiers {
            namespace
                .put(&pin_log_entry_key(target_id, *frontier), b"row".to_vec())
                .await
                .unwrap();
        }
        let pin_log = PinLog::new(
            store,
            SyncConfig::default(),
            Arc::new(Mutex::new(Vec::new())),
        )
        .with_compact_after_rows(compact_after_rows);
        (pin_log, compacted)
    }

    /// Truncation alone never returns a byte, so it must lead to a compaction.
    ///
    /// `LastStore::delete` appends a delete line and leaves the original record
    /// in the segment. On the primary that made `sync_pin_log` grow 21,389 ->
    /// 21,621 MiB in 91 minutes *while sync was healthy and truncation was
    /// firing every cycle*. Deleting confirmed rows without compacting after
    /// them is the leak, not the fix.
    #[tokio::test]
    async fn confirmed_truncation_compacts_the_pin_log_plane() {
        let (pin_log, compacted) = pin_log_with_seeded_rows(3, "personal", &[1, 2, 3, 4]).await;

        // Two confirmed rows: below the threshold, nothing is rewritten yet.
        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2])
            .await;
        assert_eq!(removed, 2);
        assert!(
            compacted.lock().unwrap().is_empty(),
            "compaction fired before the truncation budget was reached; a full \
             plane rewrite per delete is not affordable"
        );

        // Crossing the threshold rewrites the plane exactly once.
        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[3, 4])
            .await;
        assert_eq!(removed, 2);
        assert_eq!(
            compacted.lock().unwrap().as_slice(),
            [PIN_LOG_NAMESPACE.to_string()],
            "confirmed truncation did not compact the pin-log plane, so its \
             deleted rows stay on disk forever"
        );
    }

    /// A cycle that confirmed nothing must not rewrite the plane.
    ///
    /// Truncation runs after every successful publish, and most publishes
    /// confirm frontiers that were already deleted (`Ok(false)`). Compacting on
    /// those would pay a full-plane rewrite per sync cycle for zero reclaim.
    #[tokio::test]
    async fn truncation_that_removed_nothing_does_not_compact() {
        let (pin_log, compacted) = pin_log_with_seeded_rows(1, "personal", &[]).await;

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2, 3])
            .await;
        assert_eq!(removed, 0, "no rows were seeded, so none can be removed");
        assert!(
            compacted.lock().unwrap().is_empty(),
            "compacted the plane after a cycle that reclaimed nothing"
        );
    }

    #[tokio::test]
    async fn mixed_pre_intent_and_intent_records_truncate_after_confirm() {
        use crate::schema::types::key_value::KeyValue;
        use crate::schema::types::operations::MutationType;
        use crate::schema::types::Mutation;
        use crate::sync::log::{LogEntry, LogOp};
        use serde_json::json;
        use std::collections::HashMap;

        let store: Arc<dyn NamespacedStore> = Arc::new(InMemoryNamespacedStore::new());
        let pin_log = PinLog::new(
            Arc::clone(&store),
            SyncConfig::default(),
            Arc::new(Mutex::new(Vec::new())),
        )
        .with_compact_after_rows(u64::MAX);

        let put_entry = LogEntry {
            seq: 1,
            timestamp_ms: 10,
            device_id: "dev".to_string(),
            op: LogOp::Put {
                namespace: "main".to_string(),
                key: "bWs6dGlw".to_string(),
                value: "ZmF0LWJvZHk=".to_string(),
            },
        };
        let mut fields = HashMap::new();
        fields.insert("title".to_string(), json!("hello"));
        let mutation = Mutation::new(
            "Note".to_string(),
            fields,
            KeyValue::new(Some("n1".to_string()), None),
            "pk".to_string(),
            MutationType::Update,
        );
        let intent_entry = LogEntry {
            seq: 2,
            timestamp_ms: 11,
            device_id: "dev".to_string(),
            op: crate::sync::mutation_intent::mutation_intent_op(
                crate::sync::mutation_intent::encode_mutations(
                    std::slice::from_ref(&mutation),
                    None,
                ),
            ),
        };

        let record = |entry: LogEntry| PinLogRecord {
            model_version: PIN_LOG_MODEL_VERSION,
            target_id: "personal".to_string(),
            target_label: "personal".to_string(),
            target_prefix: String::new(),
            writer_id: entry.device_id.clone(),
            frontier_after: entry.seq,
            timestamp_ms: entry.timestamp_ms,
            entry,
        };
        pin_log
            .persist_pin_log_records(&[record(put_entry), record(intent_entry)])
            .await
            .expect("persist mixed pin-log records");

        let before = pin_log
            .inventory_pin_log_kinds("personal")
            .await
            .expect("inventory before");
        assert_eq!(before.records, 2);
        assert_eq!(before.pre_intent_records(), 1);
        assert_eq!(before.intent_records(), 1);
        assert!(before.bytes > 0);

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2])
            .await;
        assert_eq!(removed, 2, "confirm must delete both pre-intent and intent");

        let after = pin_log
            .inventory_pin_log_kinds("personal")
            .await
            .expect("inventory after");
        assert_eq!(after.records, 0);
        assert_eq!(after.pre_intent_records(), 0);
        assert_eq!(after.intent_records(), 0);
        assert_eq!(after.bytes, 0);
    }

    /// `LASTDB_PIN_LOG_COMPACT_AFTER_ROWS=0` hands reclaim back to the operator.
    #[tokio::test]
    async fn zero_threshold_disables_self_compaction() {
        let (pin_log, compacted) = pin_log_with_seeded_rows(0, "personal", &[1, 2, 3]).await;

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2, 3])
            .await;
        assert_eq!(removed, 3);
        assert!(
            compacted.lock().unwrap().is_empty(),
            "self-compaction is meant to be fully disableable"
        );
    }

    fn test_engine_with_store(store: Arc<dyn NamespacedStore>, config: SyncConfig) -> SyncEngine {
        let http = Arc::new(reqwest::Client::new());
        let auth = AuthClient::new(
            Arc::clone(&http),
            "http://127.0.0.1:1".to_string(),
            SyncAuth::ApiKey("test-key".to_string()),
        );
        let s3 = S3Client::new(http);
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x77u8; 32]));
        let signer = Arc::new(Ed25519KeyPair::generate().unwrap());
        SyncEngine::new(
            "test-device".to_string(),
            crypto,
            s3,
            auth,
            store,
            config,
            signer,
        )
    }

    /// Pin-log self-compact is a compaction entry point. A held photograph
    /// cut is a packing lock: rewriting `sync_pin_log` sealed files under it
    /// is the same 08-08 staged-cut defect as tips/CLI compact.
    #[tokio::test]
    async fn pin_log_does_not_compact_while_a_backup_cut_is_held() {
        let (store, compacted, _) = CompactRecordingStore::recording_triple(Some(21_951_142_027));
        let mut engine = test_engine_with_store(store, SyncConfig::default());
        engine.pin_log.compact_max_plane_bytes = 512 * 1024 * 1024;
        engine.pin_log.compact_bloat_probe_interval_s = 0;
        engine
            .inject_backup_publish_target_for_test(
                crate::storage::laststore::BackupManifest {
                    version: 1,
                    store_uuid: "pin-log-compact-held-test".into(),
                    epoch: 1,
                    counter: 1,
                    previous_manifest_sha256: None,
                    cut_csn: 1,
                    created_at_unix_secs: 1,
                    mutable_chunks: Vec::new(),
                    atom_chunks: Vec::new(),
                    b2_cas_blob_refs: Vec::new(),
                    deletion_receipts: Vec::new(),
                    named_holes: Vec::new(),
                },
                std::iter::empty(),
            )
            .await;

        engine.pin_log.maybe_compact_pin_log_plane(0).await;

        assert!(
            compacted.lock().unwrap().is_empty(),
            "pin-log self-compact must defer while a backup cut is held"
        );
    }

    /// Pin log over a store that reports on-disk bytes for the bloat probe.
    fn pin_log_over_plane_of(
        disk_bytes: Option<u64>,
        compact_after_rows: u64,
        max_plane_bytes: u64,
    ) -> (
        PinLog,
        Arc<std::sync::Mutex<Vec<String>>>,
        Arc<std::sync::atomic::AtomicU64>,
    ) {
        let (store, compacted, probes) = CompactRecordingStore::recording_triple(disk_bytes);
        let pin_log = PinLog::new(
            store,
            SyncConfig::default(),
            Arc::new(Mutex::new(Vec::new())),
        )
        .with_compact_after_rows(compact_after_rows)
        .with_compact_max_plane_bytes(max_plane_bytes)
        .with_compact_bloat_probe_interval_s(0);
        (pin_log, compacted, probes)
    }

    /// The row budget is process-local, so it cannot bound the plane.
    ///
    /// `truncated_since_compact` is an in-memory counter. A restart zeroes it,
    /// and the primary restarts for safe upgrades and memory-guard events more
    /// often than a publish stream refills 20,000 confirmed rows. Measured on
    /// the primary 2026-08-17T06:52Z, 43 minutes into a start with
    /// `degraded=false` and `log_lag=0`: `sync_pin_log` held **20.4 GiB behind
    /// `live_keys: 1`** — 52% of a 39 GiB store — with `never_compact: false`,
    /// `skipped_reason: null`, and zero pin-log lines in the daemon log.
    /// Compaction was permitted, would have collapsed the plane to one record,
    /// and had never been attempted.
    ///
    /// A fresh `PinLog` — which is what every restart produces — must therefore
    /// compact an already-bloated plane on its first cycle, without waiting to
    /// re-earn a budget it can never keep.
    #[tokio::test]
    async fn inherited_bloat_compacts_on_the_first_cycle_after_a_restart() {
        // Row budget deliberately far out of reach, as it is in production.
        let (pin_log, compacted, _) =
            pin_log_over_plane_of(Some(21_951_142_027), 20_000, 512 * 1024 * 1024);
        let namespace = pin_log
            .store
            .open_namespace(PIN_LOG_NAMESPACE)
            .await
            .unwrap();
        namespace
            .put(&pin_log_entry_key("personal", 1), b"row".to_vec())
            .await
            .unwrap();

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1])
            .await;

        assert_eq!(removed, 1, "one seeded row was confirmed");
        assert_eq!(
            compacted.lock().unwrap().as_slice(),
            [PIN_LOG_NAMESPACE.to_string()],
            "a 20.4 GiB plane behind one live record was left uncompacted \
             because a process-local row counter had not refilled"
        );
    }

    /// Bloat left by an earlier process is invisible to the row counter.
    ///
    /// A cycle whose confirmed frontiers were all already deleted removes zero
    /// rows. That is the common case once the plane is logically drained — and
    /// it is exactly when the dead segment bytes are largest.
    #[tokio::test]
    async fn plane_over_its_cap_compacts_even_when_the_cycle_removed_nothing() {
        let (pin_log, compacted, _) =
            pin_log_over_plane_of(Some(4 * 1024 * 1024 * 1024), 1, 512 * 1024 * 1024);

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2, 3])
            .await;

        assert_eq!(removed, 0, "no rows were seeded, so none can be removed");
        assert_eq!(
            compacted.lock().unwrap().as_slice(),
            [PIN_LOG_NAMESPACE.to_string()],
            "the plane is 8x over its cap and nothing else will ever reclaim it"
        );
    }

    /// A plane inside its cap pays no rewrite. The cap is a ceiling, not a
    /// schedule.
    #[tokio::test]
    async fn plane_within_its_cap_is_not_compacted() {
        let (pin_log, compacted, _) =
            pin_log_over_plane_of(Some(64 * 1024 * 1024), 20_000, 512 * 1024 * 1024);

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2, 3])
            .await;

        assert_eq!(removed, 0);
        assert!(
            compacted.lock().unwrap().is_empty(),
            "compacted a plane that is well inside its byte cap"
        );
    }

    /// `LASTDB_PIN_LOG_COMPACT_MAX_BYTES=0` disables the size trigger only.
    ///
    /// The row budget must still work, so an operator who turns the size cap off
    /// keeps the behaviour that shipped before it existed.
    #[tokio::test]
    async fn zero_byte_cap_disables_the_size_trigger_but_not_the_row_budget() {
        let (pin_log, compacted, probes) = pin_log_over_plane_of(Some(21_951_142_027), 1, 0);
        let namespace = pin_log
            .store
            .open_namespace(PIN_LOG_NAMESPACE)
            .await
            .unwrap();
        namespace
            .put(&pin_log_entry_key("personal", 7), b"row".to_vec())
            .await
            .unwrap();

        // Nothing to remove: the size trigger is off, so no compaction.
        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1])
            .await;
        assert_eq!(removed, 0);
        assert!(
            compacted.lock().unwrap().is_empty(),
            "size trigger fired with the cap set to 0"
        );
        assert_eq!(
            probes.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "a disabled cap must not even pay for the stat walk"
        );

        // The row budget still reclaims.
        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[7])
            .await;
        assert_eq!(removed, 1);
        assert_eq!(
            compacted.lock().unwrap().as_slice(),
            [PIN_LOG_NAMESPACE.to_string()],
            "disabling the size cap also disabled the row budget"
        );
    }

    /// A backend that cannot measure bytes must not read as "zero bytes".
    ///
    /// `None` means "cannot tell". Treating it as 0 would be harmless here, but
    /// treating it as "over the cap" would rewrite the plane every cycle.
    #[tokio::test]
    async fn backend_that_cannot_measure_bytes_falls_back_to_the_row_budget() {
        let (pin_log, compacted, _) = pin_log_over_plane_of(None, 20_000, 512 * 1024 * 1024);

        let removed = pin_log
            .truncate_confirmed_pin_log_records("personal", &[1, 2, 3])
            .await;

        assert_eq!(removed, 0);
        assert!(
            compacted.lock().unwrap().is_empty(),
            "an unmeasurable plane was treated as over its cap"
        );
    }

    /// A plane the rewrite cannot shrink must not be rewritten every window.
    ///
    /// The cap assumes the live set is near zero, which holds while sync is
    /// healthy. During a long sync outage nothing is confirmed, so nothing can
    /// be truncated, and the plane can legitimately hold more than the cap in
    /// records that must be kept. A naive cap would then rewrite an over-cap
    /// plane every probe interval and reclaim nothing.
    #[tokio::test]
    async fn a_plane_that_cannot_shrink_is_not_rewritten_every_window() {
        let one_gib = 1024 * 1024 * 1024;
        // Probe sees 1 GiB; compaction reports 1 GiB still there — all live.
        let (store, compacted, _) =
            CompactRecordingStore::recording_triple_reclaiming_to(Some(one_gib), one_gib);
        let pin_log = PinLog::new(
            store,
            SyncConfig::default(),
            Arc::new(Mutex::new(Vec::new())),
        )
        .with_compact_after_rows(20_000)
        .with_compact_max_plane_bytes(512 * 1024 * 1024)
        .with_compact_bloat_probe_interval_s(0);

        for _ in 0..10 {
            pin_log
                .truncate_confirmed_pin_log_records("personal", &[1])
                .await;
        }

        assert_eq!(
            compacted.lock().unwrap().len(),
            1,
            "the size cap became a rewrite treadmill on a plane whose content \
             is live: 10 cycles, 10 full-plane rewrites, nothing reclaimed"
        );
    }

    /// The floor is a backoff, not a latch: real growth still triggers.
    #[tokio::test]
    async fn growth_past_the_raised_floor_triggers_another_compaction() {
        let one_gib = 1024 * 1024 * 1024;
        // Plane reads 3 GiB; a rewrite leaves 1 GiB, so the floor becomes 2 GiB
        // — still under the 3 GiB the probe reports, so the next cycle fires.
        let (store, compacted, _) =
            CompactRecordingStore::recording_triple_reclaiming_to(Some(3 * one_gib), one_gib);
        let pin_log = PinLog::new(
            store,
            SyncConfig::default(),
            Arc::new(Mutex::new(Vec::new())),
        )
        .with_compact_after_rows(20_000)
        .with_compact_max_plane_bytes(512 * 1024 * 1024)
        .with_compact_bloat_probe_interval_s(0);

        for _ in 0..3 {
            pin_log
                .truncate_confirmed_pin_log_records("personal", &[1])
                .await;
        }

        assert_eq!(
            compacted.lock().unwrap().len(),
            3,
            "the floor latched shut on a plane still well above it"
        );
    }

    /// The probe is rate-limited: it runs on the publish path.
    ///
    /// With a non-zero interval, repeated cycles inside the window must walk the
    /// directory once, not once per cycle.
    #[tokio::test]
    async fn bloat_probe_is_rate_limited_across_publish_cycles() {
        let (store, compacted, probes) = CompactRecordingStore::recording_triple(Some(1024));
        let pin_log = PinLog::new(
            store,
            SyncConfig::default(),
            Arc::new(Mutex::new(Vec::new())),
        )
        .with_compact_after_rows(20_000)
        .with_compact_max_plane_bytes(512 * 1024 * 1024)
        .with_compact_bloat_probe_interval_s(3_600);

        for _ in 0..5 {
            pin_log
                .truncate_confirmed_pin_log_records("personal", &[1])
                .await;
        }

        assert_eq!(
            probes.load(std::sync::atomic::Ordering::Relaxed),
            1,
            "the stat walk ran once per publish cycle instead of once per window"
        );
        assert!(compacted.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn pin_log_appends_only_active_target_partition() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let org_prefix = "a".repeat(64);
        engine
            .configure_targets(
                SyncPartitioner::new_with_orgs(
                    &[],
                    &[crate::sharing::OrgSyncTarget {
                        org_hash: org_prefix.clone(),
                        storage_prefixes: Vec::new(),
                        unprefixed_schema_names: Vec::new(),
                        e2e_key_b64: base64::engine::general_purpose::STANDARD.encode([7u8; 32]),
                        slug: "org-a".to_string(),
                        active: true,
                        registered_at: "2026-08-01T00:00:00Z".to_string(),
                    }],
                ),
                vec![SyncTarget {
                    label: "org-a".to_string(),
                    prefix: org_prefix.clone(),
                    crypto: Arc::new(LocalCryptoProvider::from_key([7u8; 32])),
                }],
            )
            .await;

        engine
            .pin_log
            .enter_pin_mode_for_target("", 10)
            .await
            .unwrap();
        engine
            .record_batch_put(
                "main",
                &[
                    (b"atom:personal".to_vec(), b"p".to_vec()),
                    (format!("{org_prefix}:atom:org").into_bytes(), b"o".to_vec()),
                ],
            )
            .await
            .unwrap();

        let personal = engine.pin_log.pin_log_records_for_target("").await.unwrap();
        let org = engine
            .pin_log
            .pin_log_records_for_target(&org_prefix)
            .await
            .unwrap();
        assert_eq!(personal.len(), 1);
        assert!(
            org.is_empty(),
            "inactive org target must not receive personal pin entries"
        );
        match &personal[0].entry.op {
            LogOp::BatchPut { items, .. } => assert_eq!(items.len(), 1),
            other => panic!("expected split BatchPut, got {other:?}"),
        }
        let status = engine.status().await;
        assert_eq!(status.pin_logs.len(), 1);
        assert_eq!(status.pin_logs[0].entry_count, 1);
        assert!(status.pin_logs[0].byte_count > 0);
        assert_eq!(
            status.pin_logs[0].last_durable_frontier,
            personal[0].entry.seq
        );
    }

    #[tokio::test]
    async fn pin_log_replay_is_ordered_and_idempotent() {
        let writer = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        writer
            .pin_log
            .enter_pin_mode_for_target("", 0)
            .await
            .unwrap();
        writer.record_put("main", b"k", b"v1").await.unwrap();
        writer.record_put("main", b"k", b"v2").await.unwrap();

        let replayed = writer
            .pin_log
            .replay_pin_log_for_target(&writer, "")
            .await
            .unwrap();
        assert_eq!(replayed, 2);
        let replayed_again = writer
            .pin_log
            .replay_pin_log_for_target(&writer, "")
            .await
            .unwrap();
        assert_eq!(
            replayed_again, 0,
            "the durable materialized frontier must make a no-change replay O(1)"
        );
        let main = writer.store.open_namespace("main").await.unwrap();
        assert_eq!(
            main.get(b"k").await.unwrap().as_deref(),
            Some(b"v2".as_slice())
        );
    }

    #[tokio::test]
    async fn pin_log_materialized_frontier_survives_manager_reopen() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        engine
            .pin_log
            .enter_pin_mode_for_target("", 0)
            .await
            .unwrap();
        engine.record_put("main", b"k", b"v1").await.unwrap();
        engine.record_put("main", b"k", b"v2").await.unwrap();
        assert_eq!(
            engine
                .pin_log
                .replay_pin_log_for_target(&engine, "")
                .await
                .unwrap(),
            2
        );

        // Recreate only the pin-log manager over the same durable store. The
        // replay cursor must come from storage, not process-local runtime state.
        let reopened = PinLog::new(
            Arc::clone(&engine.store),
            engine.config.clone(),
            Arc::clone(&engine.targets),
        );
        assert_eq!(
            reopened
                .replay_pin_log_for_target(&engine, "")
                .await
                .unwrap(),
            0
        );

        engine.record_put("main", b"k", b"v3").await.unwrap();
        assert_eq!(
            reopened
                .replay_pin_log_for_target(&engine, "")
                .await
                .unwrap(),
            1,
            "a reopened manager must replay only the newly appended tail"
        );
    }

    #[tokio::test]
    async fn pin_mode_catchup_enforces_log_from_lower_bound() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        engine
            .pin_log
            .enter_pin_mode_for_target("", 0)
            .await
            .unwrap();
        engine.record_put("main", b"pre", b"v1").await.unwrap();
        let base_frontier = engine.record_put("main", b"pre", b"v2").await.unwrap();

        engine
            .pin_log
            .enter_pin_mode_for_target("", base_frontier)
            .await
            .unwrap();
        engine.record_put("main", b"post", b"v3").await.unwrap();
        engine.record_put("main", b"post", b"v4").await.unwrap();

        let mut plane = PinModeLocalCloud::new();
        let desc = engine
            .pin_log
            .publish_pin_mode_catchup("", &mut plane, &[], 1)
            .await
            .unwrap();
        assert_eq!(desc.log_from, base_frontier);
        assert_eq!(
            plane.log_len("personal"),
            2,
            "catch-up must publish only records strictly newer than log_from"
        );
        assert_eq!(
            engine
                .pin_log
                .pin_log_records_for_target("")
                .await
                .unwrap()
                .len(),
            4,
            "the bounded catch-up read must not discard older durable records"
        );
    }

    #[tokio::test]
    async fn pin_log_ignores_corrupt_trailing_record_only() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        engine
            .pin_log
            .enter_pin_mode_for_target("", 0)
            .await
            .unwrap();
        let first = engine.record_put("main", b"k1", b"v1").await.unwrap();
        let store = engine.pin_log.pin_log_store().await.unwrap();
        store
            .put(
                &pin_log_entry_key("personal", first + 1),
                b"{partial".to_vec(),
            )
            .await
            .unwrap();
        store.flush().await.unwrap();
        assert_eq!(
            engine
                .pin_log
                .pin_log_records_for_target("")
                .await
                .unwrap()
                .len(),
            1
        );

        engine.record_put("main", b"k2", b"v2").await.unwrap();
        let err = engine
            .pin_log
            .pin_log_records_for_target("")
            .await
            .unwrap_err();
        assert!(err.contains("decode durable pin log record"), "{err}");
    }

    #[tokio::test]
    async fn pin_mode_freezes_sealed_base_and_blocks_rewrite_path() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let sealed = vec![
            SealedBaseMember {
                path: "chunks/aa".into(),
                sha256: "a".repeat(64),
                len: 10,
                mtime_secs: 1,
            },
            SealedBaseMember {
                path: "chunks/bb".into(),
                sha256: "b".repeat(64),
                len: 20,
                mtime_secs: 2,
            },
        ];
        let status = engine
            .pin_log
            .enter_pin_mode_for_target_with_sealed_base("", 42, sealed.clone())
            .await
            .unwrap();
        assert!(status.active);
        assert_eq!(status.base_frontier, 42);
        assert_eq!(status.sealed_base_count, 2);
        assert!(status.pin_age_known);
        assert!(status.pin_age_secs.is_some());
        assert!(!status.degraded);
        assert_eq!(
            engine.pin_log.sealed_base_for_target("").await.unwrap(),
            sealed
        );

        // Post-F0 write goes to pin log, not rewrite of S.
        engine.record_put("main", b"post-f0", b"v").await.unwrap();
        assert_eq!(
            engine
                .pin_log
                .pin_log_records_for_target("")
                .await
                .unwrap()
                .len(),
            1
        );

        // Write-path hard refuse for S members.
        let err = engine
            .pin_log
            .attempt_sealed_base_member_rewrite(&"a".repeat(64), b"new")
            .await
            .unwrap_err();
        assert!(err.contains("sealed base refuse"), "{err}");
        let err2 = engine
            .pin_log
            .note_sealed_base_rewrite_attempt("", &"a".repeat(64))
            .await
            .unwrap_err();
        assert!(err2.contains("sealed base refuse"), "{err2}");
        // Empty path_or_sha must not match every sealed member via ends_with("").
        engine
            .pin_log
            .attempt_sealed_base_member_rewrite("", b"empty-probe")
            .await
            .unwrap();
        // Non-S path is allowed.
        engine
            .pin_log
            .attempt_sealed_base_member_rewrite("chunks/not-in-s", b"ok")
            .await
            .unwrap();
        // Missing sealed member is an integrity violation (not silently skipped).
        let broken_missing = engine
            .pin_log
            .check_sealed_base_integrity("", &[("chunks/aa".into(), "a".repeat(64), 10)])
            .await
            .unwrap();
        assert_eq!(
            broken_missing.len(),
            1,
            "bb fully missing from observed must be flagged: {broken_missing:?}"
        );
        assert_eq!(broken_missing[0].path, "chunks/bb");
        // Sha/len mismatch on a present member.
        let broken = engine
            .pin_log
            .check_sealed_base_integrity(
                "",
                &[
                    (
                        "chunks/aa".into(),
                        "c".repeat(64), // rewritten content
                        10,
                    ),
                    ("chunks/bb".into(), "b".repeat(64), 20),
                ],
            )
            .await
            .unwrap();
        assert_eq!(broken.len(), 1);
        assert_eq!(broken[0].path, "chunks/aa");
        let status = engine.pin_log.pin_log_statuses().await;
        assert!(status[0].s_rewrite_attempts >= 2);
        assert!(status[0].pin_age_known);
        assert!(status[0].pin_age_secs.is_some());

        // Wire exit_pin_mode: clear freeze so former S members may be rewritten.
        let exited = engine.pin_log.exit_pin_mode_for_target("").await.unwrap();
        assert!(!exited.active, "status.active tracks pin freeze");
        assert!(!exited.degraded);
        engine
            .pin_log
            .attempt_sealed_base_member_rewrite(&"a".repeat(64), b"new")
            .await
            .unwrap();
    }

    #[tokio::test]
    async fn pin_mode_catchup_publish_and_bystander_probe() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        engine
            .pin_log
            .enter_pin_mode_for_target_with_sealed_base(
                "",
                0,
                vec![SealedBaseMember {
                    path: "chunks/s0".into(),
                    sha256: "d".repeat(64),
                    len: 1,
                    mtime_secs: 0,
                }],
            )
            .await
            .unwrap();
        engine.record_put("main", b"k", b"v1").await.unwrap();
        engine.record_put("main", b"k", b"v2").await.unwrap();

        let sha = "d".repeat(64);
        let mut plane = PinModeLocalCloud::new();
        let desc = engine
            .pin_log
            .publish_pin_mode_catchup("", &mut plane, &[(sha.clone(), b"base-bytes".to_vec())], 7)
            .await
            .unwrap();
        assert_eq!(desc.target_id, "personal");
        assert_eq!(desc.publish_counter, 7);
        assert!(desc.base_may_be_fuzzy);
        assert_eq!(plane.base_object_count("personal"), 1);
        assert!(plane.log_len("personal") >= 2);
        assert_eq!(plane.latest("personal").map(|d| d.publish_counter), Some(7));
        let status = engine.pin_log.pin_log_statuses().await;
        assert!(status[0].materialize_pending);

        // Fresh homes for bystander: base-only misses post-F0; base+log restores.
        let fresh_base = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let base_only = fresh_base
            .pin_log
            .restore_pin_mode_from_local_cloud(&fresh_base, &plane, "personal", false)
            .await
            .unwrap();
        assert!(base_only.log_entries >= 2);
        assert_eq!(base_only.app_keys_restored, 0);
        let main = fresh_base.store.open_namespace("main").await.unwrap();
        assert!(
            main.get(b"k").await.unwrap().is_none(),
            "base-only must not have post-F0 key"
        );

        let fresh_log = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let with_log = fresh_log
            .pin_log
            .restore_pin_mode_from_local_cloud(&fresh_log, &plane, "personal", true)
            .await
            .unwrap();
        assert!(with_log.app_keys_restored >= 2);
        let main = fresh_log.store.open_namespace("main").await.unwrap();
        assert_eq!(
            main.get(b"k").await.unwrap().as_deref(),
            Some(b"v2".as_slice())
        );

        engine
            .pin_log
            .materialize_pin_log_for_target(&engine, "")
            .await
            .unwrap();
        let status = engine.pin_log.pin_log_statuses().await;
        assert!(!status[0].materialize_pending);
    }

    #[tokio::test]
    async fn pin_mode_is_target_scoped_freeze_does_not_cross_org() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: true,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let org_prefix = "a".repeat(64);
        engine
            .configure_targets(
                SyncPartitioner::new_with_orgs(
                    &[],
                    &[crate::sharing::OrgSyncTarget {
                        org_hash: org_prefix.clone(),
                        storage_prefixes: Vec::new(),
                        unprefixed_schema_names: Vec::new(),
                        e2e_key_b64: base64::engine::general_purpose::STANDARD.encode([7u8; 32]),
                        slug: "org-a".to_string(),
                        active: true,
                        registered_at: "2026-08-01T00:00:00Z".to_string(),
                    }],
                ),
                vec![SyncTarget {
                    label: "org-a".to_string(),
                    prefix: org_prefix.clone(),
                    crypto: Arc::new(LocalCryptoProvider::from_key([7u8; 32])),
                }],
            )
            .await;

        engine
            .pin_log
            .enter_pin_mode_for_target_with_sealed_base(
                "",
                1,
                vec![SealedBaseMember {
                    path: "personal/s".into(),
                    sha256: "e".repeat(64),
                    len: 1,
                    mtime_secs: 0,
                }],
            )
            .await
            .unwrap();
        // Org not pinned: note_ is target-scoped and errors "not active".
        let err = engine
            .pin_log
            .note_sealed_base_rewrite_attempt(&org_prefix, &"e".repeat(64))
            .await
            .unwrap_err();
        assert!(err.contains("not active") || err.contains("not configured") || !err.is_empty());
        // Personal S member is hard-refused on the write path.
        let err = engine
            .pin_log
            .attempt_sealed_base_member_rewrite(&"e".repeat(64), b"x")
            .await
            .unwrap_err();
        assert!(err.contains("sealed base refuse"), "{err}");
    }

    /// CoW-style proof: sustained post-F0 writes, group-commit survival across
    /// engine "kill", catch-up publish, base-only fail / base+log pass on a
    /// fresh home, pin age known, S rewrite blocked.
    #[tokio::test]
    async fn pin_mode_cow_end_to_end_proof() {
        let shared_store: Arc<dyn NamespacedStore> = Arc::new(InMemoryNamespacedStore::new());
        let mk = |store: Arc<dyn NamespacedStore>| {
            let http = Arc::new(reqwest::Client::new());
            let auth = AuthClient::new(
                Arc::clone(&http),
                "http://127.0.0.1:1".to_string(),
                SyncAuth::ApiKey("test-key".to_string()),
            );
            let s3 = S3Client::new(http);
            let crypto: Arc<dyn CryptoProvider> =
                Arc::new(LocalCryptoProvider::from_key([0x55u8; 32]));
            let signer = Arc::new(Ed25519KeyPair::generate().unwrap());
            SyncEngine::new(
                "cow-device".to_string(),
                crypto,
                s3,
                auth,
                store,
                SyncConfig {
                    legacy_personal_cloud_sync: true,
                    max_upload_bytes_per_cycle: 1024 * 1024,
                    ..SyncConfig::default()
                },
                signer,
            )
        };

        let sealed_sha = "f".repeat(64);
        let writer = mk(Arc::clone(&shared_store));
        let status = writer
            .pin_log
            .enter_pin_mode_for_target_with_sealed_base(
                "",
                0,
                vec![SealedBaseMember {
                    path: "chunks/f0".into(),
                    sha256: sealed_sha.clone(),
                    len: 4,
                    mtime_secs: 0,
                }],
            )
            .await
            .unwrap();
        assert!(status.pin_age_known);
        assert_eq!(status.sealed_base_count, 1);

        // Sustained post-F0 writes (group-commit per record_put path).
        for i in 0..16u8 {
            writer.record_put("main", b"cow-key", &[i]).await.unwrap();
        }
        assert_eq!(
            writer
                .pin_log
                .pin_log_records_for_target("")
                .await
                .unwrap()
                .len(),
            16
        );
        // S rewrite blocked mid-pin.
        assert!(writer
            .pin_log
            .attempt_sealed_base_member_rewrite(&sealed_sha, b"nope")
            .await
            .is_err());

        // Kill after group-commit: drop writer, reopen same durable store.
        drop(writer);
        let survivor = mk(Arc::clone(&shared_store));
        // Pin log is in shared store; replay without re-enter.
        let n = survivor
            .pin_log
            .replay_pin_log_for_target(&survivor, "")
            .await
            .unwrap();
        assert_eq!(n, 16);
        let main = survivor.store.open_namespace("main").await.unwrap();
        assert_eq!(
            main.get(b"cow-key").await.unwrap().as_deref(),
            Some(&[15u8][..])
        );

        // Catch-up publish + fresh-home restore.
        let publisher = mk(Arc::clone(&shared_store));
        publisher
            .pin_log
            .enter_pin_mode_for_target_with_sealed_base(
                "",
                0,
                vec![SealedBaseMember {
                    path: "chunks/f0".into(),
                    sha256: sealed_sha.clone(),
                    len: 4,
                    mtime_secs: 0,
                }],
            )
            .await
            .unwrap();
        // Re-record is fine (idempotent replay later); ensure log non-empty for plane.
        let mut plane = PinModeLocalCloud::new();
        // Use survivor's durable pin log already on shared store — publish from
        // a new pin session that can still read the same pin_log namespace.
        let pub2 = mk(Arc::clone(&shared_store));
        pub2.pin_log
            .enter_pin_mode_for_target_with_sealed_base(
                "",
                0,
                vec![SealedBaseMember {
                    path: "chunks/f0".into(),
                    sha256: sealed_sha.clone(),
                    len: 4,
                    mtime_secs: 0,
                }],
            )
            .await
            .unwrap();
        let desc = pub2
            .pin_log
            .publish_pin_mode_catchup("", &mut plane, &[(sealed_sha, b"f0xx".to_vec())], 1)
            .await
            .unwrap();
        assert_eq!(desc.sealed_base_shas.len(), 1);
        assert!(plane.log_len("personal") >= 16);

        let fresh = mk(Arc::new(InMemoryNamespacedStore::new()));
        let base_only = fresh
            .pin_log
            .restore_pin_mode_from_local_cloud(&fresh, &plane, "personal", false)
            .await
            .unwrap();
        assert_eq!(base_only.app_keys_restored, 0);
        let main = fresh.store.open_namespace("main").await.unwrap();
        assert!(main.get(b"cow-key").await.unwrap().is_none());

        let fresh2 = mk(Arc::new(InMemoryNamespacedStore::new()));
        let full = fresh2
            .pin_log
            .restore_pin_mode_from_local_cloud(&fresh2, &plane, "personal", true)
            .await
            .unwrap();
        assert!(full.app_keys_restored >= 16);
        let main = fresh2.store.open_namespace("main").await.unwrap();
        assert_eq!(
            main.get(b"cow-key").await.unwrap().as_deref(),
            Some(&[15u8][..])
        );

        let age = pub2.pin_log.pin_log_statuses().await;
        assert!(age[0].pin_age_known);
        assert!(age[0].materialize_pending);
        pub2.pin_log
            .materialize_pin_log_for_target(&pub2, "")
            .await
            .unwrap();
        assert!(!pub2.pin_log.pin_log_statuses().await[0].materialize_pending);
    }

    /// MutationLog continuous plane must durable-capture org-scoped keys under
    /// the org target_id — never silently Ok with empty records when an org
    /// destination is configured (teardown-sync-mutation-log-scoped-partitions).
    #[tokio::test]
    async fn continuous_mutation_log_captures_org_partition_not_silent_drop() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let org_prefix = "b".repeat(64);
        let locator = crate::access::parse_db_locator("lastdb://org/edgevector/state-machine")
            .expect("org locator");
        let db_prefix = crate::access::storage_prefix_for(&locator).expect("org db prefix");
        assert_ne!(
            db_prefix, org_prefix,
            "test must exercise distinct identities"
        );
        let org_crypto: Arc<dyn CryptoProvider> =
            Arc::new(LocalCryptoProvider::from_key([0x42u8; 32]));
        engine
            .configure_targets(
                SyncPartitioner::new_with_orgs(
                    &[],
                    &[crate::sharing::OrgSyncTarget {
                        org_hash: org_prefix.clone(),
                        storage_prefixes: vec![db_prefix.clone()],
                        unprefixed_schema_names: Vec::new(),
                        e2e_key_b64: base64::engine::general_purpose::STANDARD.encode([0x42u8; 32]),
                        slug: "org-b".to_string(),
                        active: true,
                        registered_at: "2026-08-13T00:00:00Z".to_string(),
                    }],
                ),
                vec![SyncTarget {
                    label: "org-b".to_string(),
                    prefix: org_prefix.clone(),
                    crypto: Arc::clone(&org_crypto),
                }],
            )
            .await;

        assert!(engine.should_stage_cloud_mutations().await);

        // A key written through the org DB locator carries db_prefix locally,
        // but must land in the org_hash cloud stream.
        let org_key = format!("{db_prefix}:atom:org-row");
        engine
            .record_put("main", org_key.as_bytes(), b"org-v")
            .await
            .expect("org-scoped MutationLog capture must not fail closed unless status surfaces");

        let org_records = engine
            .pin_log
            .pin_log_records_for_target(&org_prefix)
            .await
            .unwrap();
        assert_eq!(
            org_records.len(),
            1,
            "configured org target must receive continuous mutation-log capture"
        );
        let expected_org_id = target_id_for_prefix(&org_prefix);
        assert_eq!(org_records[0].target_id, expected_org_id);
        assert_eq!(org_records[0].target_prefix, org_prefix);
        match &org_records[0].entry.op {
            LogOp::Put { key, .. } => {
                let raw = LogOp::decode_bytes(key).unwrap();
                assert_eq!(raw, org_key.as_bytes());
            }
            other => panic!("expected Put for org key, got {other:?}"),
        }

        // Personal stream must not absorb the org partition.
        let personal = engine.pin_log.pin_log_records_for_target("").await.unwrap();
        assert!(
            personal.is_empty(),
            "org-scoped key must not dual-write the personal continuous stream"
        );

        // Seal path must use target crypto (not personal engine.crypto).
        let sealed = seal_mutation_log_segment(&org_records[0], &org_crypto)
            .await
            .expect("org segment seals under org crypto");
        let recovered = unseal_mutation_log_segment(&sealed.payload, &org_crypto)
            .await
            .expect("org crypto must open its own segment");
        assert_eq!(recovered.len(), 1);
        assert_eq!(recovered[0].target_id, expected_org_id);
        let foreign = unseal_mutation_log_segment(&sealed.payload, &engine.crypto).await;
        assert!(
            foreign.is_err(),
            "personal crypto must not open org-sealed mutation-log segment"
        );
    }

    /// Mutation-log-first Phase A: Cloud Sync on → durable log capture without
    /// pin freeze, without snapshot cycle, without legacy personal outbox.
    #[tokio::test]
    async fn continuous_mutation_log_capture_without_pin_mode() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        // Sync is on by default (cloud_sync_disabled_at = None).
        assert!(engine.should_stage_cloud_mutations().await);
        assert!(engine.cloud_plane_allows_upload().await);

        // No enter_pin_mode — continuous capture must still durable-log commits.
        let n = 8u8;
        for i in 0..n {
            engine
                .record_put("main", format!("k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let records = engine.pin_log.pin_log_records_for_target("").await.unwrap();
        assert_eq!(
            records.len(),
            n as usize,
            "expected {n} durable mutation-log entries without pin mode; got {}",
            records.len()
        );
        assert!(
            records.iter().all(|r| r.target_id == "personal"),
            "single personal writer stream scaffold"
        );
        // Status must not report pin-freeze active or degraded for continuous mode.
        let statuses = engine.pin_log.pin_log_statuses().await;
        assert_eq!(statuses.len(), 1);
        assert!(
            !statuses[0].active,
            "continuous capture must not surface as pin freeze"
        );
        assert!(!statuses[0].degraded);
        assert_eq!(statuses[0].entry_count, n as u64);
        assert_eq!(statuses[0].sealed_base_count, 0);

        // Legacy outbox stays empty on LastStore-style (non-legacy) homes.
        assert_eq!(engine.outbox_count().await.unwrap(), 0);
        assert_eq!(engine.pending_count().await, 0);

        // Forced "offline" for upload must still accept local record_op (never-block).
        // Staging remains on while sync is on; offline is network, not local gate.
        engine
            .record_put("main", b"offline-ok", b"v")
            .await
            .expect("local mutation log append must never fail for network reasons");
        assert_eq!(
            engine
                .pin_log
                .pin_log_records_for_target("")
                .await
                .unwrap()
                .len(),
            n as usize + 1
        );

        // Intentional sync-off past grace stops staging (and thus log growth).
        engine.set_cloud_sync_disabled(true).await;
        let disabled_at = engine.cloud_sync_disabled_at().await.unwrap();
        *engine.cloud_sync_disabled_at.lock().await =
            Some(disabled_at.saturating_sub(engine.config.sync_off_grace_secs.saturating_add(1)));
        assert!(!engine.should_stage_cloud_mutations().await);
        let before = engine
            .pin_log
            .pin_log_records_for_target("")
            .await
            .unwrap()
            .len();
        engine.record_put("main", b"after-off", b"v").await.unwrap();
        assert_eq!(
            engine
                .pin_log
                .pin_log_records_for_target("")
                .await
                .unwrap()
                .len(),
            before,
            "past-grace sync-off must stop mutation-log staging"
        );
    }

    /// Continuous log plane: seal/upload under `log/{writer_id}/`, advance F,
    /// backlog converges under synthetic load; sealed-home backup demoted.
    /// A cycle that cannot reach cloud must publish NOTHING: no frontier
    /// advance, no segment count, no bytes.
    ///
    /// This is the regression guard for the defect this seam exists to prevent.
    /// The cycle used to "publish" by inserting into an in-process `HashMap`
    /// and then advance F, so on the primary it reported 236 segments uploaded
    /// against **0** `log/` objects in R2, and log lag grew ~1 s/s forever
    /// because the frontier kept moving over records that never left the box.
    /// The old tests could not catch it: they asserted convergence using an
    /// engine whose auth endpoint is `127.0.0.1:1`, which can only "succeed"
    /// if publishing never touches the network.
    ///
    /// A durability frontier may only advance on cloud-confirmed writes.
    /// A publish that never reached cloud must not delete the local records.
    ///
    /// Truncation is gated on cloud confirmation for the same reason the
    /// frontier is: the local pin log is the only copy until something else
    /// holds it. Deleting on a failed publish would destroy data that no peer
    /// and no snapshot has. The paired risk is the opposite one — never
    /// deleting at all — which grew the primary's pin log 138 MiB -> 10.45 GiB
    /// in a day.
    #[tokio::test]
    async fn failed_publish_does_not_truncate_local_pin_log() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..5u8 {
            engine
                .record_put("main", format!("keep-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let before = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap()
            .len();
        assert!(before > 0, "capture must have produced durable records");

        // Cloud is unreachable in the test engine (auth points at 127.0.0.1:1).
        let mut plane = MutationLogLocalCloud::new();
        let res = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::Cloud,
            )
            .await;
        assert!(res.is_err(), "unreachable cloud must error, got {res:?}");

        let after = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap()
            .len();
        assert_eq!(
            after, before,
            "a failed publish must not delete durable pin-log records"
        );
    }

    #[tokio::test]
    async fn cloud_publish_failure_does_not_advance_frontier() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..4u8 {
            engine
                .record_put("main", format!("nocloud-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let before = engine.status().await;
        let f_before = before.mutation_log.as_ref().map_or(0, |m| m.frontier_f);

        // test_engine's auth points at 127.0.0.1:1, so Cloud publish must fail.
        // Use the real engine plane so this also verifies its status projection.
        let mut plane = engine.mutation_log_plane.lock().await;
        let res = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::Cloud,
            )
            .await;
        assert!(
            res.is_err(),
            "unreachable cloud must surface an error, got {res:?}"
        );

        let after = tokio::time::timeout(std::time::Duration::from_millis(250), engine.status())
            .await
            .expect("failed cloud publication must leave status accessible under the plane lock");
        let ml = after
            .mutation_log
            .as_ref()
            .expect("MutationLog plane must surface status");
        assert_eq!(
            ml.frontier_f, f_before,
            "frontier must not advance when nothing reached cloud"
        );
        assert_eq!(
            ml.segments_uploaded, 0,
            "segments_uploaded must count cloud-confirmed writes, not local inserts"
        );
        assert_eq!(
            plane.segment_count(),
            0,
            "a failed cloud publish must not leave segments in the local plane"
        );
        assert_eq!(
            ml.published_through, f_before,
            "operator published_through must track cloud-confirmed F only"
        );
        assert_eq!(
            ml.recovery_point_age_secs, None,
            "RPO age must stay unset until a cloud-confirmed segment lands"
        );
    }

    #[tokio::test]
    async fn multi_schema_cloud_publish_failure_keeps_record_and_frontier() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let record = transaction_group_record();
        engine
            .pin_log
            .persist_pin_log_records(std::slice::from_ref(&record))
            .await
            .expect("persist multi-schema transaction");
        let before = engine.status().await;
        let frontier_before = before.mutation_log.as_ref().map_or(0, |log| log.frontier_f);

        let mut plane = MutationLogLocalCloud::new();
        let error = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::Cloud,
            )
            .await
            .expect_err("the test cloud endpoint is unreachable");
        assert!(
            !error.contains("more than one schema identity")
                && !error.contains("cannot mix or omit schema names"),
            "the transaction group must reach the cloud path instead of the old sealer rejection: {error}"
        );

        let after = engine.status().await;
        let mutation_log = after.mutation_log.as_ref().expect("mutation-log status");
        assert_eq!(mutation_log.frontier_f, frontier_before);
        assert_eq!(mutation_log.segments_uploaded, 0);
        assert_eq!(plane.segment_count(), 0);
        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let pending = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert!(pending
            .iter()
            .any(|candidate| candidate.frontier_after == record.frontier_after));
    }

    /// RPO fields are cloud-confirmed only: local-plane geometry advances F for
    /// lag accounting, but does not invent a recovery-point timestamp.
    #[tokio::test]
    async fn local_plane_publish_advances_f_without_inventing_rpo_age() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..3u8 {
            engine
                .record_put("main", format!("rpo-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }
        let mut plane = MutationLogLocalCloud::new();
        let report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert!(report.segments_uploaded >= 1);
        let st = engine.status().await;
        let ml = st.mutation_log.as_ref().expect("mutation_log status");
        assert_eq!(ml.frontier_f, report.published_frontier_after);
        assert_eq!(
            ml.published_through, ml.frontier_f,
            "published_through mirrors scalar F for operators"
        );
        assert_eq!(
            ml.recovery_point_age_secs, None,
            "LocalPlaneForTests is geometry only — RPO age must not advance"
        );
        let pin = engine.pin_log.pin_log_statuses().await;
        assert_eq!(pin[0].published_through, pin[0].published_frontier);
        assert_eq!(pin[0].recovery_point_age_secs, None);
    }

    #[test]
    fn pin_log_runtime_rpo_tracks_cloud_confirmed_timestamp() {
        let mut runtime = PinLogRuntime::new(
            "personal".into(),
            "personal".into(),
            String::new(),
            0,
            0,
            true,
        );
        assert_eq!(runtime.status().recovery_point_age_secs, None);
        assert_eq!(runtime.status().published_through, 0);

        let confirmed_at = now_millis().saturating_sub(7_000);
        runtime.advance_published_f("writer-a", 42, confirmed_at);
        let st = runtime.status();
        assert_eq!(st.published_through, 42);
        assert_eq!(st.published_frontier, 42);
        let age = st
            .recovery_point_age_secs
            .expect("cloud-confirmed advance must set RPO age");
        assert!(
            (6..=10).contains(&age),
            "expected ~7s recovery point age, got {age}"
        );

        // Lower through must not regress F or refresh the RPO clock.
        runtime.advance_published_f("writer-a", 10, now_millis());
        let st = runtime.status();
        assert_eq!(st.published_through, 42);
        let age2 = st.recovery_point_age_secs.expect("age remains set");
        assert!(
            age2 >= age,
            "stale lower-through publish must not reset RPO clock ({age2} < {age})"
        );
    }

    #[tokio::test]
    async fn continuous_mutation_log_segment_upload_advances_f_and_converges() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        assert!(engine.pin_log.continuous_sealed_home_backup_demoted());

        let n = 12u8;
        for i in 0..n {
            engine
                .record_put("main", format!("seg-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let mut plane = MutationLogLocalCloud::new();
        // Twelve records fit in one request-sized segment.
        let mid = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                5,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(mid.segments_uploaded, 1);
        assert!(mid.published_frontier_after > mid.published_frontier_before);
        assert_eq!(mid.records_considered, n as usize);
        assert_eq!(mid.upload_backlog_after, 0);
        assert!(
            mid.object_keys
                .iter()
                .all(|k| k.starts_with("log/test-device/")),
            "segments must live under log/{{writer_id}}/: {:?}",
            mid.object_keys
        );

        let final_report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(final_report.segments_uploaded, 0);
        assert_eq!(final_report.upload_backlog_after, 0);
        assert_eq!(plane.segment_count(), 1);
        assert_eq!(
            plane.keys_under_writer("test-device").len(),
            1,
            "all segments under log/test-device/"
        );
        assert!(
            plane.published_f("test-device") > 0,
            "published F must advance for writer"
        );

        let status = engine.pin_log.pin_log_statuses().await;
        assert_eq!(status.len(), 1);
        assert_eq!(status[0].upload_backlog, 0);
        assert_eq!(status[0].segments_uploaded, 1);
        assert_eq!(
            status[0].published_frontier,
            status[0].last_durable_frontier
        );

        // Idle cycle is a no-op (backlog already zero).
        let idle = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(idle.segments_uploaded, 0);
        assert_eq!(idle.upload_backlog_after, 0);
        assert_eq!(plane.segment_count(), 1);
    }

    /// A locally-sealed frontier from another writer must raise the
    /// max-across-writers scalar `frontier_f` WITHOUT raising
    /// `published_through`, which names a cloud confirmation.
    ///
    /// Before the fix both fields were the same expression
    /// (`published_through: frontier_f`), so they were equal in every sample the
    /// node could emit — measured 12/12 equal on the live primary on 2026-08-18,
    /// including at 108s of unpublished backlog. That made publish lag
    /// unobservable from the two fields that name it, and it made the equality
    /// look like evidence of a caught-up plane when it was an identity.
    #[tokio::test]
    async fn published_through_is_not_raised_by_a_locally_sealed_peer_frontier() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });

        let published: u64 = 1_787_000_000_000_000_000;
        let durable: u64 = published + 108_000_000_000; // 108s of unpublished work
        let peer_sealed: u64 = published + 500_000_000_000; // sealed locally, not in cloud

        let status = PinLogTargetStatus {
            target_id: "personal".to_string(),
            target_label: "personal".to_string(),
            target_prefix: String::new(),
            active: false,
            base_frontier: 0,
            last_durable_frontier: durable,
            entry_count: 0,
            byte_count: 0,
            last_durable_at_ms: None,
            sealed_base_count: 0,
            pin_age_secs: None,
            pin_age_known: false,
            s_rewrite_attempts: 0,
            materialize_pending: false,
            degraded: false,
            published_frontier: published,
            published_through: published,
            recovery_point_age_secs: Some(108),
            published_f_by_writer: BTreeMap::from([("test-device".to_string(), published)]),
            upload_backlog: durable - published,
            segments_uploaded: 3,
            records_quarantined: 0,
            last_quarantine_reason: None,
        };

        let mut plane_vector_f = BTreeMap::new();
        plane_vector_f.insert("peer-device".to_string(), peer_sealed);

        let ml = engine
            .mutation_log_plane_status_from_pin_logs(&[status], &plane_vector_f)
            .expect("MutationLog capture mode must produce a plane status");

        // The scalar compat frontier still absorbs the peer's local seal.
        assert_eq!(
            ml.frontier_f, peer_sealed,
            "frontier_f is documented as the max across writers"
        );

        // The cloud-confirmed watermark must NOT move for a local seal.
        assert_eq!(
            ml.published_through, published,
            "published_through must stay the cloud-confirmed frontier"
        );
        assert!(
            ml.published_through < ml.frontier_f,
            "the publish gap must be visible: published_through {} vs frontier_f {}",
            ml.published_through,
            ml.frontier_f
        );

        // `log_lag` must be reconstructible from the emitted operands.
        assert_eq!(
            ml.last_durable_frontier - ml.published_through,
            ml.log_lag,
            "log_lag must equal last_durable_frontier - published_through"
        );
    }

    /// Build a plane status with a chosen recovery point age and a large
    /// nanosecond backlog, to pin `lag_degraded` at the real trip site.
    fn plane_status_with_recovery_age(recovery_point_age_secs: Option<u64>) -> PinLogTargetStatus {
        let published: u64 = 1_787_000_000_000_000_000;
        // 258s of unpublished frontier delta — the live sample from the report
        // that opened this card. Under the old ns-vs-seconds comparison this
        // operand alone forced `lag_degraded` true regardless of real health.
        let durable: u64 = published + 258_000_000_000;
        PinLogTargetStatus {
            target_id: "personal".to_string(),
            target_label: "personal".to_string(),
            target_prefix: String::new(),
            active: false,
            base_frontier: 0,
            last_durable_frontier: durable,
            entry_count: 0,
            byte_count: 0,
            last_durable_at_ms: None,
            sealed_base_count: 0,
            pin_age_secs: None,
            pin_age_known: false,
            s_rewrite_attempts: 0,
            materialize_pending: false,
            degraded: false,
            published_frontier: published,
            published_through: published,
            recovery_point_age_secs,
            published_f_by_writer: BTreeMap::from([("test-device".to_string(), published)]),
            upload_backlog: durable - published,
            segments_uploaded: 3,
            records_quarantined: 0,
            last_quarantine_reason: None,
        }
    }

    /// `lag_degraded` keys on the recovery point **age in seconds**, not on the
    /// nanosecond `log_lag` delta.
    ///
    /// Every case below carries the same 258s nanosecond backlog, so the flag
    /// can only vary with the seconds operand. Under the shipped defect all
    /// four cases read `true`. The ages are mid-range on purpose: a threshold
    /// of `1`, as the older tests used, passes under either unit and is why the
    /// mismatch shipped green.
    #[tokio::test]
    async fn mutation_log_plane_degrades_on_recovery_point_age() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            mutation_log_lag_degraded_threshold_secs: 32,
            ..SyncConfig::default()
        });
        let empty_vector_f = BTreeMap::new();

        let healthy = engine
            .mutation_log_plane_status_from_pin_logs(
                &[plane_status_with_recovery_age(Some(5))],
                &empty_vector_f,
            )
            .expect("MutationLog capture mode must produce a plane status");
        assert!(
            healthy.log_lag > 0,
            "the nanosecond backlog must still be reported: {}",
            healthy.log_lag
        );
        assert!(
            !healthy.lag_degraded,
            "a 5s recovery point is healthy even with {}ns of backlog",
            healthy.log_lag
        );

        let behind = engine
            .mutation_log_plane_status_from_pin_logs(
                &[plane_status_with_recovery_age(Some(90))],
                &empty_vector_f,
            )
            .expect("plane status");
        assert!(
            behind.lag_degraded,
            "a 90s recovery point is genuinely behind and must degrade"
        );

        // Same backlog, no confirmed recovery point: fresh, not degraded.
        let fresh = engine
            .mutation_log_plane_status_from_pin_logs(
                &[plane_status_with_recovery_age(None)],
                &empty_vector_f,
            )
            .expect("plane status");
        assert!(
            !fresh.lag_degraded,
            "no cloud-confirmed recovery point yet is fresh, not degraded"
        );

        // The flag must be able to read false while backlog is nonzero. That
        // is the bit the old comparison could not express.
        assert_ne!(
            healthy.lag_degraded, behind.lag_degraded,
            "lag_degraded must carry information across recovery point ages"
        );
    }

    /// The idle-node shape from every `cloud-sync-health-fix` fire between
    /// 2026-09-10 and 2026-09-13: `log_lag=0`, `rpo_secs=0`, and a publish
    /// event age in the hundreds of seconds because nothing was owed. The
    /// engine used to read that as `mutation_log_lag`; a caught-up publisher
    /// has no lag to be degraded on. The same age with a backlog still trips,
    /// so the gate only silences the idle case.
    #[tokio::test]
    async fn mutation_log_plane_caught_up_node_is_not_lag_degraded() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            mutation_log_lag_degraded_threshold_secs: 32,
            ..SyncConfig::default()
        });
        let empty_vector_f = BTreeMap::new();

        let mut caught_up = plane_status_with_recovery_age(Some(867));
        caught_up.last_durable_frontier = caught_up.published_frontier;
        caught_up.upload_backlog = 0;
        let idle = engine
            .mutation_log_plane_status_from_pin_logs(&[caught_up], &empty_vector_f)
            .expect("plane status");
        assert_eq!(idle.log_lag, 0, "nothing sealed is unpublished");
        assert_eq!(
            idle.recovery_point_age_secs,
            Some(867),
            "the publish event age is still reported as-is"
        );
        assert!(
            !idle.lag_degraded,
            "an 867s-old publish event with zero backlog is idle, not degraded"
        );

        let stalled = engine
            .mutation_log_plane_status_from_pin_logs(
                &[plane_status_with_recovery_age(Some(867))],
                &empty_vector_f,
            )
            .expect("plane status");
        assert!(
            stalled.lag_degraded,
            "the same age with {}ns of backlog is a stalled publisher",
            stalled.log_lag
        );
    }

    #[tokio::test]
    async fn mutation_log_backlog_wakes_successive_bounded_passes_then_goes_idle() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            // Wake pacing reads the ns frontier-delta knob, not the seconds
            // degraded threshold. Any remaining backlog re-arms the publisher.
            mutation_log_backlog_wake_threshold_ns: 1,
            max_upload_bytes_per_cycle: 8 * 1024 * 1024,
            ..SyncConfig::default()
        });
        let wake = engine.wake_handle();
        let record_count = MUTATION_LOG_SEGMENT_MAX_RECORDS * 2 + 17;
        for i in 0..record_count {
            engine
                .record_put("main", format!("paced-k{i}").as_bytes(), &[1])
                .await
                .unwrap();
        }

        // Burst writes coalesce into one permit. Consume it so every later
        // readiness assertion comes from backlog pacing, not the write path.
        tokio::time::timeout(Duration::from_millis(50), wake.notified())
            .await
            .expect("durable appends must queue the initial publisher wake");

        let mut plane = MutationLogLocalCloud::new();
        for expected_remaining_passes in [2usize, 1] {
            let report = engine
                .pin_log
                .run_mutation_log_segment_upload_cycle(
                    &engine,
                    "",
                    &mut plane,
                    1,
                    MutationLogPublish::LocalPlaneForTests,
                )
                .await
                .unwrap();
            assert_eq!(report.segments_uploaded, 1);
            assert!(
                report.upload_backlog_after > 0,
                "a bounded pass must leave backlog for pass {expected_remaining_passes}"
            );
            assert!(
                engine.wake_mutation_log_publisher_for_backlog(&report),
                "progress with lag above the SLO must queue the next pass"
            );
            tokio::time::timeout(Duration::from_millis(50), wake.notified())
                .await
                .expect("backlog follow-up wake must be immediately consumable");
        }

        let final_report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                1,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(final_report.segments_uploaded, 1);
        assert_eq!(final_report.upload_backlog_after, 0);
        assert!(
            !engine.wake_mutation_log_publisher_for_backlog(&final_report),
            "a caught-up writer must not schedule another pass"
        );
        assert!(
            tokio::time::timeout(Duration::from_millis(10), wake.notified())
                .await
                .is_err(),
            "the caught-up publisher must stay idle instead of spinning"
        );
    }

    /// Status surfaces log lag + F + writer_id, and catch-up converges lag to
    /// zero. Sealed-chunk is not the continuous health story.
    ///
    /// A fresh, unpublished backlog is explicitly **not** degraded here. This
    /// test previously asserted the opposite, with the threshold set to `1` so
    /// that any backlog tripped. That expectation encoded the unit mismatch it
    /// was supposed to guard: `log_lag` is a nanosecond frontier delta, so a
    /// seconds-scale threshold read against it fired at every nonzero lag.
    /// Degradation is now a statement about the **age** of the cloud-confirmed
    /// recovery point; see `mutation_log_plane_degrades_on_recovery_point_age`
    /// and the mid-range cases in `sync::engine::wiring`.
    #[tokio::test]
    async fn mutation_log_status_lag_and_frontier_track_publish_and_recover() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            mutation_log_lag_degraded_threshold_secs: 32,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        assert!(engine.pin_log.continuous_sealed_home_backup_demoted());

        // No durable mutations yet: plane active, lag 0, not degraded.
        let empty = engine.status().await;
        let ml = empty
            .mutation_log
            .as_ref()
            .expect("MutationLog plane must surface status");
        assert!(ml.active);
        assert_eq!(ml.writer_id, "test-device");
        assert_eq!(ml.log_lag, 0);
        assert_eq!(ml.frontier_f, 0);
        assert_eq!(ml.published_through, 0);
        assert_eq!(ml.recovery_point_age_secs, None);
        assert!(!ml.capture_registered);
        // Single-writer scaffold: empty map is ok before any durable progress;
        // once durable/published, status is always a one-entry (or more) map.
        assert!(!ml.lag_degraded);
        assert!(!empty.sync_degraded);
        assert!(!empty
            .degraded_reasons
            .iter()
            .any(|r| r == "mutation_log_lag"));

        let n = 6u8;
        for i in 0..n {
            engine
                .record_put("main", format!("lag-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        // Before upload: lag = durable - published F, and it is observable.
        let lagging = engine.status().await;
        let ml = lagging.mutation_log.as_ref().expect("mutation_log status");
        assert!(ml.capture_registered);
        assert!(
            ml.log_lag >= 1,
            "expected synthetic upload lag, got {}",
            ml.log_lag
        );
        assert_eq!(ml.last_durable_frontier, ml.frontier_f + ml.log_lag);
        // Writes seconds old with no confirmed recovery point are a healthy
        // node mid-publish-cycle. This is the defect this card fixed: the flag
        // used to read `true` here, and at 258s of real stall, identically.
        assert_eq!(ml.recovery_point_age_secs, None);
        assert!(
            !ml.lag_degraded,
            "a fresh unpublished backlog is not a degraded plane"
        );
        assert!(
            !lagging
                .degraded_reasons
                .iter()
                .any(|r| r == "mutation_log_lag"),
            "mutation_log_lag must not fire on ordinary mid-cycle lag: {:?}",
            lagging.degraded_reasons
        );
        // Continuous health is log-based, not sealed-chunk remaining %.
        assert!(
            !lagging
                .degraded_reasons
                .iter()
                .any(|r| r == "backup_failing"),
            "sealed-chunk backup must not be primary continuous degraded reason"
        );

        // The small backlog batches into one object and recovers in one cycle.
        let mut plane = MutationLogLocalCloud::new();
        let mid = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                2,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(mid.segments_uploaded, 1);
        assert_eq!(mid.upload_backlog_after, 0);
        let mid_status = engine.status().await;
        let ml = mid_status.mutation_log.as_ref().unwrap();
        assert_eq!(ml.frontier_f, mid.published_frontier_after);
        assert_eq!(ml.published_through, ml.frontier_f);
        assert_eq!(
            ml.recovery_point_age_secs, None,
            "the local plane test double must not claim an off-box recovery point"
        );
        assert_eq!(ml.log_lag, mid.upload_backlog_after);
        assert!(!ml.lag_degraded);
        assert!(!mid_status.sync_degraded);

        // Drain remaining → lag recovers, degraded clears.
        let final_report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(final_report.upload_backlog_after, 0);
        let recovered = engine.status().await;
        let ml = recovered.mutation_log.as_ref().unwrap();
        assert_eq!(ml.log_lag, 0);
        assert_eq!(ml.frontier_f, ml.last_durable_frontier);
        assert!(!ml.lag_degraded);
        // Single-writer scaffold: F is still a one-entry map, not scalar-only.
        assert_eq!(
            ml.frontier_f_by_writer.len(),
            1,
            "single-writer status F must be one-entry map: {:?}",
            ml.frontier_f_by_writer
        );
        assert_eq!(
            ml.frontier_f_by_writer.get(&ml.writer_id).copied(),
            Some(ml.frontier_f)
        );
        assert!(
            !recovered
                .degraded_reasons
                .iter()
                .any(|r| r == "mutation_log_lag"),
            "catch-up must clear mutation_log_lag: {:?}",
            recovered.degraded_reasons
        );
        // No other degradation injects → overall healthy again.
        assert!(
            !recovered.sync_degraded,
            "expected healthy after catch-up: {:?}",
            recovered.degraded_reasons
        );
    }

    #[test]
    fn cloud_confirmation_sets_published_through_and_recovery_point_age() {
        let mut runtime = PinLogRuntime::new(
            "personal".to_string(),
            "Personal".to_string(),
            String::new(),
            0,
            42,
            true,
        );
        let confirmed_at = now_millis().saturating_sub(5_000);

        runtime.advance_published_f("writer-a", 42, confirmed_at);

        let status = runtime.status();
        assert_eq!(status.published_frontier, 42);
        assert_eq!(status.published_through, 42);
        assert!(
            status.recovery_point_age_secs.is_some_and(|age| age >= 5),
            "RPO age must come from the cloud-confirmed record timestamp: {status:?}"
        );
    }

    /// Record carrying a recognizable secret in its value, for the plaintext
    /// tests below.
    fn secret_bearing_record(secret: &[u8]) -> PinLogRecord {
        PinLogRecord {
            model_version: 1,
            target_id: "personal".into(),
            target_label: "personal".into(),
            target_prefix: String::new(),
            writer_id: "device-xyz".into(),
            frontier_after: 42,
            timestamp_ms: 1,
            entry: LogEntry {
                seq: 42,
                device_id: "device-xyz".into(),
                timestamp_ms: 1,
                op: crate::sync::log::LogOp::Put {
                    namespace: "main".into(),
                    key: base64::engine::general_purpose::STANDARD.encode(b"atom:secret-key"),
                    value: base64::engine::general_purpose::STANDARD.encode(secret),
                },
            },
        }
    }

    fn transaction_group_record() -> PinLogRecord {
        let schemas = ["Brain", "BoardCard", "Brain", "Milestone", "BoardCard"];
        let mut record = secret_bearing_record(b"transaction-group");
        record.frontier_after = 73;
        record.entry.seq = 73;
        record.entry.op = LogOp::MutationIntent {
            mutations: schemas
                .iter()
                .enumerate()
                .map(|(index, schema_name)| crate::sync::log::MutationEnvelope {
                    schema_name: (*schema_name).to_string(),
                    mutation_type: "update".to_string(),
                    key_value: crate::schema::types::key_value::KeyValue::new(
                        Some(format!("key-{index}")),
                        None,
                    ),
                    fields_and_values: HashMap::from([
                        (
                            "zeta".to_string(),
                            serde_json::json!({"b": index, "a": true}),
                        ),
                        ("alpha".to_string(), serde_json::json!(index)),
                    ]),
                    pub_key: "pk".to_string(),
                    written_at: 1_700_000_000_000_000_100 + index as u64,
                    writer_id: "device-xyz".to_string(),
                    logical_counter: index as u64 + 1,
                    author_clock_signature: String::new(),
                    author_clock_signature_version: 0,
                    storage_prefix: None,
                    provenance: None,
                    imported_version: None,
                    mutation_uuid: format!("mutation-{index}"),
                    source_file_name: None,
                    metadata: Some(HashMap::from([
                        ("zeta".to_string(), format!("z-{index}")),
                        ("alpha".to_string(), format!("a-{index}")),
                    ])),
                    aggregate_set: None,
                    field_atom_uuids: HashMap::from([
                        ("zeta".to_string(), format!("atom-z-{index}")),
                        ("alpha".to_string(), format!("atom-a-{index}")),
                    ]),
                })
                .collect(),
        };
        record
    }

    fn typed_mutation_intent_record(frontier_after: u64, written_at: u64) -> PinLogRecord {
        let mut record = secret_bearing_record(format!("typed-{frontier_after}").as_bytes());
        record.frontier_after = frontier_after;
        record.timestamp_ms = frontier_after;
        record.entry.seq = frontier_after;
        record.entry.timestamp_ms = frontier_after;
        record.entry.op = LogOp::MutationIntent {
            mutations: vec![crate::sync::log::MutationEnvelope {
                schema_name: "Card".to_string(),
                mutation_type: "update".to_string(),
                key_value: crate::schema::types::key_value::KeyValue::new(
                    Some(format!("c{frontier_after}")),
                    None,
                ),
                fields_and_values: HashMap::new(),
                pub_key: "pk".to_string(),
                written_at,
                writer_id: "device-xyz".to_string(),
                logical_counter: 0,
                author_clock_signature: String::new(),
                author_clock_signature_version: 0,
                storage_prefix: None,
                provenance: None,
                imported_version: None,
                mutation_uuid: format!("m{frontier_after}"),
                source_file_name: None,
                metadata: None,
                aggregate_set: None,
                field_atom_uuids: HashMap::new(),
            }],
        };
        record
    }

    async fn install_mutation_apply_counter(
        engine: &SyncEngine,
    ) -> Arc<std::sync::atomic::AtomicUsize> {
        let applied = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let applied_for_callback = Arc::clone(&applied);
        engine
            .set_mutation_intent_applier(Arc::new(move |mutations| {
                let applied = Arc::clone(&applied_for_callback);
                Box::pin(async move {
                    applied.fetch_add(mutations.len(), std::sync::atomic::Ordering::SeqCst);
                    Ok(())
                })
            }))
            .await;
        applied
    }

    #[derive(Serialize)]
    struct LegacyRawIndexedMutation<'a> {
        original_index: u32,
        mutation: &'a RawValue,
    }

    #[derive(Serialize)]
    #[serde(tag = "wire_type", rename_all = "snake_case")]
    enum LegacyTransactionGroupWire<'a> {
        Shard {
            format_version: u32,
            group_id: &'a str,
            writer_id: &'a str,
            frontier_after: u64,
            schema_name: &'a str,
            shard_index: u32,
            shard_count: u32,
            operations: Vec<LegacyRawIndexedMutation<'a>>,
        },
        Manifest {
            format_version: u32,
            group_id: &'a str,
            writer_id: &'a str,
            frontier_after: u64,
            record_sha256: &'a str,
            operation_count: u32,
            shard_count: u32,
            record_template: &'a RawValue,
            shards: &'a [TransactionGroupShardRef],
        },
    }

    async fn legacy_transaction_group_objects(
        crypto: &Arc<dyn CryptoProvider>,
    ) -> (Vec<MutationLogSegment>, PinLogRecord) {
        let record = transaction_group_record();
        let LogOp::MutationIntent { mutations } = &record.entry.op else {
            unreachable!("transaction group fixture is a MutationIntent");
        };
        let raw_mutations = mutations
            .iter()
            .map(|mutation| {
                RawValue::from_string(serde_json::to_string(mutation).unwrap()).unwrap()
            })
            .collect::<Vec<_>>();
        let mut record_template = record.clone();
        let LogOp::MutationIntent {
            mutations: template_mutations,
        } = &mut record_template.entry.op
        else {
            unreachable!("transaction group fixture template is a MutationIntent");
        };
        template_mutations.clear();
        let raw_record_template =
            RawValue::from_string(serde_json::to_string(&record_template).unwrap()).unwrap();
        let legacy_record_json = serde_json::to_vec(&record).unwrap();
        let record_sha256 = sha256_hex(&legacy_record_json);
        let group_id = transaction_group_id(
            &record,
            TRANSACTION_GROUP_RECORD_DIGEST_LEGACY_JSON,
            &record_sha256,
        );
        let writer = record.writer_id.as_str();
        let mut by_schema = BTreeMap::<String, Vec<usize>>::new();
        for (index, mutation) in mutations.iter().enumerate() {
            by_schema
                .entry(mutation.schema_name.clone())
                .or_default()
                .push(index);
        }
        let operation_count = u32::try_from(mutations.len()).unwrap();
        let shard_count = u32::try_from(by_schema.len()).unwrap();
        let mut objects = Vec::new();
        let mut shard_refs = Vec::new();
        for (shard_index, (schema_name, indexes)) in by_schema.iter().enumerate() {
            let shard_index = u32::try_from(shard_index).unwrap();
            let shard_t0 = indexes
                .iter()
                .map(|index| mutations[*index].written_at)
                .max()
                .unwrap();
            let segment = MutationLogSegmentId::schema_folder(
                writer,
                schema_name,
                shard_t0,
                record.frontier_after,
                record.frontier_after,
            );
            let operation_indexes = indexes
                .iter()
                .map(|index| u32::try_from(*index).unwrap())
                .collect::<Vec<_>>();
            let operations = indexes
                .iter()
                .map(|index| LegacyRawIndexedMutation {
                    original_index: u32::try_from(*index).unwrap(),
                    mutation: raw_mutations[*index].as_ref(),
                })
                .collect();
            let wire = LegacyTransactionGroupWire::Shard {
                format_version: TRANSACTION_GROUP_WIRE_VERSION,
                group_id: &group_id,
                writer_id: writer,
                frontier_after: record.frontier_after,
                schema_name,
                shard_index,
                shard_count,
                operations,
            };
            let payload = seal_mutation_log_json(&wire, crypto, "legacy transaction group shard")
                .await
                .unwrap();
            shard_refs.push(TransactionGroupShardRef {
                schema_name: schema_name.clone(),
                shard_index,
                object_key: segment.object_key.clone(),
                ciphertext_sha256: sha256_hex(&payload),
                operation_indexes,
            });
            objects.push(MutationLogSegment { segment, payload });
        }
        let manifest_t0 = mutations
            .iter()
            .map(|mutation| mutation.written_at)
            .max()
            .unwrap();
        let manifest_wire = LegacyTransactionGroupWire::Manifest {
            format_version: TRANSACTION_GROUP_WIRE_VERSION,
            group_id: &group_id,
            writer_id: writer,
            frontier_after: record.frontier_after,
            record_sha256: &record_sha256,
            operation_count,
            shard_count,
            record_template: raw_record_template.as_ref(),
            shards: &shard_refs,
        };
        let manifest_segment = MutationLogSegmentId::schema_folder(
            writer,
            TRANSACTION_GROUP_MANIFEST_SCHEMA,
            manifest_t0,
            record.frontier_after,
            record.frontier_after,
        );
        let manifest_payload =
            seal_mutation_log_json(&manifest_wire, crypto, "legacy transaction group manifest")
                .await
                .unwrap();
        objects.push(MutationLogSegment {
            segment: manifest_segment,
            payload: manifest_payload,
        });
        (objects, record)
    }

    /// A corrupt non-trailing row makes the GC reference page unknown.
    #[tokio::test]
    async fn pin_log_gc_reference_page_fails_closed_on_unreadable_row() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        let store = engine.pin_log.pin_log_store().await.expect("pin-log store");
        let mut valid = secret_bearing_record(b"valid");
        valid.frontier_after = 2;
        valid.entry.seq = 2;
        store
            .batch_put(vec![
                (pin_log_entry_key("personal", 1), b"not-json".to_vec()),
                (
                    pin_log_entry_key("personal", 2),
                    serde_json::to_vec(&valid).expect("valid row"),
                ),
            ])
            .await
            .expect("seed pin-log rows");

        let error = engine
            .pin_log
            .pending_pin_log_atom_uuids_page(None, 8)
            .await
            .expect_err("an unreadable non-trailing row must fail the GC page");
        assert!(error.contains("decode durable pin log record"), "{error}");
    }

    #[tokio::test]
    async fn seal_mutation_log_segment_uses_writer_id_path() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x31u8; 32]));
        let record = secret_bearing_record(b"v");
        let sealed = seal_mutation_log_segment(&record, &crypto).await.unwrap();
        assert_eq!(sealed.segment.object_key, "log/device-xyz/42.enc");
        assert_eq!(sealed.segment.writer_id.as_deref(), Some("device-xyz"));
        assert_eq!(sealed.segment.through_id, 42);
    }

    #[tokio::test]
    async fn seal_mutation_intent_uses_typed_schema_folder_path() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x32u8; 32]));
        let mut record = secret_bearing_record(b"v");
        record.frontier_after = 7;
        record.entry.op = LogOp::MutationIntent {
            mutations: vec![crate::sync::log::MutationEnvelope {
                schema_name: "Card".to_string(),
                mutation_type: "update".to_string(),
                key_value: crate::schema::types::key_value::KeyValue::new(
                    Some("c1".to_string()),
                    None,
                ),
                fields_and_values: HashMap::new(),
                pub_key: "pk".to_string(),
                written_at: 1_700_000_000_000_000_042,
                writer_id: "device-xyz".to_string(),
                logical_counter: 0,
                author_clock_signature: String::new(),
                author_clock_signature_version: 0,
                storage_prefix: None,
                provenance: None,
                imported_version: None,
                mutation_uuid: "m1".to_string(),
                source_file_name: None,
                metadata: None,
                aggregate_set: None,
                field_atom_uuids: HashMap::new(),
            }],
        };
        let sealed = seal_mutation_log_segment(&record, &crypto).await.unwrap();
        assert_eq!(
            sealed.segment.object_key,
            "log/device-xyz/Card/1700000000000000042_7.enc"
        );
        assert_eq!(sealed.segment.sequence, Some(7));
    }

    #[tokio::test]
    async fn typed_batch_replay_uses_max_t0_across_all_records() {
        let engine = test_engine(SyncConfig::default());
        let records = [
            typed_mutation_intent_record(1, 200),
            typed_mutation_intent_record(2, 100),
        ];
        let sealed = seal_mutation_log_segment_batch(&records, &engine.crypto)
            .await
            .unwrap();
        assert_eq!(sealed.segment.utc_nanos, Some(200));
        assert_eq!(sealed.segment.sequence, Some(2));
        assert_eq!(
            sealed.segment.object_key,
            "log/device-xyz/Card/0000000000000000200_2.enc"
        );

        let applied = install_mutation_apply_counter(&engine).await;

        let report = replay_mutation_log_segments(&engine, &[sealed], &Frontier::scalar(0))
            .await
            .expect("the key T0 represents the complete typed batch");
        assert_eq!(report.segments_applied, 1);
        assert_eq!(report.records_applied, 2);
        assert_eq!(applied.load(std::sync::atomic::Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn typed_batch_replay_rejects_a_key_rebound_to_the_last_record_t0() {
        let engine = test_engine(SyncConfig::default());
        let records = [
            typed_mutation_intent_record(1, 200),
            typed_mutation_intent_record(2, 100),
        ];
        let mut sealed = seal_mutation_log_segment_batch(&records, &engine.crypto)
            .await
            .unwrap();
        sealed.segment.utc_nanos = Some(100);
        sealed.segment.object_key = sealed.segment.expected_object_key();

        let applied = install_mutation_apply_counter(&engine).await;

        let error = replay_mutation_log_segments(&engine, &[sealed], &Frontier::scalar(0))
            .await
            .expect_err("the typed key must bind the maximum T0 across the complete batch");
        assert!(
            error.to_string().contains("typed identity mismatch"),
            "{error}"
        );
        assert_eq!(applied.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn typed_batch_replay_rejects_a_schema_rebound_hidden_before_the_last_record() {
        let engine = test_engine(SyncConfig::default());
        let mut records = [
            typed_mutation_intent_record(1, 200),
            typed_mutation_intent_record(2, 100),
        ];
        let LogOp::MutationIntent { mutations } = &mut records[0].entry.op else {
            unreachable!("the typed record helper always creates a MutationIntent");
        };
        mutations[0].schema_name = "Brain".to_string();
        let sealed = MutationLogSegment {
            segment: MutationLogSegmentId::schema_folder("device-xyz", "Card", 100, 2, 2),
            payload: seal_mutation_log_json(&records, &engine.crypto, "schema rebound batch")
                .await
                .unwrap(),
        };
        let applied = install_mutation_apply_counter(&engine).await;

        let error = replay_mutation_log_segments(&engine, &[sealed], &Frontier::scalar(0))
            .await
            .expect_err("an earlier record cannot hide a different schema behind the last record");
        assert!(error.to_string().contains("mix schema streams"), "{error}");
        assert_eq!(applied.load(std::sync::atomic::Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn transaction_group_seals_one_shard_per_schema_and_a_manifest_last() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x33u8; 32]));
        let record = transaction_group_record();

        let objects = seal_transaction_group(&record, &crypto).await.unwrap();

        assert_eq!(objects.len(), 4);
        assert_eq!(
            objects
                .iter()
                .map(|object| object.segment.schema_name.as_deref().unwrap())
                .collect::<Vec<_>>(),
            vec![
                "BoardCard",
                "Brain",
                "Milestone",
                TRANSACTION_GROUP_MANIFEST_SCHEMA,
            ]
        );
        assert!(objects
            .iter()
            .all(|object| object.segment.sequence == Some(record.frontier_after)));
        let manifest_json = open_mutation_log_json(&objects.last().unwrap().payload, &crypto)
            .await
            .unwrap();
        let manifest: TransactionGroupWireV2 = serde_json::from_slice(&manifest_json).unwrap();
        assert!(matches!(
            manifest,
            TransactionGroupWireV2::Manifest {
                record_digest_version: TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1,
                ..
            }
        ));

        let units = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .unwrap();
        assert_eq!(units.len(), 1);
        assert!(units[0].transaction_group);
        assert_eq!(
            canonical_transaction_group_record_json(&units[0].records[0]).unwrap(),
            canonical_transaction_group_record_json(&record).unwrap(),
            "restore must reconstruct the source record and operation order"
        );

        let retry = seal_transaction_group(&record, &crypto).await.unwrap();
        assert_eq!(
            objects
                .iter()
                .map(|object| object.segment.object_key.as_str())
                .collect::<Vec<_>>(),
            retry
                .iter()
                .map(|object| object.segment.object_key.as_str())
                .collect::<Vec<_>>(),
            "a retry must use stable object keys"
        );
    }

    #[test]
    fn transaction_group_record_digest_ignores_hash_map_order() {
        fn reverse_map<V>(map: &mut HashMap<String, V>) {
            let mut entries = std::mem::take(map).into_iter().collect::<Vec<_>>();
            entries.sort_unstable_by(|left, right| right.0.cmp(&left.0));
            map.extend(entries);
        }

        let first = transaction_group_record();
        let mut second = first.clone();
        let LogOp::MutationIntent { mutations } = &mut second.entry.op else {
            unreachable!("transaction group fixture is a MutationIntent");
        };
        for mutation in mutations {
            reverse_map(&mut mutation.fields_and_values);
            reverse_map(&mut mutation.field_atom_uuids);
            if let Some(metadata) = &mut mutation.metadata {
                reverse_map(metadata);
            }
        }

        let first_digest = transaction_group_record_sha256(&first).unwrap();
        let second_digest = transaction_group_record_sha256(&second).unwrap();
        assert_eq!(first_digest, second_digest);
        assert_eq!(
            transaction_group_id(
                &first,
                TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1,
                &first_digest,
            ),
            transaction_group_id(
                &second,
                TRANSACTION_GROUP_RECORD_DIGEST_SORTED_JSON_V1,
                &second_digest,
            )
        );
    }

    #[tokio::test]
    async fn transaction_group_replays_marker_absent_legacy_record_digest() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x37u8; 32]));
        let (objects, record) = legacy_transaction_group_objects(&crypto).await;
        let manifest_json = open_mutation_log_json(&objects.last().unwrap().payload, &crypto)
            .await
            .unwrap();
        assert!(!String::from_utf8(manifest_json)
            .unwrap()
            .contains("record_digest_version"));

        let units = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .unwrap();
        assert_eq!(units.len(), 1);
        assert!(units[0].transaction_group);
        assert_eq!(
            canonical_transaction_group_record_json(&units[0].records[0]).unwrap(),
            canonical_transaction_group_record_json(&record).unwrap()
        );
    }

    #[tokio::test]
    async fn transaction_group_record_digest_rejects_a_rebound_semantic_change() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x38u8; 32]));
        let mut objects = seal_transaction_group(&transaction_group_record(), &crypto)
            .await
            .unwrap();
        let shard_json = open_mutation_log_json(&objects[0].payload, &crypto)
            .await
            .unwrap();
        let mut shard: TransactionGroupWireV2 = serde_json::from_slice(&shard_json).unwrap();
        let TransactionGroupWireV2::Shard {
            shard_index,
            operations,
            ..
        } = &mut shard
        else {
            unreachable!("the first object is a transaction group shard");
        };
        operations[0]
            .mutation
            .fields_and_values
            .insert("alpha".to_string(), serde_json::json!("corrupt"));
        let changed_shard_index = *shard_index;
        objects[0].payload = seal_mutation_log_json(&shard, &crypto, "changed shard")
            .await
            .unwrap();
        let changed_shard_sha256 = sha256_hex(&objects[0].payload);

        let manifest_index = objects.len() - 1;
        let manifest_json = open_mutation_log_json(&objects[manifest_index].payload, &crypto)
            .await
            .unwrap();
        let mut manifest: TransactionGroupWireV2 = serde_json::from_slice(&manifest_json).unwrap();
        let TransactionGroupWireV2::Manifest { shards, .. } = &mut manifest else {
            unreachable!("the last object is a transaction group manifest");
        };
        shards
            .iter_mut()
            .find(|reference| reference.shard_index == changed_shard_index)
            .unwrap()
            .ciphertext_sha256 = changed_shard_sha256;
        objects[manifest_index].payload =
            seal_mutation_log_json(&manifest, &crypto, "rebound manifest")
                .await
                .unwrap();

        let error = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .expect_err("the record digest must reject a semantically changed shard");
        assert!(
            error.contains("reconstructed record hash mismatch"),
            "{error}"
        );
    }

    #[tokio::test]
    async fn transaction_group_rejects_unknown_record_digest_version() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x39u8; 32]));
        let mut objects = seal_transaction_group(&transaction_group_record(), &crypto)
            .await
            .unwrap();
        let manifest_index = objects.len() - 1;
        let manifest_json = open_mutation_log_json(&objects[manifest_index].payload, &crypto)
            .await
            .unwrap();
        let mut manifest: TransactionGroupWireV2 = serde_json::from_slice(&manifest_json).unwrap();
        let TransactionGroupWireV2::Manifest {
            record_digest_version,
            ..
        } = &mut manifest
        else {
            unreachable!("the last object is a transaction group manifest");
        };
        *record_digest_version = 99;
        objects[manifest_index].payload =
            seal_mutation_log_json(&manifest, &crypto, "unknown-version manifest")
                .await
                .unwrap();

        let error = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .expect_err("an unknown record digest version must fail closed");
        assert!(
            error.contains("unsupported transaction group record digest version 99"),
            "{error}"
        );
    }

    #[test]
    fn mutation_log_segment_id_reads_app_qualified_schema_path() {
        let object_key = "log/device-a/lagprobe/LagProbeKey/1700000000000000042_7.enc";
        let segment = mutation_log_segment_id_from_object_key(object_key, 7).unwrap();
        assert_eq!(segment.writer_id.as_deref(), Some("device-a"));
        assert_eq!(segment.schema_name.as_deref(), Some("lagprobe/LagProbeKey"));
        assert_eq!(segment.utc_nanos, Some(1_700_000_000_000_000_042));
        assert_eq!(segment.sequence, Some(7));
        assert_eq!(segment.object_key, object_key);
    }

    #[test]
    fn mutation_log_segment_id_rejects_invalid_app_qualified_schema_path() {
        for object_key in [
            "log/device-a/lagprobe//LagProbeKey/1700000000000000042_7.enc",
            "log/device-a/lagprobe/../LagProbeKey/1700000000000000042_7.enc",
            "log/device-a/lagprobe/LagProbeKey/not-a-t0_7.enc",
        ] {
            assert!(
                mutation_log_segment_id_from_object_key(object_key, 7).is_err(),
                "accepted invalid mutation-log key: {object_key}"
            );
        }
    }

    #[tokio::test]
    async fn transaction_group_without_manifest_fails_before_replay() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x34u8; 32]));
        let mut objects = seal_transaction_group(&transaction_group_record(), &crypto)
            .await
            .unwrap();
        objects.pop();

        let error = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .expect_err("shards without a commit manifest must not become replay units");
        assert!(error.contains("no commit manifest"), "{error}");
    }

    #[tokio::test]
    async fn transaction_group_with_missing_shard_fails_before_replay() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x35u8; 32]));
        let mut objects = seal_transaction_group(&transaction_group_record(), &crypto)
            .await
            .unwrap();
        objects.remove(0);

        let error = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .expect_err("a manifest cannot commit an incomplete transaction group");
        assert!(error.contains("shard count"), "{error}");
    }

    #[tokio::test]
    async fn transaction_group_rejects_a_resealed_shard_not_named_by_manifest() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x36u8; 32]));
        let mut objects = seal_transaction_group(&transaction_group_record(), &crypto)
            .await
            .unwrap();
        let shard_json = open_mutation_log_json(&objects[0].payload, &crypto)
            .await
            .unwrap();
        let shard: TransactionGroupWireV2 = serde_json::from_slice(&shard_json).unwrap();
        objects[0].payload = seal_mutation_log_json(&shard, &crypto, "replacement shard")
            .await
            .unwrap();

        let error = open_mutation_log_replay_units(&objects, &crypto)
            .await
            .expect_err("the manifest binds each shard ciphertext digest");
        assert!(error.contains("manifest validation"), "{error}");
    }

    /// REGRESSION (P0, 2026-08-09): the sealed payload must not be plaintext.
    ///
    /// `seal_mutation_log_segment` was `serde_json::to_vec` and nothing else,
    /// so every object it wrote to the shared `log/` prefix was readable JSON.
    /// 3,171 objects / 1.20 GB of real user records reached production R2 that
    /// way. This asserts the three things that were each independently false:
    /// the payload does not begin with `{`, the record's field names do not
    /// appear in it, and a secret value round-tripped through the record is not
    /// present in the bytes.
    #[tokio::test]
    async fn sealed_mutation_log_segment_payload_is_never_plaintext() {
        const SECRET: &[u8] = b"tom-private-brain-content-do-not-leak";
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x42u8; 32]));
        let record = secret_bearing_record(SECRET);

        let sealed = seal_mutation_log_segment(&record, &crypto).await.unwrap();

        assert_ne!(
            sealed.payload.first(),
            Some(&b'{'),
            "payload starts with '{{' — it is bare JSON, not an envelope. This is \
             exactly the byte the decryptability prover misread as \
             'unsupported log envelope version: 123' (0x7B == 123)."
        );

        // `secret_bearing_record` base64-encodes both the key and the value, so
        // the RAW forms of `SECRET` and `atom:secret-key` never appear in a
        // `PinLogRecord`'s JSON — not even in the broken plaintext version that
        // actually shipped. Those two needles alone would pass against the very
        // defect this test exists to catch; only the structural field names were
        // doing real work. Assert the encoded forms too, so the value-leak claim
        // is tested rather than merely stated.
        let secret_b64 = base64::engine::general_purpose::STANDARD.encode(SECRET);
        let key_b64 = base64::engine::general_purpose::STANDARD.encode(b"atom:secret-key");

        let haystack = sealed.payload.as_slice();
        for needle in [
            SECRET,
            b"atom:secret-key".as_slice(),
            secret_b64.as_bytes(),
            key_b64.as_bytes(),
            b"model_version".as_slice(),
            b"frontier_after".as_slice(),
            b"BatchPut".as_slice(),
            b"device-xyz".as_slice(),
        ] {
            assert!(
                !haystack.windows(needle.len()).any(|w| w == needle),
                "sealed payload leaks {:?} in cleartext",
                String::from_utf8_lossy(needle)
            );
        }
    }

    /// The ciphertext must be openable, or we have merely made the data
    /// unreadable to everyone including us.
    #[tokio::test]
    async fn sealed_mutation_log_segment_round_trips_through_unseal() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x99u8; 32]));
        let record = secret_bearing_record(b"round-trip-me");

        let sealed = seal_mutation_log_segment(&record, &crypto).await.unwrap();
        let recovered = unseal_mutation_log_segment(&sealed.payload, &crypto)
            .await
            .unwrap();
        assert_eq!(recovered.len(), 1);
        let recovered = &recovered[0];

        assert_eq!(recovered.writer_id, record.writer_id);
        assert_eq!(recovered.frontier_after, record.frontier_after);
        assert_eq!(recovered.target_id, record.target_id);
        assert_eq!(
            serde_json::to_vec(&recovered.entry).unwrap(),
            serde_json::to_vec(&record.entry).unwrap()
        );
    }

    #[tokio::test]
    async fn mutation_log_segment_batches_records_and_reads_legacy_single_payloads() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x9Au8; 32]));
        let mut records = Vec::new();
        for seq in 42..45 {
            let mut record = secret_bearing_record(format!("batch-{seq}").as_bytes());
            record.frontier_after = seq;
            record.entry.seq = seq;
            records.push(record);
        }

        let sealed = seal_mutation_log_segment_batch(&records, &crypto)
            .await
            .unwrap();
        assert_eq!(sealed.segment.through_id, 44);
        assert_eq!(sealed.segment.object_key, "log/device-xyz/44.enc");
        let recovered = unseal_mutation_log_segment(&sealed.payload, &crypto)
            .await
            .unwrap();
        assert_eq!(
            recovered
                .iter()
                .map(|record| record.frontier_after)
                .collect::<Vec<_>>(),
            vec![42, 43, 44]
        );

        // Historical objects carried one JSON object rather than an array.
        let legacy_json = serde_json::to_vec(&records[0]).unwrap();
        let mut hasher = Sha256::new();
        hasher.update(&legacy_json);
        let hash: [u8; MUTATION_LOG_SEGMENT_HASH_SIZE] = hasher.finalize().into();
        let mut plaintext = Vec::with_capacity(hash.len() + legacy_json.len());
        plaintext.extend_from_slice(&hash);
        plaintext.extend_from_slice(&legacy_json);
        let legacy_payload = crypto.encrypt(&plaintext).await.unwrap();
        let legacy = unseal_mutation_log_segment(&legacy_payload, &crypto)
            .await
            .unwrap();
        assert_eq!(legacy.len(), 1);
        assert_eq!(legacy[0].frontier_after, 42);
    }

    /// A tampered segment must fail the hash check rather than deserialize into
    /// an attacker-chosen record.
    #[tokio::test]
    async fn unseal_mutation_log_segment_rejects_a_tampered_payload() {
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0xABu8; 32]));
        let record = secret_bearing_record(b"integrity");
        let sealed = seal_mutation_log_segment(&record, &crypto).await.unwrap();

        let mut tampered = sealed.payload.clone();
        let last = tampered.len() - 1;
        tampered[last] ^= 0xFF;

        assert!(
            unseal_mutation_log_segment(&tampered, &crypto)
                .await
                .is_err(),
            "a flipped ciphertext byte must not unseal"
        );
    }

    /// A different key must not open the segment — proves the payload is bound
    /// to the content key rather than merely encoded.
    #[tokio::test]
    async fn unseal_mutation_log_segment_rejects_a_foreign_key() {
        let writer: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x01u8; 32]));
        let stranger: Arc<dyn CryptoProvider> =
            Arc::new(LocalCryptoProvider::from_key([0x02u8; 32]));
        let record = secret_bearing_record(b"not-yours");

        let sealed = seal_mutation_log_segment(&record, &writer).await.unwrap();

        assert!(
            unseal_mutation_log_segment(&sealed.payload, &stranger)
                .await
                .is_err(),
            "a foreign key must not open a sealed segment"
        );
    }

    /// Phase B: two concurrent writers append under load; both streams seal to
    /// distinct `log/{writer_id}/` prefixes on a shared plane without a
    /// snapshot lock or continuous full-home re-snapshot.
    #[tokio::test]
    async fn concurrent_dual_writer_mutation_log_streams_append_without_snapshot() {
        let cfg = SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        };
        let engine_a = test_engine_with_device("writer-a", cfg.clone());
        let engine_b = test_engine_with_device("writer-b", cfg);
        assert!(engine_a.pin_log.continuous_sealed_home_backup_demoted());
        assert!(engine_b.pin_log.continuous_sealed_home_backup_demoted());

        let n = 10u8;
        // Concurrent synthetic write load — no shared snapshot lock.
        let (res_a, res_b) = tokio::join!(
            async {
                for i in 0..n {
                    engine_a
                        .record_put("main", format!("a-{i}").as_bytes(), &[i])
                        .await
                        .expect("writer-a local append must never fail for network/upload");
                }
            },
            async {
                for i in 0..n {
                    engine_b
                        .record_put("main", format!("b-{i}").as_bytes(), &[i.wrapping_add(50)])
                        .await
                        .expect("writer-b local append must never fail for network/upload");
                }
            }
        );
        let _ = (res_a, res_b);

        let rec_a = engine_a
            .pin_log
            .pin_log_records_for_target("")
            .await
            .unwrap();
        let rec_b = engine_b
            .pin_log
            .pin_log_records_for_target("")
            .await
            .unwrap();
        assert_eq!(rec_a.len(), n as usize, "writer-a durable stream length");
        assert_eq!(rec_b.len(), n as usize, "writer-b durable stream length");
        assert!(
            rec_a.iter().all(|r| r.writer_id == "writer-a"),
            "engine A records must stamp writer-a"
        );
        assert!(
            rec_b.iter().all(|r| r.writer_id == "writer-b"),
            "engine B records must stamp writer-b"
        );
        // Continuous capture must not freeze multi-device progress.
        for eng in [&engine_a, &engine_b] {
            let st = eng.pin_log.pin_log_statuses().await;
            assert_eq!(st.len(), 1);
            assert!(
                !st[0].active,
                "continuous multi-writer must not surface pin freeze"
            );
            assert_eq!(st[0].sealed_base_count, 0);
        }

        // Shared cloud plane: both writers seal/upload independently (no CAS
        // snapshot required to publish either stream).
        let mut plane = MutationLogLocalCloud::new();
        let report_a = engine_a
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine_a,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        let report_b = engine_b
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine_b,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(report_a.segments_uploaded, 1);
        assert_eq!(report_b.segments_uploaded, 1);
        assert_eq!(report_a.writer_id, "writer-a");
        assert_eq!(report_b.writer_id, "writer-b");
        assert!(
            report_a
                .object_keys
                .iter()
                .all(|k| k.starts_with("log/writer-a/")),
            "A keys: {:?}",
            report_a.object_keys
        );
        assert!(
            report_b
                .object_keys
                .iter()
                .all(|k| k.starts_with("log/writer-b/")),
            "B keys: {:?}",
            report_b.object_keys
        );

        assert_eq!(plane.keys_under_writer("writer-a").len(), 1);
        assert_eq!(plane.keys_under_writer("writer-b").len(), 1);
        assert_eq!(plane.segment_count(), 2);
        let mut uploaded_records = Vec::new();
        for segment in plane.segments.values() {
            uploaded_records.extend(
                unseal_mutation_log_segment(&segment.payload, &engine_a.crypto)
                    .await
                    .expect("batched multi-writer segment must remain readable"),
            );
        }
        assert_eq!(
            uploaded_records.len(),
            (n as usize) * 2,
            "two batched objects must retain every logical mutation"
        );
        assert_eq!(
            uploaded_records
                .iter()
                .filter(|record| record.writer_id == "writer-a")
                .count(),
            n as usize
        );
        assert_eq!(
            uploaded_records
                .iter()
                .filter(|record| record.writer_id == "writer-b")
                .count(),
            n as usize
        );
        assert!(plane.published_f("writer-a") > 0);
        assert!(plane.published_f("writer-b") > 0);
        let vf = plane.vector_frontier();
        assert_eq!(vf.len(), 2, "vector F must list both writers: {vf:?}");
        assert!(vf.contains_key("writer-a") && vf.contains_key("writer-b"));
        assert_eq!(
            plane.writer_ids(),
            vec!["writer-a".to_string(), "writer-b".to_string()]
        );

        // Head / status: vector F is first-class (not scalar-only).
        use crate::sync::snapshot_log::LatestCasPayload;
        let head = LatestCasPayload::with_vector_f("", vf.clone(), plane.latest_counter().max(1));
        assert!(matches!(
            head.frontier,
            crate::sync::snapshot_log::Frontier::Vector { .. }
        ));
        assert_eq!(head.frontier.as_writer_hwm(None).len(), 2);
        assert_eq!(
            head.frontier.max_through(),
            vf.values().copied().max().unwrap()
        );

        // Each engine's pin-log status surfaces its own HWM after upload.
        let st_a = engine_a.pin_log.pin_log_statuses().await;
        let st_b = engine_b.pin_log.pin_log_statuses().await;
        assert_eq!(
            st_a[0].published_f_by_writer.get("writer-a"),
            vf.get("writer-a")
        );
        assert_eq!(
            st_b[0].published_f_by_writer.get("writer-b"),
            vf.get("writer-b")
        );

        // Agent-facing SyncStatus.mutation_log merges process plane + runtime map.
        // Seed each engine's process-local plane with the shared multi-writer F so
        // status head can express both writers (peer plane knowledge).
        for eng in [&engine_a, &engine_b] {
            let mut proc = eng.mutation_log_plane.lock().await;
            for (wid, thr) in &vf {
                proc.advance_published_f(wid, *thr);
            }
        }
        let status_a = engine_a.status().await;
        let ml = status_a
            .mutation_log
            .as_ref()
            .expect("mutation_log plane status");
        assert_eq!(
            ml.frontier_f_by_writer.len(),
            2,
            "status head F must list both writers: {:?}",
            ml.frontier_f_by_writer
        );
        assert_eq!(
            ml.frontier_f_by_writer.get("writer-a"),
            vf.get("writer-a"),
            "writer-a through_seq"
        );
        assert_eq!(
            ml.frontier_f_by_writer.get("writer-b"),
            vf.get("writer-b"),
            "writer-b through_seq"
        );
        assert_eq!(ml.frontier_f, head.frontier.max_through());
        // Scalar remains max (compat); vector is the multi-device source of truth.
        assert!(ml.frontier_f_by_writer.values().all(|&t| t > 0));

        // Idle re-upload is a no-op for both writers (per-writer F respected).
        let idle_a = engine_a
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine_a,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        let idle_b = engine_b
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine_b,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert_eq!(idle_a.segments_uploaded, 0);
        assert_eq!(idle_b.segments_uploaded, 0);
        assert_eq!(plane.segment_count(), 2);
    }

    /// Pure concurrent seal: two writers put segments onto a shared plane
    /// without serializing through a snapshot / latest CAS.
    #[test]
    fn concurrent_seal_two_writers_share_mutation_log_plane() {
        use std::sync::{Arc, Mutex};
        use std::thread;

        let plane = Arc::new(Mutex::new(MutationLogLocalCloud::new()));
        let crypto: Arc<dyn CryptoProvider> = Arc::new(LocalCryptoProvider::from_key([0x64u8; 32]));
        let mut handles = Vec::new();
        for (wid, base_seq) in [("writer-a", 1u64), ("writer-b", 100u64)] {
            let plane = Arc::clone(&plane);
            let crypto = Arc::clone(&crypto);
            handles.push(thread::spawn(move || {
                // Sealing is async now that it encrypts; this test is about the
                // plane's concurrency geometry, so each writer thread drives the
                // seal on its own current-thread runtime.
                let rt = tokio::runtime::Builder::new_current_thread()
                    .build()
                    .expect("writer runtime");
                for i in 0..8u64 {
                    let seq = base_seq + i;
                    let record = PinLogRecord {
                        model_version: 1,
                        target_id: "personal".into(),
                        target_label: "personal".into(),
                        target_prefix: String::new(),
                        writer_id: wid.into(),
                        frontier_after: seq,
                        timestamp_ms: i,
                        entry: LogEntry {
                            seq,
                            device_id: wid.into(),
                            timestamp_ms: i,
                            op: crate::sync::log::LogOp::Put {
                                namespace: "main".into(),
                                key: base64::engine::general_purpose::STANDARD
                                    .encode(format!("{wid}-{i}").as_bytes()),
                                value: base64::engine::general_purpose::STANDARD.encode(b"v"),
                            },
                        },
                    };
                    let sealed = rt
                        .block_on(seal_mutation_log_segment(&record, &crypto))
                        .unwrap();
                    let mut g = plane.lock().unwrap();
                    g.put_segment(&sealed).unwrap();
                    g.advance_published_f(wid, seq);
                }
            }));
        }
        for h in handles {
            h.join().expect("writer thread");
        }
        let plane = plane.lock().unwrap();
        assert_eq!(plane.keys_under_writer("writer-a").len(), 8);
        assert_eq!(plane.keys_under_writer("writer-b").len(), 8);
        assert_eq!(plane.segment_count(), 16);
        assert_eq!(plane.published_f("writer-a"), 8);
        assert_eq!(plane.published_f("writer-b"), 107);
        assert!(plane
            .keys_under_writer("writer-a")
            .iter()
            .all(|k| k.starts_with("log/writer-a/")));
        assert!(plane
            .keys_under_writer("writer-b")
            .iter()
            .all(|k| k.starts_with("log/writer-b/")));
    }

    // ---- bounded pin-log scan (2026-08-09) ---------------------------------
    //
    // Regression cover for the OOM that took Tom's primary down three times on
    // 2026-08-08: `run_mutation_log_segment_upload_cycle` read the WHOLE target
    // prefix — keys and values — and only then applied `max_segments`. With a
    // 12.33 GiB `sync_pin_log` plane, every boot with cloud sync armed drove RSS
    // from 0 to 13-15 GiB in ~3 minutes and the memory guard SIGKILLed the
    // daemon. The cap bounded what the cycle published and nothing about what it
    // read.

    #[test]
    fn prefix_upper_bound_is_exclusive_and_admits_no_finite_successor() {
        assert_eq!(
            prefix_upper_bound(b"target:x:entry:"),
            Some(b"target:x:entry;".to_vec())
        );
        // 0xFF tail is dropped, not incremented into a carry.
        assert_eq!(prefix_upper_bound(&[0x41, 0xFF, 0xFF]), Some(vec![0x42]));
        // No finite successor -> None, so the caller cannot inherit a bound
        // that would silently make the range empty.
        assert_eq!(prefix_upper_bound(&[0xFF, 0xFF]), None);
        assert_eq!(prefix_upper_bound(b""), None);
    }

    #[test]
    fn key_after_is_the_immediate_successor() {
        let k = b"target:p:entry:00000000000000000007".to_vec();
        let next = key_after(&k);
        assert!(next > k, "cursor must advance strictly");
        // Nothing sorts between a key and key||0x00, so no row can be skipped.
        assert_eq!(next, [k.as_slice(), &[0u8]].concat());
    }

    /// The whole point: the cycle's read cost tracks the BATCH, not the plane.
    #[tokio::test]
    async fn upload_cycle_reads_only_the_batch_it_will_publish() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let plane_records = MUTATION_LOG_SEGMENT_MAX_RECORDS + 17;
        for i in 0..plane_records {
            engine
                .record_put("main", format!("bounded-k{i}").as_bytes(), &[1])
                .await
                .unwrap();
        }

        let mut plane = MutationLogLocalCloud::new();
        let report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                1,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();

        assert_eq!(report.segments_uploaded, 1);
        assert_eq!(report.records_considered, MUTATION_LOG_SEGMENT_MAX_RECORDS);
        assert_eq!(
            report.rows_scanned, MUTATION_LOG_SEGMENT_MAX_RECORDS,
            "a one-segment batch must not read past its 1,000-record bound; before the paged \
             read this was the whole plane"
        );
        assert!(
            report.records_considered_is_lower_bound,
            "the scan stopped early, so records_considered is a floor and must say so"
        );
        assert!(
            !report.scan_row_budget_exhausted,
            "stopping on a filled batch is not a budget stop"
        );
    }

    /// A scan that reached the end reports a real total, not a floor.
    #[tokio::test]
    async fn upload_cycle_reports_a_total_when_the_scan_reaches_the_end() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..3 {
            engine
                .record_put("main", format!("exact-k{i}").as_bytes(), &[1])
                .await
                .unwrap();
        }

        let mut plane = MutationLogLocalCloud::new();
        let report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                64,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();

        assert_eq!(report.segments_uploaded, 1);
        assert_eq!(report.records_considered, 3);
        assert_eq!(report.rows_scanned, 3);
        assert!(
            !report.records_considered_is_lower_bound,
            "the plane was exhausted, so the count is a total"
        );
    }

    /// One missing atom must not fail-close the cycle. Later MutationIntent
    /// rows still seal and publish (CoW DEV proof 2026-08-20).
    #[tokio::test]
    async fn missing_atom_intent_is_quarantined_and_later_records_still_upload() {
        use crate::sync::engine::types::MutationIntentMaterializer;
        use crate::sync::log::{LogOp, MutationEnvelope};
        use std::collections::HashMap;
        use std::sync::Arc;

        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let materializer: MutationIntentMaterializer = Arc::new(|envelopes| {
            Box::pin(async move {
                for envelope in &envelopes {
                    if envelope
                        .field_atom_uuids
                        .values()
                        .any(|id| id == "dead-atom")
                    {
                        return Err("missing atom dead-atom for field title".to_string());
                    }
                }
                Ok(envelopes)
            })
        });
        engine.set_mutation_intent_materializer(materializer).await;

        let envelope = |atom: &str, seq: u64| {
            let mut field_atom_uuids = HashMap::new();
            field_atom_uuids.insert("title".to_string(), atom.to_string());
            MutationEnvelope {
                schema_name: "Note".to_string(),
                mutation_type: "update".to_string(),
                key_value: crate::schema::types::key_value::KeyValue::new(
                    Some(format!("n{seq}")),
                    None,
                ),
                fields_and_values: HashMap::new(),
                pub_key: "pk".to_string(),
                written_at: seq,
                writer_id: "test-device".to_string(),
                logical_counter: 0,
                author_clock_signature: String::new(),
                author_clock_signature_version: 0,
                storage_prefix: None,
                provenance: None,
                imported_version: None,
                mutation_uuid: format!("m{seq}"),
                source_file_name: None,
                metadata: None,
                aggregate_set: None,
                field_atom_uuids,
            }
        };
        let record = |seq: u64, atom: &str| PinLogRecord {
            model_version: PIN_LOG_MODEL_VERSION,
            target_id: "personal".to_string(),
            target_label: "personal".to_string(),
            target_prefix: String::new(),
            writer_id: "test-device".to_string(),
            frontier_after: seq,
            timestamp_ms: seq,
            entry: LogEntry {
                seq,
                timestamp_ms: seq,
                device_id: "test-device".to_string(),
                op: LogOp::MutationIntent {
                    mutations: vec![envelope(atom, seq)],
                },
            },
        };
        engine
            .pin_log
            .persist_pin_log_records(&[record(1, "dead-atom"), record(2, "live-atom")])
            .await
            .expect("persist mixed pin-log intents");

        let mut plane = MutationLogLocalCloud::new();
        let report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .expect("missing-atom row must not fail-close the cycle");

        assert_eq!(report.records_quarantined, 1);
        assert_eq!(
            report.last_quarantine_reason.as_deref(),
            Some("missing atom dead-atom for field title")
        );
        assert_eq!(report.segments_uploaded, 1);
        assert_eq!(
            report.records_considered, 1,
            "only the sealable row publishes"
        );
        assert_eq!(plane.segment_count(), 1);
        let keys = plane.keys_under_writer("test-device");
        assert_eq!(keys.len(), 1);
        assert!(
            keys[0].starts_with("log/test-device/"),
            "writer-scoped object key, got {}",
            keys[0]
        );
        let status = engine
            .pin_log
            .pin_log_statuses()
            .await
            .into_iter()
            .find(|s| s.target_id == "personal");
        if let Some(status) = status {
            assert_eq!(status.records_quarantined, 1);
            assert_eq!(
                status.last_quarantine_reason.as_deref(),
                Some("missing atom dead-atom for field title")
            );
        }
    }

    /// A dropped record must leave a receipt.
    ///
    /// The quarantine drop is permanent and cloud never saw the record, so the
    /// only thing standing between it and an untraceable hole is the tombstone.
    /// Before 2026-08-22 there was none: the frontier list was a local `Vec`,
    /// the count was process-lifetime, and the durable row was deleted through
    /// a function documented as deleting only cloud-confirmed frontiers.
    ///
    /// Cloud is unreachable in `test_engine` (auth points at 127.0.0.1:1), so
    /// the cycle errors at publish. That is deliberate and does not weaken the
    /// assertion: the drop runs *before* any upload, because an unsealable row
    /// can never be uploaded on any cycle.
    #[tokio::test]
    async fn quarantined_record_is_tombstoned_before_its_durable_row_is_deleted() {
        use crate::sync::engine::types::MutationIntentMaterializer;
        use crate::sync::log::{LogOp, MutationEnvelope};
        use std::collections::HashMap;
        use std::sync::Arc;

        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        let materializer: MutationIntentMaterializer = Arc::new(|envelopes| {
            Box::pin(async move {
                for envelope in &envelopes {
                    if envelope
                        .field_atom_uuids
                        .values()
                        .any(|id| id == "dead-atom")
                    {
                        return Err("missing atom dead-atom for field title".to_string());
                    }
                }
                Ok(envelopes)
            })
        });
        engine.set_mutation_intent_materializer(materializer).await;

        let envelope = |atom: &str, seq: u64| {
            let mut field_atom_uuids = HashMap::new();
            field_atom_uuids.insert("title".to_string(), atom.to_string());
            MutationEnvelope {
                schema_name: "Note".to_string(),
                mutation_type: "update".to_string(),
                key_value: crate::schema::types::key_value::KeyValue::new(
                    Some(format!("n{seq}")),
                    None,
                ),
                fields_and_values: HashMap::new(),
                pub_key: "pk".to_string(),
                written_at: seq,
                writer_id: "test-device".to_string(),
                logical_counter: 0,
                author_clock_signature: String::new(),
                author_clock_signature_version: 0,
                storage_prefix: None,
                provenance: None,
                imported_version: None,
                mutation_uuid: format!("m{seq}"),
                source_file_name: None,
                metadata: None,
                aggregate_set: None,
                field_atom_uuids,
            }
        };
        let record = |seq: u64, atom: &str| PinLogRecord {
            model_version: PIN_LOG_MODEL_VERSION,
            target_id: "personal".to_string(),
            target_label: "personal".to_string(),
            target_prefix: String::new(),
            writer_id: "test-device".to_string(),
            frontier_after: seq,
            timestamp_ms: seq,
            entry: LogEntry {
                seq,
                timestamp_ms: seq,
                device_id: "test-device".to_string(),
                op: LogOp::MutationIntent {
                    mutations: vec![envelope(atom, seq)],
                },
            },
        };
        engine
            .pin_log
            .persist_pin_log_records(&[record(1, "dead-atom"), record(2, "live-atom")])
            .await
            .expect("persist mixed pin-log intents");

        assert!(
            engine
                .upload_quarantine_tombstone("", 1)
                .await
                .expect("read tombstone")
                .is_none(),
            "no tombstone before the cycle runs"
        );

        let mut plane = MutationLogLocalCloud::new();
        let _ = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::Cloud,
            )
            .await;

        assert_eq!(
            engine
                .upload_quarantine_tombstone("", 1)
                .await
                .expect("read tombstone")
                .as_deref(),
            Some("missing atom dead-atom for field title"),
            "the tombstone must carry the missing atom id and field — after the \
             durable row is gone it is the only description of the hole"
        );
        assert!(
            engine
                .upload_quarantine_tombstone("", 2)
                .await
                .expect("read tombstone")
                .is_none(),
            "a sealable record must not be tombstoned"
        );

        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let remaining: Vec<u64> = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap()
            .into_iter()
            .map(|r| r.frontier_after)
            .collect();
        assert!(
            !remaining.contains(&1),
            "the quarantined row is dropped, got {remaining:?}"
        );
        assert!(
            remaining.contains(&2),
            "cloud never confirmed the sealable row, so it must stay pending, got {remaining:?}"
        );
    }

    /// Keyset pagination must cross the page boundary without dropping or
    /// repeating a row: an uncapped cycle over a plane larger than one page
    /// still publishes every record exactly once.
    #[tokio::test]
    async fn uncapped_cycle_pages_across_the_scan_page_boundary() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 8 * 1024 * 1024,
            ..SyncConfig::default()
        });
        let n = pin_log_scan_page_size() + 17;
        for i in 0..n {
            engine
                .record_put("main", format!("paged-k{i}").as_bytes(), &[1])
                .await
                .unwrap();
        }

        let mut plane = MutationLogLocalCloud::new();
        let report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                0,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();

        assert_eq!(
            report.segments_uploaded, 1,
            "the records spanning the page boundary fit in one object"
        );
        assert_eq!(report.rows_scanned, n);
        assert!(!report.records_considered_is_lower_bound);
        assert_eq!(plane.segment_count(), 1);
    }

    /// A long run of already-published rows at the front cannot make one cycle
    /// walk the whole plane — and the stop is reported, not inferred.
    #[tokio::test]
    async fn row_budget_stops_a_cycle_that_is_only_skipping_published_rows() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..40 {
            engine
                .record_put("main", format!("skip-k{i}").as_bytes(), &[1])
                .await
                .unwrap();
        }
        let target = SyncTarget {
            label: "personal".to_string(),
            prefix: String::new(),
            crypto: Arc::new(LocalCryptoProvider::from_key([0x77u8; 32])),
        };

        // Nothing is pending: the scan can only skip.
        let never_pending = |_: &PinLogRecord| false;
        let page = engine
            .pin_log
            .read_pending_pin_log_records_paged(&target, &never_pending, 8, 0, 10)
            .await
            .unwrap();

        assert!(page.records.is_empty());
        assert_eq!(page.not_pending_frontiers.len(), 10);
        assert_eq!(page.rows_scanned, 10, "the budget bounds the cycle's walk");
        assert!(page.row_budget_exhausted);
        assert!(
            !page.scan_complete,
            "a budget stop is not the end of the plane and must not read as one"
        );
    }

    /// A cloud-confirmed record whose first best-effort delete failed must be
    /// retried on the next cycle. The retry happens before a newer pending
    /// upload, so a current network failure cannot strand old confirmed rows.
    #[tokio::test]
    async fn cloud_cycle_retries_truncation_for_already_published_records() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..3u8 {
            engine
                .record_put("main", format!("retry-truncate-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let before = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert_eq!(before.len(), 3);

        // Model two records whose cloud upload succeeded but local delete did
        // not. The third record remains pending and its upload will fail on the
        // test engine's unreachable cloud endpoint.
        let mut plane = MutationLogLocalCloud::new();
        engine
            .pin_log
            .persist_published_f(
                &target_id_for_prefix(&target.prefix),
                &BTreeMap::from([(before[1].writer_id.clone(), before[1].frontier_after)]),
            )
            .await
            .unwrap();
        let result = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::Cloud,
            )
            .await;
        assert!(result.is_err(), "the newer pending upload must reach cloud");

        let after = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert_eq!(after.len(), 1, "confirmed rows must be retried and deleted");
        assert_eq!(after[0].frontier_after, before[2].frontier_after);
    }

    /// A restart must not forget which records cloud already confirmed.
    ///
    /// This is the defect that made `sync_pin_log` 21 GiB on the primary: the
    /// published high-water mark lived only in `PinLogRuntime` and the process
    /// `MutationLogLocalCloud`, both constructed empty, so after every boot the
    /// already-uploaded front of the log read as pending and its delete never
    /// fired again. Truncate-after-confirm had shipped; it just could not see
    /// what a previous process confirmed.
    ///
    /// Modelled here as the state a fresh process actually starts in: the
    /// durable map is present, and *nothing else is* — empty runtime map, empty
    /// plane.
    #[tokio::test]
    async fn durable_published_f_survives_restart_and_still_truncates() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..3u8 {
            engine
                .record_put("main", format!("restart-truncate-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let target_id = target_id_for_prefix(&target.prefix);
        let before = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert_eq!(before.len(), 3);

        // A previous process uploaded records 0 and 1 and recorded that fact
        // durably. This process knows nothing else about them.
        let mut durable = BTreeMap::new();
        durable.insert(before[1].writer_id.clone(), before[1].frontier_after);
        engine
            .pin_log
            .persist_published_f(&target_id, &durable)
            .await
            .unwrap();
        {
            let mut state = engine.pin_log.state.lock().await;
            if let Some(runtime) = state.get_mut(&target_id) {
                runtime.published_f_by_writer.clear();
                runtime.published_frontier = 0;
            }
        }

        // Fresh plane: this process has confirmed nothing itself.
        let mut plane = MutationLogLocalCloud::new();
        let result = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::Cloud,
            )
            .await;
        assert!(result.is_err(), "the newer pending upload must reach cloud");

        let after = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert_eq!(
            after.len(),
            1,
            "records confirmed by a previous process must still be deletable"
        );
        assert_eq!(after[0].frontier_after, before[2].frontier_after);
    }

    /// Operator audit must use the durable published-F predicate only:
    /// rows at/below the writer's HWM are confirmed; rows above are pending.
    #[tokio::test]
    async fn operator_audit_respects_durable_published_f_and_resumes() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..4u8 {
            engine
                .record_put("main", format!("op-audit-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }
        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let target_id = target_id_for_prefix(&target.prefix);
        let before = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert_eq!(before.len(), 4);
        let writer = before[0].writer_id.clone();
        // Confirm first two records durably; leave 2 and 3 pending.
        let mut durable = BTreeMap::new();
        durable.insert(writer.clone(), before[1].frontier_after);
        engine
            .pin_log
            .persist_published_f(&target_id, &durable)
            .await
            .unwrap();

        let store = engine.pin_log.pin_log_store().await.unwrap();
        let audit = audit_pin_log_plane(store.as_ref(), 50_000, None)
            .await
            .expect("audit");
        assert_eq!(audit.entry_rows, 4);
        assert_eq!(audit.confirmed_rows, 2);
        assert_eq!(audit.pending_rows, 2);

        let first = audit_pin_log_plane(store.as_ref(), 2, None)
            .await
            .expect("first bounded page");
        assert_eq!(first.entry_rows, 2);
        assert!(first.more_remaining);
        let second = audit_pin_log_plane(store.as_ref(), 50_000, first.next_after_key.as_deref())
            .await
            .expect("resumed page");
        assert_eq!(second.entry_rows, 2);
        assert_eq!(first.confirmed_rows + second.confirmed_rows, 2);
        assert_eq!(first.pending_rows + second.pending_rows, 2);

        // A corrupt map makes every row pending and never mutates the plane.
        store
            .put(&pin_log_published_f_key(&target_id), b"not-json".to_vec())
            .await
            .unwrap();
        let safe = audit_pin_log_plane(store.as_ref(), 50_000, None)
            .await
            .expect("audit on corrupt map");
        assert_eq!(safe.confirmed_rows, 0);
        assert_eq!(safe.pending_rows, 4);
        let still = engine
            .pin_log
            .read_pin_log_records_for_target(&target)
            .await
            .unwrap();
        assert_eq!(still.len(), 4, "the read-only audit must never delete");
    }

    /// The operator path must classify each writer against only that writer's
    /// durable high-water mark. It intentionally starts with no runtime or
    /// process-plane frontier, modelling a fresh process after restart.
    #[tokio::test]
    async fn operator_audit_is_restart_safe_for_multiple_writers() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let target_id = target_id_for_prefix(&target.prefix);
        let store = engine.pin_log.pin_log_store().await.unwrap();

        for (writer_id, frontier_after) in [
            ("writer-a", 9u64),
            ("writer-a", 11),
            ("writer-b", 99),
            ("writer-b", 101),
        ] {
            let mut record = secret_bearing_record(writer_id.as_bytes());
            record.target_id = target_id.clone();
            record.target_label = target.label.clone();
            record.target_prefix = target.prefix.clone();
            record.writer_id = writer_id.to_string();
            record.frontier_after = frontier_after;
            record.entry.seq = frontier_after;
            store
                .put(
                    &pin_log_entry_key(&target_id, frontier_after),
                    serde_json::to_vec(&record).unwrap(),
                )
                .await
                .unwrap();
        }
        let durable = BTreeMap::from([
            ("writer-a".to_string(), 10u64),
            ("writer-b".to_string(), 100u64),
        ]);
        engine
            .pin_log
            .persist_published_f(&target_id, &durable)
            .await
            .unwrap();

        let audit = audit_pin_log_plane(store.as_ref(), 50_000, None)
            .await
            .unwrap();
        assert_eq!(audit.confirmed_rows, 2);
        assert_eq!(audit.pending_rows, 2);
        assert_eq!(audit.writers.len(), 2);
        assert_eq!(audit.writers[0].writer_id, "writer-a");
        assert_eq!(audit.writers[0].durable_published_f, 10);
        assert_eq!(audit.writers[0].confirmed_rows, 1);
        assert_eq!(audit.writers[0].pending_rows, 1);
        assert_eq!(audit.writers[1].writer_id, "writer-b");
        assert_eq!(audit.writers[1].durable_published_f, 100);
        assert_eq!(audit.writers[1].confirmed_rows, 1);
        assert_eq!(audit.writers[1].pending_rows, 1);
    }

    /// `LocalPlaneForTests` frontiers are not cloud confirmation. Persisting
    /// them would outlive the process and authorize a later real cycle to
    /// delete records that no peer holds — the one unrecoverable outcome on
    /// this path.
    #[tokio::test]
    async fn local_test_plane_never_persists_published_f() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            max_upload_bytes_per_cycle: 1024 * 1024,
            ..SyncConfig::default()
        });
        for i in 0..3u8 {
            engine
                .record_put("main", format!("local-plane-k{i}").as_bytes(), &[i])
                .await
                .unwrap();
        }

        let target = engine.pin_log.sync_target_by_prefix("").await.unwrap();
        let target_id = target_id_for_prefix(&target.prefix);
        let mut plane = MutationLogLocalCloud::new();
        let report = engine
            .pin_log
            .run_mutation_log_segment_upload_cycle(
                &engine,
                "",
                &mut plane,
                16,
                MutationLogPublish::LocalPlaneForTests,
            )
            .await
            .unwrap();
        assert!(
            report.segments_uploaded > 0,
            "the test plane must have accepted segments for this to prove anything"
        );

        assert!(
            engine.pin_log.read_published_f(&target_id).await.is_empty(),
            "a test-plane cycle must leave no durable confirmation behind"
        );
    }

    /// A corrupt or absent durable map reads as "nothing is confirmed", never
    /// as an error and never as a frontier that could authorize a delete.
    #[tokio::test]
    async fn undecodable_durable_published_f_reads_as_nothing_confirmed() {
        let engine = test_engine(SyncConfig {
            legacy_personal_cloud_sync: false,
            capture_mode: CaptureMode::MutationLog,
            ..SyncConfig::default()
        });
        let target_id = "personal";
        assert!(
            engine.pin_log.read_published_f(target_id).await.is_empty(),
            "absent must read as nothing confirmed"
        );

        let mut durable = BTreeMap::new();
        durable.insert("writer-a".to_string(), 42u64);
        engine
            .pin_log
            .persist_published_f(target_id, &durable)
            .await
            .unwrap();
        assert_eq!(
            engine
                .pin_log
                .read_published_f(target_id)
                .await
                .get("writer-a"),
            Some(&42),
            "a persisted map must round-trip"
        );

        engine
            .pin_log
            .pin_log_store()
            .await
            .unwrap()
            .put(&pin_log_published_f_key(target_id), b"not json".to_vec())
            .await
            .unwrap();
        assert!(
            engine.pin_log.read_published_f(target_id).await.is_empty(),
            "undecodable must read as nothing confirmed, not propagate an error"
        );
    }
}
