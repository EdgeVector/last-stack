#!/usr/bin/env bash
# Probe-copy guards for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and unit tests. No side effects at source.
#
# A probe node runs on an APFS clone of the primary home. These helpers keep
# that clone, and the conflict-stamp flag it may carry, away from the primary.
#
# bash 3.2 compatible (macOS /bin/bash). No nested functions.

# $1 = where (ephemeral-copy|primary), $2 = LASTDB_BUILD_CONFLICT_STAMP_ON_COPY.
# The flag may be 1 on the ephemeral copy only. The primary must not carry it.
probe_stamp_env_allowed() {
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

# The separate key-cap copy exercises the copy-only stamp builder. Timed
# latency copies receive no stamp work, including with an older baseline that
# ignores this flag. The live primary never receives it. $1 is the label.
probe_stamp_env_for_label() {
  case "${1:-}" in
    key-cap) printf '%s\n' 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1' ;;
    *) printf '\n' ;;
  esac
}

# $1 = plist. Prints the primary stamp flag, or an empty line when unset.
probe_plist_stamp_value() {
  local plist="${1:-}" val=""
  if [ -z "$plist" ] || [ ! -f "$plist" ]; then
    printf '\n'
    return 0
  fi
  val="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:LASTDB_BUILD_CONFLICT_STAMP_ON_COPY' "$plist" 2>/dev/null || true)"
  printf '%s\n' "$val"
}

# Print the physical path of $1.
# A symlink leaf fails. The caller must not follow it into the primary home.
# A missing leaf resolves through its real parent, so a path can be checked
# before cp creates it. A trailing slash does not change the result.
probe_physical_path() {
  local path="$1" parent base parent_real
  [ -n "$path" ] || return 1
  if [ -L "$path" ]; then
    return 1
  fi
  if [ -d "$path" ]; then
    (CDPATH= cd -- "$path" && pwd -P) || return 1
    return 0
  fi
  parent="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [ -L "$parent" ]; then
    parent="$(CDPATH= cd -- "$parent" && pwd -P)" || return 1
  fi
  if [ ! -d "$parent" ]; then
    return 1
  fi
  parent_real="$(CDPATH= cd -- "$parent" && pwd -P)" || return 1
  case "$base" in
    ''|.) printf '%s\n' "$parent_real" ;;
    ..) (CDPATH= cd -- "$parent_real/.." && pwd -P) || return 1 ;;
    *)
      parent_real="${parent_real%/}"
      printf '%s/%s\n' "$parent_real" "$base"
      ;;
  esac
}

# $1 = copy path, $2 = primary home. Fail when the copy is the primary home,
# lives inside it, or contains it. A symlink copy fails. Paths are compared
# after pwd -P, so a trailing slash does not hide a child.
probe_copy_is_not_primary() {
  local copy="$1" primary="$2" copy_real primary_real
  [ -n "$copy" ] && [ -n "$primary" ] || return 1
  if [ -L "$copy" ]; then
    return 1
  fi
  copy_real="$(probe_physical_path "$copy")" || return 1
  if [ -L "$primary" ]; then
    primary_real="$(CDPATH= cd -- "$primary" && pwd -P)" || return 1
  else
    primary_real="$(probe_physical_path "$primary")" || return 1
  fi
  copy_real="${copy_real%/}"
  primary_real="${primary_real%/}"
  [ -n "$copy_real" ] || copy_real="/"
  [ -n "$primary_real" ] || primary_real="/"
  [ "$copy_real" != "$primary_real" ] || return 1
  case "$copy_real" in
    "$primary_real"/*) return 1 ;;
  esac
  case "$primary_real" in
    "$copy_real"/*) return 1 ;;
  esac
  return 0
}

# $1 = probe copy, $2 = primary home. Remove all copied production cloud
# credentials and resume intent before any candidate process can boot.
probe_strip_cloud_state() {
  local copy="$1" primary="$2" path
  probe_copy_is_not_primary "$copy" "$primary" || return 1
  [ -d "$copy" ] && [ ! -L "$copy" ] || return 1
  for path in \
    "$copy"/cloud_sync.json* \
    "$copy"/.cloud_sync.json.tmp* \
    "$copy"/.cloud_resume_required \
    "$copy"/.cloud_resume_requested \
    "$copy"/.cloud_resume_ready; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      [ ! -d "$path" ] || return 1
      rm -f -- "$path" || return 1
    fi
  done
  for path in \
    "$copy"/cloud_sync.json* \
    "$copy"/.cloud_sync.json.tmp* \
    "$copy"/.cloud_resume_required \
    "$copy"/.cloud_resume_requested \
    "$copy"/.cloud_resume_ready; do
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
  done
}
