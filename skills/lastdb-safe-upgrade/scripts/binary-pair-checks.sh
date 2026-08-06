#!/usr/bin/env bash
# Pure binary-pair gates for lastdb-safe-upgrade.

lastdb_binary_version() {
  local bin="$1"
  [ -x "$bin" ] || return 1
  "$bin" --version 2>/dev/null | awk '{print $NF}'
}

lastdb_sibling_cli_for_daemon() {
  local daemon="$1"
  printf '%s/lastdb\n' "$(dirname "$daemon")"
}

assert_lastdb_binary_pair_ok() {
  # $1 = lastdbd path, $2 = lastdb path, $3 = expected version, $4 = label
  local daemon="$1" cli="$2" expected="$3" label="$4"
  local daemon_ver cli_ver

  [ -x "$daemon" ] || {
    printf 'RED: %s lastdbd is not executable: %s\n' "$label" "$daemon"
    return 1
  }
  [ -x "$cli" ] || {
    printf 'RED: %s missing sibling lastdb CLI: %s\n' "$label" "$cli"
    return 1
  }

  daemon_ver="$(lastdb_binary_version "$daemon" || true)"
  cli_ver="$(lastdb_binary_version "$cli" || true)"
  [ -n "$daemon_ver" ] || {
    printf 'RED: %s lastdbd --version failed: %s\n' "$label" "$daemon"
    return 1
  }
  [ -n "$cli_ver" ] || {
    printf 'RED: %s lastdb --version failed: %s\n' "$label" "$cli"
    return 1
  }
  [ "$daemon_ver" = "$expected" ] || {
    printf 'RED: %s lastdbd version (%s) != expected (%s)\n' "$label" "$daemon_ver" "$expected"
    return 1
  }
  [ "$cli_ver" = "$expected" ] || {
    printf 'RED: %s lastdb CLI version (%s) != expected lastdbd version (%s)\n' "$label" "$cli_ver" "$expected"
    return 1
  }

  printf 'OK: %s lastdb/lastdbd version %s\n' "$label" "$expected"
  return 0
}
