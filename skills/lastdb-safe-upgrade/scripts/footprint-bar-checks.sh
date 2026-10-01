#!/usr/bin/env bash
# Pure footprint bar for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# The upgrade gate is proof_kind=upgrade-gate when
# 600 <= duration_secs < 86400. A 86400 soak is long-memory-candidate.
# It is not this gate. Absent fields fail. There is no skip: build
# be41e547e does not publish footprint_net, and a skip would promote it.
#
# Operating checks: purge_delay_ms = 0, phys_footprint - footprint_net
# at or under 512 MiB, and a 0.25 phys_footprint drop on every step that
# freed warm bytes. The 12 GiB p99 and the 1.3 multiplier stay backstops.
# They are not the operating target.
#
# bash 3.2 compatible (macOS /bin/bash). No nested functions.

FOOTPRINT_BAR_UPGRADE_GATE_SECS=600
FOOTPRINT_BAR_SOAK_SECS=86400
FOOTPRINT_BAR_SLACK_MAX_BYTES=$((512 * 1024 * 1024))
FOOTPRINT_BAR_P99_MAX_BYTES=$((12 * 1024 * 1024 * 1024))

# $1 = canonical JSON, $2 = jq filter. Prints a raw string.
footprint_bar_field() {
  printf '%s' "$1" | jq -r "$2"
}

# $1 = duration seconds. Prints upgrade-gate, long-memory-candidate, short,
# or absent. Does not decide pass or fail by itself.
footprint_bar_proof_kind() {
  local d="${1:-}"
  case "$d" in
    ''|*[!0-9]*) printf 'absent\n'; return 0 ;;
  esac
  if [ "$d" -ge "$FOOTPRINT_BAR_SOAK_SECS" ]; then
    printf 'long-memory-candidate\n'
  elif [ "$d" -ge "$FOOTPRINT_BAR_UPGRADE_GATE_SECS" ]; then
    printf 'upgrade-gate\n'
  else
    printf 'short\n'
  fi
}

# $1 = where (ephemeral-copy|primary), $2 = LASTDB_BUILD_CONFLICT_STAMP_ON_COPY.
# The flag may be 1 on the ephemeral copy only. The primary must not carry it.
footprint_stamp_env_allowed() {
  local where="$1" value="${2-}"
  case "$where" in
    ephemeral-copy)
      [ -z "$value" ] || [ "$value" = "1" ]
      ;;
    primary)
      [ -z "$value" ] || [ "$value" = "0" ]
      ;;
    *)
      return 1
      ;;
  esac
}

# $1 = plist. Prints the primary stamp flag, or an empty line when unset.
footprint_plist_stamp_value() {
  local plist="${1:-}" val=""
  if [ -z "$plist" ] || [ ! -f "$plist" ]; then
    printf '\n'
    return 0
  fi
  val="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDB_BUILD_CONFLICT_STAMP_ON_COPY' "$plist" 2>/dev/null || true)"
  printf '%s\n' "$val"
}

# $1 = copy path, $2 = primary home. Fail when the copy is the primary home
# or lives inside it. The copy's conflict stamp must not be installed there.
footprint_copy_is_not_primary() {
  local copy="$1" primary="$2"
  [ -n "$copy" ] && [ -n "$primary" ] || return 1
  case "$copy" in
    "$primary"|"$primary"/*) return 1 ;;
  esac
  case "$primary" in
    "$copy"|"$copy"/*) return 1 ;;
  esac
  return 0
}

# Read one status sample. Prints one GREEN or RED line. Returns 1 on RED.
# A sample that lacks footprint_net (or any other required field) is RED.
footprint_bar_eval() {
  local file="$1" canon="" missing="" expected=""
  local proof_kind="" duration="" purge="" phys="" net="" p99="" multiplier="" collect=""
  local nsteps=0 i=0 freed="" before="" after="" drop=0 freed_steps=0 slack=0
  if [ -z "$file" ] || [ ! -f "$file" ]; then
    printf 'footprint bar RED: status sample is absent (absent fields fail the bar; not skipped)\n'
    return 1
  fi
  canon="$(jq -c -e '
    def intval:
      if . == null then null
      elif type == "number" then (if floor == . then floor else "bad" end)
      elif type == "string" and test("^[0-9]+$") then tonumber
      else "bad" end;
    def step:
      {
        freed: ((.warm_bytes_freed // null) | intval),
        before: ((.footprint_before // .phys_footprint_before // .phys_footprint_before_bytes // null) | intval),
        after: ((.footprint_after // .phys_footprint_after // .phys_footprint_after_bytes // null) | intval)
      };
    . as $root
    | ($root.status // null) as $st0
    | (if ($st0 | type) == "object" then $st0 else {} end) as $st
    | ($st.allocator_tuning // $st.allocator // null) as $al0
    | (if ($al0 | type) == "object" then $al0 else {} end) as $al
    | (if $root.proof_kind != null then $root.proof_kind elif $st.proof_kind != null then $st.proof_kind else null end) as $proof_kind
    | (if $root.duration_secs != null then $root.duration_secs elif $st.duration_secs != null then $st.duration_secs else null end) as $duration
    | (if $root.purge_delay_ms != null then $root.purge_delay_ms elif $st.purge_delay_ms != null then $st.purge_delay_ms elif $al.purge_delay_ms != null then $al.purge_delay_ms else null end) as $purge
    | (if $root.phys_footprint != null then $root.phys_footprint elif $root.phys_footprint_bytes != null then $root.phys_footprint_bytes elif $st.phys_footprint != null then $st.phys_footprint elif $st.phys_footprint_bytes != null then $st.phys_footprint_bytes elif $st.measured_phys_footprint_bytes != null then $st.measured_phys_footprint_bytes else null end) as $phys
    | (if $root.footprint_net != null then $root.footprint_net elif $root.footprint_net_bytes != null then $root.footprint_net_bytes elif $st.footprint_net != null then $st.footprint_net elif $st.footprint_net_bytes != null then $st.footprint_net_bytes else null end) as $net
    | (if $root.p99_phys_footprint != null then $root.p99_phys_footprint elif $root.physical_footprint_p99 != null then $root.physical_footprint_p99 elif $st.p99_phys_footprint != null then $st.p99_phys_footprint elif $st.phys_footprint_p99 != null then $st.phys_footprint_p99 else null end) as $p99
    | (if $root.multiplier != null then $root.multiplier elif $root.implied_multiplier != null then $root.implied_multiplier elif $st.multiplier != null then $st.multiplier elif $st.implied_multiplier != null then $st.implied_multiplier else null end) as $mult
    | (if $root.request_end_collect != null then $root.request_end_collect elif $st.request_end_collect != null then $st.request_end_collect else null end) as $collect
    | (if ($root.steps | type) == "array" then $root.steps elif ($st.steps | type) == "array" then $st.steps else [] end) as $steps
    | (if $root.warm_bytes_freed != null and ($root.footprint_before != null or $root.phys_footprint_before != null) then
        [{warm_bytes_freed: $root.warm_bytes_freed,
          footprint_before: ($root.footprint_before // $root.phys_footprint_before),
          footprint_after: ($root.footprint_after // $root.phys_footprint_after // $phys)}]
      elif $st.warm_bytes_freed != null and ($st.footprint_before != null or $st.phys_footprint_before != null) then
        [{warm_bytes_freed: $st.warm_bytes_freed,
          footprint_before: ($st.footprint_before // $st.phys_footprint_before),
          footprint_after: ($st.footprint_after // $st.phys_footprint_after // $phys)}]
      else [] end) as $extra
    | {
        proof_kind: $proof_kind,
        duration_secs: ($duration | intval),
        purge_delay_ms: ($purge | intval),
        phys_footprint: ($phys | intval),
        footprint_net: ($net | intval),
        p99_phys_footprint: ($p99 | intval),
        multiplier: (if $mult == null then null elif ($mult | type) == "number" then $mult elif ($mult | type) == "string" and ($mult | test("^[0-9]+([.][0-9]+)?$")) then ($mult | tonumber) else "bad" end),
        request_end_collect: $collect,
        steps: (($steps + $extra) | map(step))
      }
  ' "$file" 2>/dev/null)" || {
    printf 'footprint bar RED: status sample is not a JSON object (absent fields fail the bar; not skipped)\n'
    return 1
  }
  proof_kind="$(footprint_bar_field "$canon" 'if .proof_kind == null then "" else (.proof_kind | tostring) end')"
  duration="$(footprint_bar_field "$canon" 'if .duration_secs == null then "" else (.duration_secs | tostring) end')"
  purge="$(footprint_bar_field "$canon" 'if .purge_delay_ms == null then "" else (.purge_delay_ms | tostring) end')"
  phys="$(footprint_bar_field "$canon" 'if .phys_footprint == null then "" else (.phys_footprint | tostring) end')"
  net="$(footprint_bar_field "$canon" 'if .footprint_net == null then "" else (.footprint_net | tostring) end')"
  p99="$(footprint_bar_field "$canon" 'if .p99_phys_footprint == null then "" else (.p99_phys_footprint | tostring) end')"
  multiplier="$(footprint_bar_field "$canon" 'if .multiplier == null then "" else (.multiplier | tostring) end')"
  collect="$(footprint_bar_field "$canon" 'if .request_end_collect == null then "" else (.request_end_collect | tostring) end')"
  [ -n "$net" ] || missing="footprint_net"
  [ -n "$phys" ] || missing="${missing}${missing:+, }phys_footprint"
  [ -n "$purge" ] || missing="${missing}${missing:+, }purge_delay_ms"
  [ -n "$proof_kind" ] || missing="${missing}${missing:+, }proof_kind"
  [ -n "$duration" ] || missing="${missing}${missing:+, }duration_secs"
  [ -n "$p99" ] || missing="${missing}${missing:+, }p99_phys_footprint"
  [ -n "$multiplier" ] || missing="${missing}${missing:+, }multiplier"
  [ -n "$collect" ] || missing="${missing}${missing:+, }request_end_collect"
  if [ -n "$missing" ]; then
    printf 'footprint bar RED: status sample lacks %s (absent fields fail the bar; not skipped)\n' "$missing"
    return 1
  fi
  case "$net$phys$purge$duration$p99" in
    *[!0-9]*)
      printf 'footprint bar RED: a byte or duration field is not an integer (not skipped)\n'
      return 1
      ;;
  esac
  case "$multiplier" in
    ''|*[!0-9.]*)
      printf 'footprint bar RED: multiplier is not a number (not skipped)\n'
      return 1
      ;;
  esac
  expected="$(footprint_bar_proof_kind "$duration")"
  if [ "$proof_kind" != "upgrade-gate" ] || [ "$expected" != "upgrade-gate" ]; then
    if [ "$proof_kind" = "long-memory-candidate" ] || [ "$expected" = "long-memory-candidate" ]; then
      printf 'footprint bar RED: proof_kind=%s duration_secs=%s is the soak, not the upgrade gate (upgrade-gate at %s seconds)\n' \
        "$proof_kind" "$duration" "$FOOTPRINT_BAR_UPGRADE_GATE_SECS"
    else
      printf 'footprint bar RED: proof_kind=%s duration_secs=%s is not upgrade-gate at %s seconds\n' \
        "$proof_kind" "$duration" "$FOOTPRINT_BAR_UPGRADE_GATE_SECS"
    fi
    return 1
  fi
  if [ "$purge" -ne 0 ]; then
    printf 'footprint bar RED: purge_delay_ms=%s (the bar requires 0)\n' "$purge"
    return 1
  fi
  if [ "$collect" != "true" ]; then
    printf 'footprint bar RED: purge slack is not scored after request-end collect (not skipped)\n'
    return 1
  fi
  slack=$((phys - net))
  if [ "$slack" -gt "$FOOTPRINT_BAR_SLACK_MAX_BYTES" ]; then
    printf 'footprint bar RED: purge slack %s bytes is above 512 MiB (%s)\n' \
      "$slack" "$FOOTPRINT_BAR_SLACK_MAX_BYTES"
    return 1
  fi
  nsteps="$(footprint_bar_field "$canon" '.steps | length')"
  case "$nsteps" in
    ''|*[!0-9]*)
      printf 'footprint bar RED: steps is absent (not skipped)\n'
      return 1
      ;;
  esac
  i=0
  freed_steps=0
  while [ "$i" -lt "$nsteps" ]; do
    freed="$(printf '%s' "$canon" | jq -r --argjson i "$i" '.steps[$i].freed | if . == null then "" else tostring end')"
    before="$(printf '%s' "$canon" | jq -r --argjson i "$i" '.steps[$i].before | if . == null then "" else tostring end')"
    after="$(printf '%s' "$canon" | jq -r --argjson i "$i" '.steps[$i].after | if . == null then "" else tostring end')"
    if [ -z "$freed" ] || [ -z "$before" ] || [ -z "$after" ]; then
      printf 'footprint bar RED: a step lacks warm_bytes_freed or phys_footprint before/after (not skipped)\n'
      return 1
    fi
    case "$freed$before$after" in
      *[!0-9]*)
        printf 'footprint bar RED: a step field is not an integer (not skipped)\n'
        return 1
        ;;
    esac
    if [ "$freed" -eq 0 ]; then
      i=$((i + 1))
      continue
    fi
    drop=$((before - after))
    if [ "$drop" -lt 0 ] || [ $((drop * 4)) -lt "$freed" ]; then
      printf 'footprint bar RED: a step freed %s warm bytes but phys_footprint dropped %s (need at least 0.25)\n' \
        "$freed" "$drop"
      return 1
    fi
    freed_steps=$((freed_steps + 1))
    i=$((i + 1))
  done
  if [ "$freed_steps" -lt 1 ]; then
    printf 'footprint bar RED: no step freed warm bytes, so the 0.25 footprint drop is unproven (not skipped)\n'
    return 1
  fi
  # Backstop, not the operating target. physical_footprint_limit: p99 >= 12 GiB.
  if [ "$p99" -ge "$FOOTPRINT_BAR_P99_MAX_BYTES" ]; then
    printf 'footprint bar RED: p99 phys_footprint %s bytes is at or above the 12 GiB backstop\n' "$p99"
    return 1
  fi
  # Backstop, not the operating target. multiplier_limit: implied multiplier >= 1.3.
  if ! awk -v m="$multiplier" 'BEGIN { exit !(m + 0 < 1.3) }'; then
    printf 'footprint bar RED: implied multiplier %s is at or above the 1.3 backstop\n' "$multiplier"
    return 1
  fi
  printf 'footprint bar GREEN: proof_kind=upgrade-gate duration_secs=%s purge_delay_ms=%s slack_bytes=%s drop_ratio_ok=1 p99_backstop=12GiB multiplier_backstop=1.3\n' \
    "$duration" "$purge" "$slack"
  return 0
}
