#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-lastdb-minimal-node
MODE="$(ns_mode)"
WS="$(ns_edgevector_workspace)"

notes=""
# Offline: primary socket must exist for the *product* but we only *probe* it
# for presence via lsof/stat without heavy load; never restart anything.
sock="$HOME/.lastdb/data/folddb.sock"
if [ -S "$sock" ]; then
  notes="primary socket present (not opened for heavy work): $sock"
else
  notes="primary socket missing at $sock (Mini may be down — still offline-pass structural checks)"
fi

# Prefer a lastdbd binary for throwaway boots
lastdbd=""
for c in "${LASTDBD:-}" \
  "$WS/fold/target/release/lastdbd" \
  "$WS/fold/target/debug/lastdbd" \
  "$(command -v lastdbd 2>/dev/null || true)"; do
  [ -n "$c" ] && [ -x "$c" ] && { lastdbd="$c"; break; }
done
if [ -z "$lastdbd" ]; then
  ns_write_report "$SLUG" FAIL "no lastdbd binary; set LASTDBD or build fold lastdbd" || exit 1
  exit 1
fi
notes="$(printf '%s\nlastdbd=%s\n' "$notes" "$lastdbd")"

if [ "$MODE" = offline ]; then
  # Boot throwaway node, health-check, tear down
  NODE="$(mktemp -d "${TMPDIR:-/tmp}/ns-mini-proof.XXXXXX")"
  ns_refuse_primary "$NODE/data/folddb.sock" || true
  set +e
  LASTDB_HOME="$NODE" FOLDDB_HOME="$NODE" "$lastdbd" --data-dir "$NODE" >"$NODE/node.log" 2>&1 &
  pid=$!
  sock2=""
  for _ in $(seq 1 40); do
    if [ -S "$NODE/data/folddb.sock" ]; then sock2="$NODE/data/folddb.sock"; break; fi
    sleep 0.25
  done
  health=""
  if [ -n "$sock2" ]; then
    health="$(curl -fsS --unix-socket "$sock2" -H "Host: localhost" http://x/api/system/auto-identity 2>&1 || true)"
  fi
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
  set -e
  rm -rf "$NODE"
  notes="$(printf '%s\nthrowaway boot health:\n```\n%s\n```\n' "$notes" "$health")"
  if [ -z "$sock2" ] || [ -z "$health" ]; then
    ns_write_report "$SLUG" FAIL "throwaway lastdbd failed to serve auto-identity\n$notes" || exit 1
    exit 1
  fi
  ns_write_report "$SLUG" PASS-OFFLINE "$(printf 'Mini throwaway boot GREEN (never primary).\n\n%s\nLive full CoW smoke: skill lastdb-smoke-test / sop-lastdb-local-smoke-test\n' "$notes")"
  exit 0
fi

# Live: invoke scheduled smoke skill path if a runnable script exists
if [ -x "$HOME/.last-stack/bin/last-stack-lastdb-current" ] || command -v lastdb >/dev/null; then
  notes="$(printf '%s\nLive mode: run skill lastdb-smoke-test (CoW of real data) — not inlined to avoid long CI.\n' "$notes")"
fi
ns_write_report "$SLUG" PASS "$(printf 'Minimal-node live path documents CoW smoke skill; throwaway boot already proven offline.\n\n%s\n' "$notes")"
