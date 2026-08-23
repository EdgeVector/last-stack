#!/usr/bin/env bash
# Shared live LASTDB_* env-mirror for CoW probes.
# Sourced by safe-upgrade-lastdb.sh and write-path-cow-probe.sh.
# Never invent a second env-mirror.
#
# LIVE_LASTDB_ENV_PAIRS: KEY=VAL per line from the live LaunchAgent plist.
# HOME-shaped keys are excluded — the probe must only ever see its own
# --data-dir copy.
#
# bash 3.2 compatible (macOS /bin/bash). No side effects at source.

live_lastdb_env_pairs() {
  # LASTDB_* EnvironmentVariables from the live LaunchAgent plist, KEY=VAL per
  # line, so probe nodes boot with the primary's tuning (warm budget, atom
  # limit, …). Without this, probes measure default-config behavior the live
  # node does not have (e2e 2026-07-28: probe scan 43s vs live ~23s purely from
  # the missing 4 GiB LASTDB_HASH_GROUP_WARM_BYTES). HOME-shaped keys are
  # excluded — the probe must only ever see its own --data-dir copy.
  local plist="${1:-${LAUNCHD_PLIST:-}}"
  [ -n "$plist" ] && [ -f "$plist" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$plist" 2>/dev/null \
    | awk -F' = ' '
        $1 ~ /^ *LASTDB_/ {
          key=$1; gsub(/^ +| +$/,"",key)
          if (key == "LASTDB_HOME" || key == "FOLDDB_HOME" || key == "LASTDB_DATA_DIR") next
          val=$2; gsub(/^ +| +$/,"",val)
          if (key != "" && val != "") print key "=" val
        }'
}
