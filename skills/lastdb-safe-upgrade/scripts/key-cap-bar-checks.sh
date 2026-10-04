#!/usr/bin/env bash
# Pure key-cap bar for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# The logical resident set caps fetched records by COUNT (fold
# RESIDENT_KEY_CAP = 10000), not by bytes. It keeps no hash groups, so the
# footprint governor's warm_bytes_freed stays 0 by design and cannot prove
# that eviction works. This bar proves the purge instead.
#
# The driver boots the candidate on its own CoW copy with
# LASTDB_RESIDENT_KEY_CAP far below the default, drives reads, and samples
# /api/status. Every sample must publish the three resident gauges. Every
# sample must report resident_key_budget equal to the cap the bar asked for
# (proof that the override took effect). No sample may report
# resident_key_count above that budget. resident_purged_keys must rise above
# 0 (proof that the purge ran). Absent fields are RED. There is no skip: a
# binary without the logical resident set (be41e547e) fails here.
#
# bash 3.2 compatible (macOS /bin/bash). No nested functions.

KEY_CAP_BAR_CAP="${KEY_CAP_BAR_CAP:-100}"
KEY_CAP_BAR_SECS="${KEY_CAP_BAR_SECS:-120}"
KEY_CAP_BAR_ENV="LASTDB_RESIDENT_KEY_CAP"

# $1 = sample dir (sample-NNN.json files), $2 = expected cap, $3 = out path.
# Writes one proof document. Returns 1 when there are fewer than 2 samples.
key_cap_bar_from_samples() {
  local dir="$1" cap="$2" out="$3" all=""
  [ -n "$dir" ] && [ -n "$cap" ] && [ -n "$out" ] || return 1
  all="$dir/all.json"
  if ! jq -s '.' "$dir"/sample-*.json >"$all" 2>/dev/null; then
    printf '%s\n' '{}' >"$out"
    return 1
  fi
  jq -c --argjson cap "$cap" '
    def num:
      if type == "number" and floor == . then floor
      elif type == "string" and test("^[0-9]+$") then tonumber
      elif type == "object" and has("value") then (.value | num)
      else null end;
    def res: (.status.resident // .resident // {});
    map({
      budget: (res.resident_key_budget | num),
      count: (res.resident_key_count | num),
      purged: (res.resident_purged_keys | num)
    }) as $rows
    | {
        proof_kind: "key-cap",
        cap_expected: $cap,
        samples: ($rows | length),
        complete: (($rows | length) > 0
                   and all($rows[]; .budget != null and .count != null and .purged != null)),
        budget_ok: (($rows | length) > 0 and all($rows[]; .budget == $cap)),
        max_count: ([$rows[] | .count | select(. != null)] | max),
        max_budget: ([$rows[] | .budget | select(. != null)] | max),
        count_within_budget: (($rows | length) > 0
                              and all($rows[]; .count != null and .budget != null and .count <= .budget)),
        purged_last: ([$rows[] | .purged | select(. != null)] | last)
      }
  ' "$all" >"$out" || {
    printf '%s\n' '{}' >"$out"
    return 1
  }
  [ "$(jq -r '.samples' "$out")" -ge 2 ] 2>/dev/null || return 1
  return 0
}

# $1 = proof document. Prints one GREEN or RED line. Returns 1 on RED.
key_cap_bar_eval() {
  local file="$1" kind="" samples="" complete="" budget_ok="" within="" purged="" cap="" maxc="" maxb=""
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf 'key-cap bar RED: proof is absent (not skipped)\n'
    return 1
  fi
  kind="$(jq -r '.proof_kind // ""' "$file" 2>/dev/null)"
  if [ "$kind" != "key-cap" ]; then
    printf 'key-cap bar RED: proof_kind=%s is not key-cap (not skipped)\n' "${kind:-absent}"
    return 1
  fi
  samples="$(jq -r '.samples // 0' "$file")"
  complete="$(jq -r '.complete // false' "$file")"
  budget_ok="$(jq -r '.budget_ok // false' "$file")"
  within="$(jq -r '.count_within_budget // false' "$file")"
  purged="$(jq -r 'if .purged_last == null then "" else (.purged_last | tostring) end' "$file")"
  cap="$(jq -r '.cap_expected // ""' "$file")"
  maxc="$(jq -r '.max_count // "-"' "$file")"
  maxb="$(jq -r '.max_budget // "-"' "$file")"
  case "$samples" in ''|*[!0-9]*) samples=0 ;; esac
  if [ "$samples" -lt 2 ]; then
    printf 'key-cap bar RED: %s status sample(s), need at least 2 (not skipped)\n' "$samples"
    return 1
  fi
  if [ "$complete" != "true" ]; then
    printf 'key-cap bar RED: a sample lacks resident_key_budget, resident_key_count or resident_purged_keys (absent fields fail the bar; not skipped)\n'
    return 1
  fi
  if [ "$budget_ok" != "true" ]; then
    printf 'key-cap bar RED: resident_key_budget is not the requested cap %s on every sample (max seen %s); %s did not take effect\n' \
      "$cap" "$maxb" "$KEY_CAP_BAR_ENV"
    return 1
  fi
  if [ "$within" != "true" ]; then
    printf 'key-cap bar RED: resident_key_count %s went above resident_key_budget %s\n' "$maxc" "$cap"
    return 1
  fi
  case "$purged" in ''|*[!0-9]*) purged=0 ;; esac
  if [ "$purged" -lt 1 ]; then
    printf 'key-cap bar RED: resident_purged_keys stayed 0, so the purge never ran under cap %s (max count %s)\n' \
      "$cap" "$maxc"
    return 1
  fi
  printf 'key-cap bar GREEN: cap=%s samples=%s max_count=%s purged_keys=%s\n' \
    "$cap" "$samples" "$maxc" "$purged"
  return 0
}
