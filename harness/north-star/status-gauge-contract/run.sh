#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-status-gauge-contract
# Terminal proof for the typed `lastdb status` gauge contract.
#
# Offline mode runs the merged Fold contract/regression suite. Live mode runs
# the same suite and also checks `/api/status` on a caller-provided isolated
# CoW node. The primary LastDB socket is rejected before any request is sent.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-status-gauge-contract
MODE="$(ns_mode)"
FOLD="$(ns_repo_path fold)"

notes=()
ok=0

append() {
  notes+=("$1")
}

fail_gate() {
  append "$1: FAIL"
  ok=1
}

require_fold_source() {
  local path="$FOLD/lastdb_node/src/ops/status_gauge_contract.rs"
  if [ ! -f "$path" ]; then
    fail_gate "Fold merged-main source is not resolvable at $FOLD"
    return 1
  fi

  local source_ref="archive-of-portal-main"
  if git -C "$FOLD" rev-parse --verify HEAD >/dev/null 2>&1; then
    source_ref="$(git -C "$FOLD" rev-parse HEAD)"
  else
    local portal cache
    portal="$(ns_edgevector_workspace)/fold"
    if [ -f "$portal/.portal/cache" ]; then
      cache="$(tr -d '[:space:]' <"$portal/.portal/cache")"
      source_ref="$(git --git-dir="$cache" rev-parse main 2>/dev/null || printf '%s' "$source_ref")"
    fi
  fi
  append "Fold merged-main source: $FOLD@$source_ref"
  return 0
}

run_contract_test() {
  local criterion="$1" filter="$2"
  # Proofs share a host with concurrent Fold workers. Keep this foreground
  # build small and bypass a fleet sccache wrapper by default: under pressure
  # sccache can exhaust its file-descriptor budget before rustc sees a crate.
  # Callers may opt back into a known-good wrapper explicitly.
  if (
    cd "$FOLD" &&
      env \
        CARGO_BUILD_JOBS="${STATUS_GAUGE_PROOF_BUILD_JOBS:-2}" \
        RUSTC_WRAPPER="${STATUS_GAUGE_PROOF_RUSTC_WRAPPER:-}" \
        cargo test --locked -p lastdb_node --lib "$filter" -- --nocapture
  ); then
    append "$criterion: PASS (cargo filter: $filter)"
  else
    fail_gate "$criterion (cargo filter: $filter)"
  fi
}

run_live_contract_probe() {
  local sock="${NORTH_STAR_PROOF_SOCKET:-}"
  if [ -z "$sock" ]; then
    fail_gate "live endpoint contract (NORTH_STAR_PROOF_SOCKET must name an isolated CoW node)"
    return
  fi
  if ! ns_refuse_primary "$sock"; then
    fail_gate "live endpoint contract (primary socket refused: $sock)"
    return
  fi
  if ! ns_require_cmd curl || ! ns_require_cmd jq; then
    fail_gate "live endpoint contract (curl and jq required)"
    return
  fi

  local payload
  payload="$(mktemp "${TMPDIR:-/tmp}/status-gauge-contract.XXXXXX.json")"
  if ! curl -fsS --unix-socket "$sock" -H 'Host: localhost' http://x/api/status >"$payload"; then
    rm -f "$payload"
    fail_gate "live endpoint contract (GET /api/status failed on isolated socket)"
    return
  fi
  if jq -e '
      (.status.contract.gauges | type == "array" and length > 0) and
      ([.status.contract.gauges[] |
        (.path | type == "string" and length > 0) and
        (.unit | type == "string" and length > 0) and
        (.window | type == "string" and length > 0) and
        (.availability | type == "string" and length > 0)] | all)
    ' "$payload" >/dev/null; then
    append "live endpoint contract: PASS (isolated socket: $sock)"
  else
    fail_gate "live endpoint contract (unlabeled gauge in /api/status)"
  fi
  rm -f "$payload"
}

require_fold_source || true
if [ "$ok" -eq 0 ]; then
  # 1 + 5: every typed status gauge is admitted by the inventory gate, the
  # exported contract carries labels/counts, and the additive block preserves
  # all pre-contract wire names and JSON types.
  run_contract_test \
    "1/5 labeled contract inventory and wire freeze" \
    "status_gauge_contract"
  run_contract_test \
    "1 renderer inventory contains no bare operator gauge" \
    "live_self_metrics_passes_status_gauge_gate"

  # 2: a staged-behind daemon omitting a converted field is unavailable, not
  # a serde-default measured zero. The resident regression covers the exact
  # historical deferred-persist payload as well as the generic Gauge contract.
  run_contract_test \
    "2 absent field is unavailable, never zero" \
    "missing_field_deserializes_to_unavailable_not_measured_zero"
  run_contract_test \
    "2 staged-behind deferred counters render unavailable" \
    "a_daemon_without_the_deferred_counters_says_so_instead_of_printing_zero"

  # 3: one test proves the unit owns the rendered noun; the source-audit fault
  # injection proves a hard-coded noun is rejected.
  run_contract_test \
    "3 rendered noun follows the producer unit" \
    "unit_noun_follows_unit_edges_never_rows"
  run_contract_test \
    "3 hard-coded renderer noun fails the gate" \
    "gate_fails_when_status_line_hard_codes_unit_noun"

  # 4: the three named pre-contract regressions are executable cases: edges as
  # rows, a process-lifetime total as now, and absent deferred counters as zero.
  run_contract_test \
    "4 historical mislabels fail pre-contract and pass typed" \
    "regression_"
fi

if [ "$MODE" = live ] && [ "$ok" -eq 0 ]; then
  run_live_contract_probe
fi

body=""
for note in "${notes[@]}"; do
  body="${body}- ${note}"$'\n'
done
body="${body}"$'\n'"Mode: $MODE. Offline proof executes the five merged-Fold contract gates. Live mode additionally requires an isolated CoW-node socket and refuses the primary LastDB home."

if [ "$ok" -eq 0 ]; then
  if [ "$MODE" = live ]; then
    ns_write_report "$SLUG" PASS "$body"
  else
    ns_write_report "$SLUG" PASS-OFFLINE "$body"
  fi
else
  ns_write_report "$SLUG" FAIL "$body"
fi
