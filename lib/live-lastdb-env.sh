#!/usr/bin/env bash
# Shared live LASTDB_* env-mirror for dev nodes.
# Sourced by bin/last-stack-lastdb-dev.
# Never invent a second env-mirror.
#
# LIVE_LASTDB_ENV_PAIRS: KEY=VAL per line from the live LaunchAgent plist.
# HOME-shaped keys are excluded — the probe must only ever see its own
# --data-dir copy. LASTDB_BUILD_CONFLICT_STAMP_ON_COPY is excluded too.
# It is not a live key, and a primary plist must not hand it to a dev node.
#
# bash 3.2 compatible (macOS /bin/bash). No side effects at source.

live_lastdb_env_pairs() {
  # LASTDB_* EnvironmentVariables from the live LaunchAgent plist, KEY=VAL per
  # line, so probe nodes boot with the primary's tuning (field value limit,
  # …). Without this, probes measure default-config behavior the live node
  # does not have. HOME-shaped keys and
  # LASTDB_BUILD_CONFLICT_STAMP_ON_COPY are excluded — the probe must only
  # ever see its own --data-dir copy, and the stamp flag is not a live key.
  local plist="${1:-${LAUNCHD_PLIST:-}}"
  [ -n "$plist" ] && [ -f "$plist" ] || return 0
  /usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables' "$plist" 2>/dev/null \
    | awk -F' = ' '
        $1 ~ /^ *LASTDB_/ {
          key=$1; gsub(/^ +| +$/,"",key)
          if (key == "LASTDB_HOME" || key == "LASTDB_DATA_DIR" || key == "LASTDB_BUILD_CONFLICT_STAMP_ON_COPY") next
          val=$2; gsub(/^ +| +$/,"",val)
          if (key != "" && val != "") print key "=" val
        }'
}
