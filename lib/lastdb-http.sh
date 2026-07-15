#!/usr/bin/env bash
# Shared LastDB Mini HTTP helpers for Last Stack admin publish/deliver scripts.
# Source this file; do not execute it directly.
#
# Environment:
#   LAST_STACK_LASTDB_SOCKET / LASTDB_SOCKET_PATH / FOLDDB_SOCKET_PATH
#   LAST_STACK_LASTDB_NODE_URL (default http://localhost:9001; socket preferred)
#   LASTDB_HOME (default ~/.lastdb) — used when no socket env is set
set -euo pipefail

last_stack_lastdb_socket() {
  if [ -n "${LAST_STACK_LASTDB_SOCKET:-}" ]; then
    printf '%s\n' "$LAST_STACK_LASTDB_SOCKET"
    return
  fi
  if [ -n "${LASTDB_SOCKET_PATH:-}" ]; then
    printf '%s\n' "$LASTDB_SOCKET_PATH"
    return
  fi
  if [ -n "${FOLDDB_SOCKET_PATH:-}" ]; then
    printf '%s\n' "$FOLDDB_SOCKET_PATH"
    return
  fi
  if [ -n "${FBRAIN_FOLDDB_SOCKET:-}" ]; then
    printf '%s\n' "$FBRAIN_FOLDDB_SOCKET"
    return
  fi
  local home="${LASTDB_HOME:-$HOME/.lastdb}"
  printf '%s\n' "$home/data/folddb.sock"
}

last_stack_lastdb_node_url() {
  local url="${LAST_STACK_LASTDB_NODE_URL:-http://localhost:9001}"
  printf '%s\n' "${url%/}"
}

# last_stack_lastdb_json METHOD PATH [BODY_JSON]
# Prints response body on success; exits non-zero with stderr on failure.
# Sets LAST_STACK_LASTDB_USER_HASH when auto-identity succeeds.
last_stack_lastdb_json() {
  local method="$1"
  local path="$2"
  local body="${3-}"
  local socket node_url use_socket=0
  local tmp_headers tmp_body http_code
  socket="$(last_stack_lastdb_socket)"
  node_url="$(last_stack_lastdb_node_url)"

  case "$node_url" in
    http://localhost|http://localhost:*|http://127.0.0.1|http://127.0.0.1:*|http://[::1]|http://[::1]:*)
      if [ -S "$socket" ]; then
        use_socket=1
      fi
      ;;
  esac

  tmp_headers="$(mktemp)"
  tmp_body="$(mktemp)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_headers' '$tmp_body'" RETURN

  local -a curl_args=(
    -sS
    -D "$tmp_headers"
    -o "$tmp_body"
    -w "%{http_code}"
    -X "$method"
  )
  if [ -n "${LAST_STACK_LASTDB_USER_HASH:-}" ]; then
    curl_args+=(-H "X-User-Hash: ${LAST_STACK_LASTDB_USER_HASH}")
  fi
  if [ -n "$body" ]; then
    curl_args+=(-H "Content-Type: application/json" -d "$body")
  fi
  if [ "$use_socket" -eq 1 ]; then
    curl_args+=(--unix-socket "$socket" "http://localhost${path}")
  else
    curl_args+=("${node_url}${path}")
  fi

  http_code="$(curl "${curl_args[@]}" || true)"
  if [ -z "$http_code" ] || [ "$http_code" = "000" ]; then
    if [ "$use_socket" -eq 1 ]; then
      echo "last-stack-lastdb: unreachable over socket $socket" >&2
    else
      echo "last-stack-lastdb: unreachable at $node_url" >&2
    fi
    return 1
  fi
  if [ "$http_code" -lt 200 ] || [ "$http_code" -ge 300 ]; then
    echo "last-stack-lastdb: $method $path returned HTTP $http_code: $(head -c 400 "$tmp_body")" >&2
    return 1
  fi
  cat "$tmp_body"
}

last_stack_lastdb_auto_identity() {
  if [ -n "${LAST_STACK_LASTDB_USER_HASH:-}" ]; then
    printf '%s\n' "$LAST_STACK_LASTDB_USER_HASH"
    return 0
  fi
  local body hash
  body="$(last_stack_lastdb_json GET /api/system/auto-identity)" || return 1
  hash="$(printf '%s' "$body" | last-stack-json-get .user_hash 2>/dev/null || true)"
  if [ -z "$hash" ] || [ "$hash" = "null" ]; then
    hash="$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("user_hash",""))' 2>/dev/null || true)"
  fi
  if [ -z "$hash" ]; then
    echo "last-stack-lastdb: auto-identity returned no user_hash" >&2
    return 1
  fi
  LAST_STACK_LASTDB_USER_HASH="$hash"
  export LAST_STACK_LASTDB_USER_HASH
  printf '%s\n' "$hash"
}

last_stack_json_field() {
  # stdin JSON → print field (dot path). Prefer last-stack-json-get when present.
  local path="$1"
  local root bin
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
  bin="$root/bin/last-stack-json-get"
  if [ -x "$bin" ]; then
    "$bin" "$path"
  else
    python3 - "$path" <<'PY'
import json, sys
path = sys.argv[1]
if path.startswith("."):
    path = path[1:]
cur = json.load(sys.stdin)
for part in path.split("."):
    if not part:
        continue
    if isinstance(cur, dict):
        cur = cur.get(part)
    else:
        cur = None
        break
if cur is None:
    sys.exit(1)
if isinstance(cur, (dict, list)):
    print(json.dumps(cur, separators=(",", ":")))
elif isinstance(cur, bool):
    print("true" if cur else "false")
else:
    print(cur)
PY
  fi
}
