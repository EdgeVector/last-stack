#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-proof"
chmod +x "$BIN" "$ROOT/harness/north-star"/*/run.sh

"$BIN" --list | grep -q north-star-coderings
"$BIN" --list | grep -q north-star-schema-shared-surface-native-resolver
"$BIN" --list | grep -q north-star-lastdb-file-blobs-on-demand-sync
"$BIN" --list | grep -q north-star-laststore-is-document-store-last-db-is-conventions
"$BIN" --list | grep -q north-star-mini-brain-observability
"$BIN" --list | grep -q north-star-lastdb-search-as-app

PROOF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ns-proof-test.XXXXXX")"
FILE_BLOB_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-file-blob-proof-test.XXXXXX")"
MINI_OBS_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-mini-obs-proof-test.XXXXXX")"
trap 'rm -rf "$PROOF_DIR" "$FILE_BLOB_WORK" "$MINI_OBS_WORK"' EXIT
export NORTH_STAR_PROOF_DIR="$PROOF_DIR"
export NORTH_STAR_PROOF_MODE=offline
export EDGEVECTOR_WORKSPACE="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}"

# Always-safe offline proofs when checkouts exist
if [ -d "$EDGEVECTOR_WORKSPACE/coderings" ]; then
  "$BIN" --offline north-star-coderings
  head -1 "$PROOF_DIR/north-star-coderings.md" | grep -qE '^PASS'
fi

if command -v lastdb >/dev/null 2>&1; then
  "$BIN" --offline north-star-app-ops-latency
  head -1 "$PROOF_DIR/north-star-app-ops-latency.md" | grep -qE '^PASS'
fi

# Structural: all harness scripts exist and bash -n clean
for s in coderings deliver-slices lastgit metering minimal-node app-ops schema file-blobs-on-demand-sync laststore mini-brain-observability search-as-app; do
  bash -n "$ROOT/harness/north-star/$s/run.sh"
done
bash -n "$BIN"
bash -n "$ROOT/harness/north-star/common.sh"

fold="$FILE_BLOB_WORK/edgevector/fold"
mkdir -p \
  "$fold/docs/designs" \
  "$fold/fold_db/crates/core/src/sync/engine" \
  "$fold/fold_db/crates/core/src/sharing" \
  "$fold/fold_db/crates/core/tests"
touch "$fold/Cargo.toml"

cat >"$fold/docs/designs/cloud-file-blobs-on-demand-sync.md" <<'EOF'
ordinary sync never bulk-downloads file blobs. metadata-only structured metadata
supports no local CAS bytes. explicit on-demand path. cache hit does not re-fetch.
EOF
cat >"$fold/fold_db/crates/core/src/sync/engine/file_blob.rs" <<'EOF'
//! must not list or bulk download during ordinary sync/bootstrap/device-join
EOF
cat >"$fold/fold_db/crates/core/src/sharing/query_slice.rs" <<'EOF'
fn resolve_file_bytes_on_demand() {
  blob_cas::get_blob_bytes();
  download_file_blob();
  blob_cas::put_blob();
}
EOF
cat >"$fold/fold_db/crates/core/src/sync/engine/tests.rs" <<'EOF'
fn file_blob_upload_and_delete_confirm_after_successful_object_ops() {}
fn file_blob_explicit_download_opens_with_returned_dek() {}
fn file_blob_on_demand_fetch_caches_local_hit_and_rejects_wrong_dek() {}
EOF
for i in $(seq 1 2000); do
  printf '// trailing fixture line %s keeps grep -q from being a safe pipefail shortcut\n' "$i"
done >>"$fold/fold_db/crates/core/src/sync/engine/tests.rs"
cat >"$fold/fold_db/crates/core/tests/file_blob_structured_reads_test.rs" <<'EOF'
fn structured_reads_without_bytes_missing_blob_local_CAS() {}
EOF
cat >"$fold/fold_db/crates/core/tests/file_blob_device_join_test.rs" <<'EOF'
fn device_join_metadata_only() {
  "presign_file_download";
  "GET /file/download";
  "local cache hit";
  "metadata";
}
EOF

EDGEVECTOR_WORKSPACE="$FILE_BLOB_WORK/edgevector" \
NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
FOLD_FILE_BLOB_PROOF_RUN_CARGO=0 \
  "$BIN" --offline north-star-lastdb-file-blobs-on-demand-sync >"$FILE_BLOB_WORK/proof.out"

report="$PROOF_DIR/north-star-lastdb-file-blobs-on-demand-sync.md"
test -f "$report"
test "$(sed -n '1p' "$report")" = "PASS-OFFLINE"
grep -q "metadata-only" "$report"
grep -q "on-demand" "$report"
grep -q "cache" "$report"
grep -q "no bulk" "$report"
grep -q "cargo test -p fold_db" "$report"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$FILE_BLOB_WORK/proof.out"

laststore_record="$PROOF_DIR/laststore-record.md"
cat >"$laststore_record" <<'EOF'
# North Star - Last Store vs LastDB abstraction

Last Store is a multi-collection document store (put/get/delete by collection + id, optional prefix walk, flush, compact).
LastDB is a convention of collections, ids, and documents on top of it.

Last Store: collections, ids, bodies, prefix list, group-commit, compact.
LastDB product: tip id layout, atoms, schemas, list keys, hash-range page indexes, B-tree-as-docs, upper-layer walk logic.

Mini gaps are Mini packaging, a Mini -> Last Store path, and Mini cutover migration work; they are not product incompleteness.
Design: storage-v2.md and reference-laststore-collection-naming.
Do not invent a catch-all collection main for new Storage v2 work.
EOF

LASTSTORE_PROOF_RECORD_FILE="$laststore_record" \
NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
  "$BIN" --offline north-star-laststore-is-document-store-last-db-is-conventions >"$PROOF_DIR/laststore.out"

laststore_report="$PROOF_DIR/north-star-laststore-is-document-store-last-db-is-conventions.md"
test "$(sed -n '1p' "$laststore_report")" = "PASS-OFFLINE"
grep -q "multi-collection document engine" "$laststore_report"
grep -q "Mini packaging" "$laststore_report"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$PROOF_DIR/laststore.out"

bad_laststore_record="$PROOF_DIR/bad-laststore-record.md"
cat >"$bad_laststore_record" <<'EOF'
Last Store is a convention of collections. LastDB is a document store.
EOF
if LASTSTORE_PROOF_RECORD_FILE="$bad_laststore_record" \
  NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
  "$BIN" --offline north-star-laststore-is-document-store-last-db-is-conventions >"$PROOF_DIR/laststore-bad.out" 2>&1; then
  echo "bad LastStore abstraction fixture unexpectedly passed" >&2
  exit 1
fi

mini_fold="$MINI_OBS_WORK/edgevector/fold"
mkdir -p \
  "$mini_fold/lastdb_node/src/bin" \
  "$mini_fold/lastdb_node/src/ops" \
  "$mini_fold/scripts/lastdbd" \
  "$MINI_OBS_WORK/last-stack/routines"
cat >"$mini_fold/lastdb_node/src/bin/lastdb.rs" <<'EOF'
fn status(data_dir: Option<PathBuf>) {
  crash_attribution::daemon_status_line();
  crash_attribution::status_lines();
  self_metrics::status_lines();
  request_ops_lines();
  probe_status();
}
fn alert_check(data_dir: Option<PathBuf>) {}
fn probe_status() {
  "GET /api/status";
  "X-LastDB-Client: lastdb";
}
EOF
cat >"$mini_fold/lastdb_node/src/ops/crash_attribution.rs" <<'EOF'
fn install_crash_hook() {}
fn promote_previous_crash_evidence() {
  previous_log_tail();
  "unclean exit";
  "Sentry";
}
fn previous_log_tail() {}
fn status_lines() {}
EOF
cat >"$mini_fold/lastdb_node/src/ops/session_ledger.rs" <<'EOF'
struct SessionRecord { prev_session_clean: bool }
fn live_session() {}
EOF
cat >"$mini_fold/lastdb_node/src/main.rs" <<'EOF'
fn main() {
  install_crash_hook();
  promote_previous_crash_evidence();
}
EOF
cat >"$mini_fold/lastdb_node/src/ops/self_metrics.rs" <<'EOF'
const DEFAULT_SELF_METRICS_LOG_REL: &str = "logs/self-metrics.jsonl";
const SELF_METRIC_SCHEMA: &str = "lastdb_telemetry/SelfMetricSample";
struct StatusSnapshot {
  rss_bytes: u64,
  cpu_percent: f64,
  sync_last_success_ts: u64,
  sync_pending_count: u64,
  request_ops: u64,
}
fn write() { "LASTDB_SELF_METRICS_TO_DB"; }
EOF
cat >"$mini_fold/scripts/lastdbd/telemetry-dashboard-regen.sh" <<'EOF'
#!/usr/bin/env bash
"$lastdb_bin" --data-dir "$LASTDB_HOME" telemetry-dashboard
echo "DASHBOARD_HTML=/tmp/dashboard.html"
EOF
cat >"$mini_fold/scripts/lastdbd/mini-health-alert-check.sh" <<'EOF'
#!/usr/bin/env bash
LASTDB_HEALTH_ALERT_FAILURES_BEFORE_ALERT=2
heartbeat_helper=heartbeat
lastdb alert-check
EOF
cat >"$MINI_OBS_WORK/last-stack/routines/dogfood-rotate.md" <<'EOF'
Use dogfood-registry to dogfood exactly one eligible feature from the Brain-owned registry.
EOF

MINI_BRAIN_OBSERVABILITY_PROOF_FOLD_DIR="$mini_fold" \
MINI_BRAIN_OBSERVABILITY_PROOF_LAST_STACK_DIR="$MINI_OBS_WORK/last-stack" \
NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
  "$BIN" --offline north-star-mini-brain-observability >"$PROOF_DIR/mini-obs.out"

mini_obs_report="$PROOF_DIR/north-star-mini-brain-observability.md"
test "$(sed -n '1p' "$mini_obs_report")" = "PASS-OFFLINE"
grep -q "lastdb status" "$mini_obs_report"
grep -q "Crash/session attribution" "$mini_obs_report"
grep -q "Self-metrics history" "$mini_obs_report"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$PROOF_DIR/mini-obs.out"

SEARCH_AS_APP_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ns-search-as-app-proof-test.XXXXXX")"
trap 'rm -rf "$PROOF_DIR" "$FILE_BLOB_WORK" "$MINI_OBS_WORK" "$SEARCH_AS_APP_WORK"' EXIT

search_app="$SEARCH_AS_APP_WORK/search"
saa_fold="$SEARCH_AS_APP_WORK/fold"
saa_brain="$SEARCH_AS_APP_WORK/brain"
saa_kanban="$SEARCH_AS_APP_WORK/fkanban"
mkdir -p \
  "$search_app/.last-stack" "$search_app/.lastgit" \
  "$saa_fold/lastdb_uds/src" "$saa_fold/lastdb_node/src" "$saa_fold/fold_db/crates/core" \
  "$saa_brain/src/commands" \
  "$saa_kanban/src/commands"

cat >"$search_app/README.md" <<'EOF'
Search is a first-party app hosted from lastdb:///search.
Index data is local-only and regenerable from atoms, tips, and app text projections.
Index data is not CloudSync product data.
The LastDB kernel should not ship FastEmbed, ONNX, or model weights by default.
EOF
printf 'lastgit\n' >"$search_app/.last-stack/pr-venue"
printf '#!/usr/bin/env bash\necho ok\n' >"$search_app/.lastgit/ci.sh"

cat >"$saa_fold/lastdb_uds/src/uds_router.rs" <<'EOF'
enum DataRoute { SearchAppQuery }
impl DataRoute {
  fn path(&self) -> (&str, &str) {
    match self { Self::SearchAppQuery => ("GET", "/api/search/query") }
  }
}
EOF
cat >"$saa_fold/lastdb_node/src/exec.rs" <<'EOF'
match route {
  DataRoute::SearchAppQuery => execute_search_app_query_route(req, ctx, host).await,
}
EOF
cat >"$saa_fold/fold_db/crates/core/Cargo.toml" <<'EOF'
[package]
name = "fold_db"

[features]
default = []
semantic-search = ["dep:fastembed"]

[dependencies]
fastembed = { version = "4", optional = true }
EOF
cat >"$saa_fold/lastdb_node/Cargo.toml" <<'EOF'
[package]
name = "lastdb_node"

[features]
default = ["cloud-sync", "sentry-telemetry"]
semantic-search = ["fold_db/semantic-search"]
EOF

cat >"$saa_brain/src/client.ts" <<'EOF'
const result = await sdkDataPath("/api/app/search", (client) => client.search(query));
EOF
cat >"$saa_brain/src/commands/ask.ts" <<'EOF'
const node = newSearchClientFromCfg(opts.cfg, opts.verbose).node;
// note: search index cache was cold/stale — rebuilding from N record(s)
EOF

cat >"$saa_kanban/src/client.ts" <<'EOF'
const result = await sdkDataPath("/api/app/search", (client) => client.search(query));
EOF
cat >"$saa_kanban/src/commands/search.ts" <<'EOF'
async function nativeIndexCandidateSlugs() {}
EOF

SEARCH_AS_APP_PROOF_SEARCH_DIR="$search_app" \
SEARCH_AS_APP_PROOF_FOLD_DIR="$saa_fold" \
SEARCH_AS_APP_PROOF_BRAIN_DIR="$saa_brain" \
SEARCH_AS_APP_PROOF_KANBAN_DIR="$saa_kanban" \
NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
  "$BIN" --offline north-star-lastdb-search-as-app >"$PROOF_DIR/search-as-app.out"

search_as_app_report="$PROOF_DIR/north-star-lastdb-search-as-app.md"
test "$(sed -n '1p' "$search_as_app_report")" = "PASS-OFFLINE"
grep -q "SearchAppQuery" "$search_as_app_report"
grep -qi "fastembed/onnx" "$search_as_app_report"
grep -q "PROOF_VERDICT=PASS-OFFLINE" "$PROOF_DIR/search-as-app.out"

# Regression guard: fastembed sneaking into the default binary must FAIL.
cat >"$saa_fold/lastdb_node/Cargo.toml" <<'EOF'
[package]
name = "lastdb_node"

[features]
default = ["cloud-sync", "sentry-telemetry", "semantic-search"]
semantic-search = ["fold_db/semantic-search"]
EOF
if SEARCH_AS_APP_PROOF_SEARCH_DIR="$search_app" \
  SEARCH_AS_APP_PROOF_FOLD_DIR="$saa_fold" \
  SEARCH_AS_APP_PROOF_BRAIN_DIR="$saa_brain" \
  SEARCH_AS_APP_PROOF_KANBAN_DIR="$saa_kanban" \
  NORTH_STAR_PROOF_DIR="$PROOF_DIR" \
  "$BIN" --offline north-star-lastdb-search-as-app >"$PROOF_DIR/search-as-app-bad.out" 2>&1; then
  echo "fastembed-in-default-binary fixture unexpectedly passed" >&2
  exit 1
fi

echo "PASS last-stack-north-star-proof"
