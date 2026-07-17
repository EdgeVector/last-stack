#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-schema-shared-surface-native-resolver
WS="$(ns_edgevector_workspace)"
REPO="$WS/fold"
MODE="$(ns_mode)"

capstone_dir="$REPO/schema_service/scripts/capstone-shared-surface-native-resolver"
notes=""

if [ -x "$capstone_dir/run.sh" ]; then
  notes="found in-repo capstone harness: $capstone_dir/run.sh"
  if [ "$MODE" = live ]; then
    set +e
    out="$(cd "$capstone_dir" && LASTDB_HOME="$(mktemp -d)" bash ./run.sh 2>&1)"
    rc=$?
    set -e
    notes="$(printf '%s\nrun.sh rc=%s\n```\n%s\n```\n' "$notes" "$rc" "$out")"
    if [ "$rc" -ne 0 ]; then
      ns_write_report "$SLUG" FAIL "$notes" || exit 1
      exit 1
    fi
    ns_write_report "$SLUG" PASS "$notes"
    exit 0
  fi
else
  notes="in-repo capstone run.sh not landed yet (card schema-shared-surface-native-resolver-capstone still building it)"
fi

# Offline product gate: Mini adopt path must not pull wasmtime (when cargo tree available)
if command -v cargo >/dev/null 2>&1 && [ -f "$REPO/Cargo.toml" ]; then
  set +e
  tree_out="$(cd "$REPO" && cargo tree -p lastdb_node 2>/dev/null | rg -i 'wasmtime|cranelift' || true)"
  set -e
  if [ -n "$tree_out" ]; then
    ns_write_report "$SLUG" FAIL "wasmtime/cranelift appears in lastdb_node tree:\n$tree_out" || exit 1
    exit 1
  fi
  notes="$(printf '%s\ncargo tree lastdb_node: no wasmtime/cranelift (offline WASM ban)\n' "$notes")"
else
  notes="$(printf '%s\ncargo tree skipped (cargo/lastdb_node unavailable)\n' "$notes")"
fi

# Private-local invariant docs / scripts presence
if [ -f "$REPO/schema_service/scripts/verify_app_schema_preregister.sh" ]; then
  notes="$(printf '%s\nverify_app_schema_preregister.sh present\n' "$notes")"
fi

verdict=PASS-OFFLINE
[ -x "$capstone_dir/run.sh" ] && [ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$(printf 'Schema shared-surface offline gates.\n\n%s\nWhen capstone run.sh lands, live mode executes it on throwaway LASTDB_HOME.\n' "$notes")"
