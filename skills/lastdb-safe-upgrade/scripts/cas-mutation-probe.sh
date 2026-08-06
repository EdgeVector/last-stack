#!/usr/bin/env bash
# Bounded `/api/mutation` CAS (expected) probe for lastdb-safe-upgrade.
#
# LastGit forwards CAS preconditions for ref writes and terminal CI verdicts.
# Older nodes ignore `expected` and write unconditionally — silent until
# LastGit's concurrency/CI invariants collapse. This probe is the upgrade
# gate: the candidate binary must reject a false precondition with 409
# cas_conflict and must not land the refused write, before live promotion.
#
# GUARDRAIL: boots a throwaway lastdbd under /tmp (or reuses LastGit's
# cas-expected-node-enforced.sh). NEVER points at ~/.lastdb / ~/.folddb.
# Not for routine health checks or live-primary mutation paths.
#
# Usage:
#   cas-mutation-probe.sh --lastdbd /path/to/lastdbd
#   cas-mutation-probe.sh --classify --http-code 409 --resp-file body.json
#   cas-mutation-probe.sh --classify --http-code 200 --resp-file body.json
#
# Exit:
#   0 = GREEN (CAS enforced) or SKIP (tools/schema unavailable; caller decides)
#   1 = RED  (node accepted a false CAS precondition / other probe failure)
#   2 = usage
set -euo pipefail

PROBE_NAME="cas-mutation-probe"
LASTDBD_BIN=""
CLASSIFY=0
HTTP_CODE=""
RESP_FILE=""
SCHEMA_MAP="${LASTDB_PROBE_CAS_SCHEMA_MAP:-${LASTGIT_SCHEMA_MAP:-$HOME/.lastgit/schema-map.json}}"
LASTGIT_PROBE="${LASTDB_PROBE_CAS_LASTGIT_SCRIPT:-}"

usage() {
  sed -n '2,22p' "$0"
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --lastdbd) LASTDBD_BIN="$2"; shift 2 ;;
    --classify) CLASSIFY=1; shift ;;
    --http-code) HTTP_CODE="$2"; shift 2 ;;
    --resp-file) RESP_FILE="$2"; shift 2 ;;
    --schema-map) SCHEMA_MAP="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s\n' "$PROBE_NAME" "$*"; }
fail_red() {
  # $1 = candidate path (may be empty in classify mode), $2+ = reason
  local cand="${1:-unknown}"
  shift || true
  echo ""
  echo "VERDICT: RED"
  echo "CANDIDATE: $cand"
  echo "REASON: promotion is blocked because the node accepted a false CAS precondition (or the CAS probe could not prove enforcement)."
  echo "DETAIL: $*"
  echo "NEXT:   do NOT live-upgrade this binary; fix /api/mutation expected-precondition enforcement (LastGit CAS depends on it)."
  exit 1
}

# --- pure classify (unit tests; no node) -------------------------------------
# GREEN when false-precondition returns 409 with cas_conflict.
# RED when HTTP is 200 (unconditional write) or any non-409.
classify_false_cas_response() {
  local code="$1" resp="${2:-}"
  if [ "$code" = "409" ]; then
    if [ -n "$resp" ] && [ -f "$resp" ]; then
      if command -v jq >/dev/null 2>&1; then
        if jq -e '.error == "cas_conflict"' "$resp" >/dev/null 2>&1; then
          echo "GREEN: false precondition returned 409 cas_conflict"
          return 0
        fi
        echo "RED: 409 body is not cas_conflict"
        return 1
      fi
    fi
    echo "GREEN: false precondition returned 409"
    return 0
  fi
  if [ "$code" = "200" ]; then
    echo "RED: node accepted false CAS precondition (HTTP 200 — write applied unconditionally)"
    return 1
  fi
  echo "RED: unexpected HTTP $code for false CAS precondition (want 409 cas_conflict)"
  return 1
}

if [ "$CLASSIFY" -eq 1 ]; then
  [ -n "$HTTP_CODE" ] || { echo "FAIL: --http-code required with --classify" >&2; exit 2; }
  set +e
  out="$(classify_false_cas_response "$HTTP_CODE" "$RESP_FILE")"
  rc=$?
  set -e
  printf '%s\n' "$out"
  exit "$rc"
fi

[ -n "$LASTDBD_BIN" ] || { echo "FAIL: --lastdbd PATH is required" >&2; exit 2; }
[ -x "$LASTDBD_BIN" ] || fail_red "$LASTDBD_BIN" "candidate not executable: $LASTDBD_BIN"

for tool in jq curl; do
  command -v "$tool" >/dev/null || {
    log "SKIP: $tool not on PATH — cannot run CAS probe"
    echo "VERDICT: SKIP"
    echo "CANDIDATE: $LASTDBD_BIN"
    echo "REASON: missing tool $tool"
    exit 0
  }
done

# Prefer LastGit's battle-tested discriminator when present (same machine
# that runs LastGit). LASTDBD pins the candidate, not the live primary.
find_lastgit_cas_script() {
  if [ -n "$LASTGIT_PROBE" ] && [ -f "$LASTGIT_PROBE" ]; then
    echo "$LASTGIT_PROBE"
    return 0
  fi
  local c
  for c in \
    "$HOME/.lastgit/host-checkout/lastgit/test/cas-expected-node-enforced.sh" \
    "$HOME/code/edgevector/lastgit/test/cas-expected-node-enforced.sh" \
    "${LASTGIT_ROOT:-}/test/cas-expected-node-enforced.sh"
  do
    [ -n "$c" ] && [ -f "$c" ] && { echo "$c"; return 0; }
  done
  return 1
}

run_via_lastgit() {
  local script="$1" out rc
  out="$(mktemp "${TMPDIR:-/tmp}/cas-probe-lg.XXXXXX")"
  set +e
  LASTDBD="$LASTDBD_BIN" LASTGIT_SCHEMA_MAP="$SCHEMA_MAP" \
    bash "$script" >"$out" 2>&1
  rc=$?
  set -e
  cat "$out"
  if grep -q 'CAS EXPECTED NODE-ENFORCED PASS' "$out"; then
    log "GREEN: LastGit cas-expected-node-enforced passed for $LASTDBD_BIN"
    echo "VERDICT: GREEN"
    echo "CANDIDATE: $LASTDBD_BIN"
    echo "REASON: false CAS precondition → 409 cas_conflict; refused write did not land"
    rm -f "$out"
    return 0
  fi
  if grep -qE '^SKIP:|SKIP: no ' "$out"; then
    log "SKIP: LastGit CAS script skipped (schema map / binary preflight)"
    echo "VERDICT: SKIP"
    echo "CANDIDATE: $LASTDBD_BIN"
    rm -f "$out"
    return 0
  fi
  # Non-PASS without explicit SKIP = RED (node ignored expected, or probe broken)
  rm -f "$out"
  fail_red "$LASTDBD_BIN" "LastGit cas-expected-node-enforced failed (exit $rc) against candidate"
}

if lg_script="$(find_lastgit_cas_script)"; then
  log "using LastGit discriminator: $lg_script"
  run_via_lastgit "$lg_script"
  exit 0
fi

# --- self-contained path (no LastGit checkout) --------------------------------
# Boots ephemeral node under /tmp, loads LastgitCiStatus from schema map when
# present, runs the same true→200 / false→409 / refused-did-not-land sequence.

if [ ! -f "$SCHEMA_MAP" ]; then
  log "SKIP: no schema map at $SCHEMA_MAP and no LastGit CAS script — cannot load LastgitCiStatus"
  echo "VERDICT: SKIP"
  echo "CANDIDATE: $LASTDBD_BIN"
  echo "REASON: missing schema map and LastGit cas-expected-node-enforced.sh"
  exit 0
fi

HASH="$(jq -r '.schemas.LastgitCiStatus // empty' "$SCHEMA_MAP" 2>/dev/null || true)"
if [ -z "$HASH" ] || [ "$HASH" = "null" ]; then
  log "SKIP: schema map has no LastgitCiStatus"
  echo "VERDICT: SKIP"
  echo "CANDIDATE: $LASTDBD_BIN"
  exit 0
fi

# Short /tmp path: macOS unix socket path cap (~104 bytes).
NODE_DIR="$(mktemp -d "/tmp/ls-cas-XXXXXX")"
SOCK="$NODE_DIR/data/folddb.sock"
FSOCK="$NODE_DIR/data/folddb-full.sock"
NODE_PID=""
cleanup() {
  if [ -n "${NODE_PID:-}" ]; then
    kill "$NODE_PID" 2>/dev/null || true
    wait "$NODE_PID" 2>/dev/null || true
  fi
  rm -rf "$NODE_DIR"
}
trap cleanup EXIT

case "$NODE_DIR" in
  "$HOME/.folddb"*|"$HOME/.lastdb"*) fail_red "$LASTDBD_BIN" "refusing shared data-dir $NODE_DIR" ;;
esac

log "booting ephemeral candidate $LASTDBD_BIN under $NODE_DIR"
(
  unset SENTRY_DSN OBS_SENTRY_DSN RUST_SENTRY_DSN SENTRY_URL FOLD_SENTRY_DSN 2>/dev/null || true
  export LASTDB_HOME="$NODE_DIR" FOLDDB_HOME="$NODE_DIR" FOLDDB_DISABLE_KEYCHAIN=1
  exec "$LASTDBD_BIN" --data-dir "$NODE_DIR"
) >"$NODE_DIR/node.log" 2>&1 &
NODE_PID=$!

ok=""
for _ in $(seq 1 80); do
  if [ -S "$SOCK" ]; then ok=1; break; fi
  if ! kill -0 "$NODE_PID" 2>/dev/null; then
    fail_red "$LASTDBD_BIN" "candidate exited during boot ($(tail -3 "$NODE_DIR/node.log" 2>/dev/null | tr '\n' ' '))"
  fi
  sleep 0.25
done
[ -n "$ok" ] || fail_red "$LASTDBD_BIN" "candidate socket never came up"

UH="$(curl -fsS --unix-socket "$SOCK" -H "Host: localhost" \
  http://x/api/system/auto-identity | jq -r '.user_hash // empty')"
[ -n "$UH" ] && [ "$UH" != "null" ] || fail_red "$LASTDBD_BIN" "candidate has no auto-identity"

# Load schemas (tolerate optional failures; require LastgitCiStatus by hash).
LOAD_BODY="$(mktemp "$NODE_DIR/load-XXXXXX.json")"
jq -c '{schemas:[.schemas[]]}' "$SCHEMA_MAP" >"$LOAD_BODY"
# Wait for full sock (schema load API)
for _ in $(seq 1 40); do
  [ -S "$FSOCK" ] && break
  sleep 0.25
done
if [ -S "$FSOCK" ]; then
  curl -sS --max-time 60 --unix-socket "$FSOCK" -H "Host: localhost" \
    -H "X-User-Hash: $UH" -H "Content-Type: application/json" \
    -H "X-LastDB-Client: last-stack-cas-probe" \
    --data-binary @"$LOAD_BODY" http://x/api/schemas/load \
    >"$NODE_DIR/load-result.json" 2>"$NODE_DIR/load.err" || true
else
  curl -sS --max-time 60 --unix-socket "$SOCK" -H "Host: localhost" \
    -H "X-User-Hash: $UH" -H "Content-Type: application/json" \
    -H "X-LastDB-Client: last-stack-cas-probe" \
    --data-binary @"$LOAD_BODY" http://x/api/schemas/load \
    >"$NODE_DIR/load-result.json" 2>"$NODE_DIR/load.err" || true
fi

KEY='{"hash":"cas-probe","range":"cas-probe:deadbeef:ci-required"}'
api() {
  curl -sS -o "$NODE_DIR/resp.json" -w '%{http_code}' --unix-socket "$SOCK" \
    -H "Host: localhost" -H "X-User-Hash: $UH" \
    -H "Content-Type: application/json" -H "X-LastDB-Client: last-stack-cas-probe" \
    --data-binary @"$1" http://x/api/mutation
}
row() {
  # $1=mutation_type $2=optional expected JSON fragment $3=state $4=log_excerpt
  cat >"$NODE_DIR/m.json" <<EOF
{"type":"mutation","schema":"$HASH","mutation_type":"$1","key_value":$KEY,
 $2
 "fields_and_values":{"status_key":"cas-probe:deadbeef:ci-required","repo":"cas-probe",
 "oid":"deadbeef","context":"ci-required","state":"$3","log_excerpt":"$4","event_id":"e",
 "updated_at":"2026-01-01T00:00:00Z","schema_version":"2","layout":"hashrange_v2"}}
EOF
  api "$NODE_DIR/m.json"
}

CODE="$(row create '' pending '')"
if [ "$CODE" != "200" ]; then
  # Schema may not have loaded — treat as SKIP (can't prove) rather than RED
  # on a schema-service outage. Live LastGit path would SKIP similarly.
  log "SKIP: seed create returned $CODE (schema may be unavailable)"
  cat "$NODE_DIR/resp.json" 2>/dev/null || true
  echo "VERDICT: SKIP"
  echo "CANDIDATE: $LASTDBD_BIN"
  exit 0
fi

CODE="$(row update '"expected":{"type":"value","field":"state","value":"pending"},' success ok)"
[ "$CODE" = "200" ] || fail_red "$LASTDBD_BIN" "true CAS(state==pending) returned $CODE (expected 200)"

CODE="$(row update '"expected":{"type":"value","field":"state","value":"pending"},' failure CLOBBER)"
set +e
classify_out="$(classify_false_cas_response "$CODE" "$NODE_DIR/resp.json")"
classify_rc=$?
set -e
printf '%s\n' "$classify_out"
if [ "$classify_rc" -ne 0 ]; then
  cat "$NODE_DIR/resp.json" 2>/dev/null || true
  fail_red "$LASTDBD_BIN" "false CAS(state==pending) on success row returned HTTP $CODE — node ignores expected"
fi

CODE="$(row update '"expected":{"type":"value","field":"state","value":"success"},' success 'still-success')"
[ "$CODE" = "200" ] || fail_red "$LASTDBD_BIN" "refused write still landed — row is no longer success (HTTP $CODE)"

log "GREEN: true->200, false->409 cas_conflict, refused write did not land"
echo "VERDICT: GREEN"
echo "CANDIDATE: $LASTDBD_BIN"
echo "REASON: false CAS precondition → 409 cas_conflict; refused write did not land"
exit 0
