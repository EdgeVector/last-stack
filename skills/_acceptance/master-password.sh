#!/usr/bin/env bash
# Acceptance check — LastDB master password survives a restart.
#
# This is the worked example for the acceptance gate (SOP
# `sop-autonomous-acceptance-gate` in fbrain). It is the check that, had it
# existed, would have caught the 2026-06-30 master-password lockout BEFORE it
# shipped: the password could be SET (write path, unit tests green, PR merged)
# but the node would not UNLOCK with it after a restart, because boot key
# resolution (env -> passphrase -> keyfile -> keychain) never re-supplies the
# passphrase and falls through to the stale keyfile root.
#
# Shape: ARRANGE -> ACT -> BOUNDARY (restart) -> ASSERT+ -> ASSERT-.
# The BOUNDARY is the whole point: an in-process set-then-get passes while the
# app is broken. Runs against a THROWAWAY data dir only — never ~/.folddb, the
# primary brain, or Tom's keyring.
#
# Real routes verified in fold_db_node/src/server/http_server.rs:
#   POST /api/system/master-password , /api/system/unlock , /api/system/status
# Confirm request-body field names + the unlock X-User-Hash handshake
# (/api/system/auto-identity) against the handlers when adapting per release.
set -euo pipefail

BIN="${LASTDB_BIN:-/Applications/LastDB.app/Contents/MacOS/lastdb_server}"
PORT="${LASTDB_PORT:-8899}"
PW="acceptance-pw-$$"
DATA="$(mktemp -d)"
export FOLDDB_HOME="$DATA" FOLDDB_DISABLE_KEYCHAIN=1   # throwaway; never touches ~/.folddb or the keyring

NODE=""
cleanup() { [ -n "$NODE" ] && kill "$NODE" 2>/dev/null || true; rm -rf "$DATA"; }
trap cleanup EXIT

api()  { curl -sf "localhost:$PORT$1" "${@:2}"; }
boot() {
  "$BIN" --data-dir "$DATA/data" --port "$PORT" >>"$DATA/node.log" 2>&1 & NODE=$!
  for _ in $(seq 1 40); do api /api/health >/dev/null 2>&1 && return 0; sleep 0.5; done
  echo "FAIL[boot]: node never became healthy"; tail -20 "$DATA/node.log"; exit 1
}

# 1-2  ARRANGE + ACT: fresh node (keyfile root), then set a master password.
boot
api /api/system/master-password -X POST -H 'content-type: application/json' \
    -d "{\"password\":\"$PW\"}" >/dev/null

# 3    BOUNDARY: restart WITHOUT supplying the passphrase — exactly what the
#      desktop app does today.
kill "$NODE"; wait "$NODE" 2>/dev/null || true; NODE=""
boot

# 4    ASSERT+ : node must come up usable and unlock with the correct password.
st="$(api /api/system/status | sed -n 's/.*"status":"\([^"]*\)".*/\1/p')"
if [ "$st" != "ok" ]; then
  echo "FAIL[assert+]: status=$st (expected ok) — reproduces 2026-06-30 lockout"; exit 1
fi
if ! api /api/system/unlock -X POST -H 'content-type: application/json' \
       -d "{\"password\":\"$PW\"}" >/dev/null; then
  echo "FAIL[assert+]: correct password rejected at unlock"; exit 1
fi

# 5    ASSERT- : a wrong password must be rejected.
if api /api/system/unlock -X POST -H 'content-type: application/json' \
     -d '{"password":"WRONG"}' >/dev/null 2>&1; then
  echo "FAIL[assert-]: wrong password was accepted"; exit 1
fi

echo "PASS: master-password round trip survives a restart (set -> restart -> unlock; wrong pw rejected)"
