#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-status-gauge-contract
# Terminal proof for the typed `lastdb status` gauge contract.
#
# Offline mode checks product source presence. Live mode checks `/api/status`
# on a caller-provided isolated CoW node. The primary LastDB socket is rejected before any request is sent.
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
  # The X run must be LAST. BSD mktemp does not substitute
  # "status-gauge-contract.XXXXXX.json"; it creates that literal name in a SHARED
  # TMPDIR, and the next call collides -- under `set -e` that aborts the whole
  # terminal proof with mktemp's stderr as the only clue.
  payload="$(mktemp "${TMPDIR:-/tmp}/status-gauge-contract.XXXXXX")"
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
if [ "$MODE" = live ] && [ "$ok" -eq 0 ]; then
  run_live_contract_probe
fi

body=""
for note in "${notes[@]}"; do
  body="${body}- ${note}"$'\n'
done
body="${body}"$'\n'"Mode: $MODE. Offline proof checks source presence only. Live mode requires an isolated CoW-node socket and refuses the primary LastDB home."

if [ "$ok" -eq 0 ]; then
  if [ "$MODE" = live ]; then
    ns_write_report "$SLUG" PASS "$body"
  else
    ns_write_report "$SLUG" PASS-OFFLINE "$body"
  fi
else
  ns_write_report "$SLUG" FAIL "$body"
fi
