#!/usr/bin/env bash
# Pure live-socket helpers for lastdb-safe-upgrade. No work runs at source.
#
# A leftover folddb.sock inode is still `-S` after bootout. Waiting only for
# the inode reports "socket up after 0s" and then the post-check curls a
# dead listener for 120s (2026-08-26: bootstrap EIO, leftover sock, RED).
# A socket is live only when a process holds it AND /health is ok.
#
# bash 3.2 compatible — no namerefs, no nested functions.
# Avoid `... | head` under `set -o pipefail` (SIGPIPE → 141).

live_unix_socket_listener_pid() {
  local sock="$1"
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  local pid=""
  # CAUTION: `lsof -t -U -- "$sock"` lists EVERY unix socket on the host
  # (path is ignored). Use the path-only form. Sandboxed CI may hide lsof.
  pid="$(lsof -t -- "$sock" 2>/dev/null | awk 'NR==1 { print; exit }')"
  [ -n "$pid" ] || return 1
  printf '%s\n' "$pid"
}

live_unix_socket_connect_ok() {
  # rc 0 = a process is accepting connects (live listener).
  # Leftover inode: ConnectionRefusedError.
  local sock="$1"
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$sock" <<'PY'
import socket
import sys

path = sys.argv[1]
s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(1.0)
try:
    s.connect(path)
except (ConnectionRefusedError, FileNotFoundError, OSError):
    sys.exit(1)
finally:
    s.close()
sys.exit(0)
PY
}

live_unix_socket_has_listener() {
  local sock="$1"
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  # Connect is the listener bar. lsof is a fallback when python3 is missing;
  # sandboxed CI can hide lsof even while a listener is bound.
  if live_unix_socket_connect_ok "$sock"; then
    return 0
  fi
  live_unix_socket_listener_pid "$sock" >/dev/null
}

live_unix_socket_health_ok() {
  local sock="$1"
  [ -n "$sock" ] && [ -S "$sock" ] || return 1
  curl -sS --max-time 3 --unix-socket "$sock" -H 'Host: localhost' \
    http://x/health 2>/dev/null | grep -q '"status":"ok"'
}

live_unix_socket_is_healthy() {
  local sock="$1"
  live_unix_socket_has_listener "$sock" || return 1
  live_unix_socket_health_ok "$sock"
}

unlink_stale_unix_socket() {
  # Unlink only when the inode exists and nothing holds it.
  # Never unlink a live listener's socket.
  local sock="$1"
  if [ -z "$sock" ]; then
    printf 'LIVE_SOCK=skip reason=empty-path\n'
    return 0
  fi
  if [ ! -e "$sock" ]; then
    printf 'LIVE_SOCK=absent path=%s\n' "$sock"
    return 0
  fi
  if live_unix_socket_has_listener "$sock"; then
    printf 'LIVE_SOCK=keep path=%s reason=listener\n' "$sock"
    return 0
  fi
  rm -f "$sock"
  printf 'LIVE_SOCK=unlinked path=%s reason=no-listener\n' "$sock"
}

wait_for_live_unix_socket_health() {
  # Args: sock wait_secs
  # Unlink a leftover inode (no listener), then wait until listener + /health.
  local sock="$1"
  local wait_secs="${2:-180}"
  local poll="${LASTDB_LIVE_SOCK_POLL_SECS:-2}"
  local waited=0
  local unlink_out=""
  [ -n "$sock" ] || return 1
  case "$wait_secs" in
    ''|*[!0-9]*) wait_secs=180 ;;
  esac
  case "$poll" in
    ''|*[!0-9]*) poll=2 ;;
  esac
  unlink_out="$(unlink_stale_unix_socket "$sock")"
  [ -n "$unlink_out" ] && printf '%s\n' "$unlink_out"
  while :; do
    if live_unix_socket_is_healthy "$sock"; then
      printf 'LIVE_SOCK=healthy after_s=%s path=%s\n' "$waited" "$sock"
      return 0
    fi
    [ "$waited" -ge "$wait_secs" ] && break
    if [ "$poll" -gt 0 ]; then
      sleep "$poll"
      waited=$((waited + poll))
    else
      waited=$((wait_secs + 1))
    fi
  done
  printf 'LIVE_SOCK=unhealthy after_s=%s path=%s\n' "$waited" "$sock" >&2
  return 1
}
