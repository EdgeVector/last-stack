#!/usr/bin/env bash
# Pure-ish launchd helpers for safe-upgrade. No work runs when this file is sourced.

lastdb_launchd_reload_job() {
  # Reload the job definition so plist EnvironmentVariables take effect.
  # Args: launchctl-bin domain label plist
  local launchctl_bin="$1" domain="$2" label="$3" plist="$4"
  local service="${domain}/${label}"

  if "$launchctl_bin" help bootout >/dev/null 2>&1 \
    && "$launchctl_bin" help bootstrap >/dev/null 2>&1; then
    printf 'LASTDB_LAUNCHD_RESTART_PATH=job-reload service=%s plist=%s\n' \
      "$service" "$plist"
    "$launchctl_bin" bootout "$service" || {
      printf 'LASTDB_LAUNCHD_RELOAD=failed step=bootout service=%s\n' "$service" >&2
      return 1
    }
    "$launchctl_bin" bootstrap "$domain" "$plist" || {
      printf 'LASTDB_LAUNCHD_RELOAD=failed step=bootstrap domain=%s plist=%s\n' \
        "$domain" "$plist" >&2
      return 1
    }
    printf 'LASTDB_LAUNCHD_RELOAD=ok service=%s\n' "$service"
    return 0
  fi

  printf 'LASTDB_LAUNCHD_RESTART_PATH=kickstart service=%s reason=bootout-bootstrap-unavailable\n' \
    "$service"
  "$launchctl_bin" kickstart -k "$service"
}

lastdb_launchd_plist_env_keys() {
  # Print keys only; never expose plist values in logs or comparison output.
  local plist="$1"
  local plistbuddy_bin="${LASTDB_PLISTBUDDY_BIN:-/usr/libexec/PlistBuddy}"
  "$plistbuddy_bin" -c 'Print :EnvironmentVariables' "$plist" 2>/dev/null \
    | awk -F' = ' '
        NF >= 2 {
          key=$1
          gsub(/^ +| +$/, "", key)
          if (key ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print key
        }'
}

lastdb_process_env_keys() {
  # ps eww renders argv followed by KEY=VALUE tokens. Keep key names only.
  local pid="$1"
  local ps_bin="${LASTDB_PS_BIN:-ps}"
  "$ps_bin" eww -p "$pid" -o command= 2>/dev/null \
    | tr ' ' '\n' \
    | awk -F= '$1 ~ /^[A-Za-z_][A-Za-z0-9_]*$/ && NF >= 2 { print $1 }'
}

lastdb_launchd_missing_env_keys() {
  local plist="$1" pid="$2"
  comm -23 \
    <(lastdb_launchd_plist_env_keys "$plist" | LC_ALL=C sort -u) \
    <(lastdb_process_env_keys "$pid" | LC_ALL=C sort -u)
}

lastdb_live_config_drift_check() {
  # Args: plist pid. Default WARN; LASTDB_LIVE_CONFIG_ENFORCE=1 makes drift RED.
  local plist="$1" pid="$2"
  local missing missing_csv
  missing="$(lastdb_launchd_missing_env_keys "$plist" "$pid")"
  if [ -z "$missing" ]; then
    printf 'LIVE_CONFIG_DRIFT=ok pid=%s plist=%s\n' "$pid" "$plist"
    return 0
  fi

  missing_csv="$(printf '%s\n' "$missing" | paste -sd, -)"
  printf 'LIVE_CONFIG_DRIFT=WARN pid=%s missing_keys=%s plist=%s\n' \
    "$pid" "$missing_csv" "$plist" >&2
  [ "${LASTDB_LIVE_CONFIG_ENFORCE:-0}" != "1" ]
}
