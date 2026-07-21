#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-search-as-app
MODE="$(ns_mode)"
WS="$(ns_edgevector_workspace)"

SEARCH_DIR="${SEARCH_AS_APP_PROOF_SEARCH_DIR:-$WS/search}"
FOLD_DIR="${SEARCH_AS_APP_PROOF_FOLD_DIR:-$WS/fold}"
BRAIN_DIR="${SEARCH_AS_APP_PROOF_BRAIN_DIR:-$WS/brain}"
KANBAN_DIR="${SEARCH_AS_APP_PROOF_KANBAN_DIR:-$WS/fkanban}"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

require_file() {
  local path="$1" label="$2"
  [ -f "$path" ] || fail "missing $label: $path"
}

require_text() {
  local path="$1" pattern="$2" label="$3"
  require_file "$path" "$label"
  if ! grep -Eiq "$pattern" "$path"; then
    fail "missing search-as-app contract: $label

Path: $path
Pattern: $pattern"
  fi
}

require_absent() {
  local path="$1" pattern="$2" label="$3"
  require_file "$path" "$label"
  if grep -Eiq "$pattern" "$path"; then
    fail "search-as-app contract regressed: $label

Path: $path
Pattern (must be ABSENT): $pattern"
  fi
}

# 1. Search app scaffold: kernel contract lives outside lastdbd.
search_readme="$SEARCH_DIR/README.md"
search_pr_venue="$SEARCH_DIR/.last-stack/pr-venue"
search_ci="$SEARCH_DIR/.lastgit/ci.sh"
require_text "$search_readme" 'lastdb:///search' 'Search app hosted at lastdb:///search'
require_text "$search_readme" 'local-only and regenerable' 'index data declared local-only and regenerable'
require_text "$search_readme" 'not CloudSync product data' 'index data declared not CloudSync product data'
require_text "$search_readme" 'should not ship FastEmbed' 'README states kernel should not ship FastEmbed/ONNX'
require_file "$search_ci" 'Search scaffold LastGit CI gate'
require_text "$search_pr_venue" '^lastgit' 'Search app is a LastGit-native repo'

# 2. Fold hosts a grant-scoped search route (kernel stays a thin mediator).
uds_router="$FOLD_DIR/lastdb_uds/src/uds_router.rs"
exec_rs="$FOLD_DIR/lastdb_node/src/exec.rs"
require_text "$uds_router" 'SearchAppQuery' 'kernel UDS router declares a SearchAppQuery route'
require_text "$uds_router" '/api/search/query' 'kernel exposes /api/search/query'
require_text "$exec_rs" 'execute_search_app_query_route' 'kernel dispatches search app query route'
require_text "$exec_rs" 'DataRoute::SearchAppQuery' 'search app query is a first-class DataRoute'

# 3. Brain depends on the Search app for semantic ask/search (not its own embedder).
brain_client="$BRAIN_DIR/src/client.ts"
brain_ask="$BRAIN_DIR/src/commands/ask.ts"
require_text "$brain_client" '/api/app/search' 'brain node client calls the app-scoped search endpoint'
require_text "$brain_ask" 'newSearchClientFromCfg' 'ask uses the capability-aware search client'
require_text "$brain_ask" 'search index cache was cold/stale' 'ask surfaces a clear degrade notice instead of silent empty success'

# 4. Kanban depends on the Search app for native/app search.
kanban_client="$KANBAN_DIR/src/client.ts"
kanban_search="$KANBAN_DIR/src/commands/search.ts"
require_text "$kanban_client" '/api/app/search' 'kanban node client calls the app-scoped search endpoint'
require_text "$kanban_search" 'nativeIndexCandidateSlugs' 'kanban search prefers native-index candidate slugs over full scans'

# 5. Kernel default binary is peeled: fastembed/ONNX stay opt-in, never default.
fold_db_core_cargo="$FOLD_DIR/fold_db/crates/core/Cargo.toml"
lastdb_node_cargo="$FOLD_DIR/lastdb_node/Cargo.toml"
require_text "$fold_db_core_cargo" 'fastembed = \{ version = "4", optional = true \}' 'fastembed is an optional dependency, not required'
require_text "$fold_db_core_cargo" 'semantic-search = \["dep:fastembed"\]' 'semantic-search feature gates fastembed'
core_default_line="$(grep -E '^default[[:space:]]*=' "$fold_db_core_cargo" | head -1 || true)"
[ -n "$core_default_line" ] || fail "fold_db core Cargo.toml has no default feature line: $fold_db_core_cargo"
case "$core_default_line" in
  *semantic-search*) fail "fold_db core default features still include semantic-search (fastembed would ship by default): $core_default_line" ;;
esac
node_default_line="$(grep -E '^default[[:space:]]*=' "$lastdb_node_cargo" | head -1 || true)"
[ -n "$node_default_line" ] || fail "lastdb_node Cargo.toml has no default feature line: $lastdb_node_cargo"
case "$node_default_line" in
  *semantic-search*) fail "lastdbd default features still include semantic-search (fastembed would ship in the default binary): $node_default_line" ;;
esac
require_text "$lastdb_node_cargo" 'semantic-search = \["fold_db/semantic-search"\]' 'semantic-search remains a named opt-in feature on the default binary crate'

notes="$(cat <<EOF
Search-as-app source contract verified across search/fold/brain/kanban.

Mode: $MODE
Search app: $SEARCH_DIR
Fold source: $FOLD_DIR
Brain source: $BRAIN_DIR
Kanban source: $KANBAN_DIR

Covered end-state surfaces:
- \`EdgeVector/search\` is scaffolded as a LastGit-native app declaring the
  Search product contract (hosted app, local-only/regenerable index, not
  CloudSync data, kernel should not ship FastEmbed/ONNX by default).
- \`lastdb_uds\`/\`lastdb_node\` expose a first-class, grant-scoped
  \`SearchAppQuery\` route (\`/api/search/query\`) instead of a private
  per-app index.
- Brain's \`ask\`/client path calls the app-scoped \`/api/app/search\`
  endpoint through a capability-aware client and degrades with an explicit
  cold/stale-index notice rather than a silent empty result.
- Kanban's \`search\` command calls the same app-scoped endpoint and prefers
  native-index candidates over a full card-body scan.
- \`fold_db\`'s core crate keeps \`fastembed\` optional behind a
  \`semantic-search\` feature that is absent from both \`fold_db\`'s and
  \`lastdb_node\`'s default feature sets, so the default \`lastdbd\` binary
  does not link FastEmbed/ONNX.

Cited merged work: search-app-scaffold, fold-index-sink-change-feed,
fold-search-app-host-integration, brain-migrate-to-search-app,
kanban-migrate-to-search-app, fold-peel-fastembed-default-binary.

Offline proof policy:
- This harness performs source/contract checks only.
- It does not open, restart, kill, or write to the primary \`~/.lastdb\` daemon.
- Live end-to-end proof (fresh Mini boot, real \`brain ask\` / \`kanban search\`
  hits, cloud-sync capture exclusion) belongs to
  \`search-as-app-ns-terminal-verification\`'s live mode / dogfood pass.
EOF
)"

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$notes"
