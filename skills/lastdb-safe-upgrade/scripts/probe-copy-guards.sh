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

# The separate real-data smoke copy exercises the copy-only stamp builder.
# Timed latency copies and the key-cap copy receive no stamp work. An older
# baseline can ignore this flag without bias. The primary never receives it.
# $1 is the label.
probe_stamp_env_for_label() {
  case "${1:-}" in
    smoke) printf '%s\n' 'LASTDB_BUILD_CONFLICT_STAMP_ON_COPY=1' ;;
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

# Clone one entry with the same platform choice as the existing probe copies.
probe_clone_entry() {
  local source="$1" destination="$2"
  if stat --version >/dev/null 2>&1; then
    cp -R "$source" "$destination"
  else
    cp -cR "$source" "$destination"
  fi
}

# Refuse a link at any part of the excluded path. A copied link could let a
# candidate follow the probe path back into the live Search files.
probe_receipt_chain_is_safe() {
  local path="$1" component
  shift
  for component in "$@"; do
    path="$path/$component"
    [ ! -L "$path" ] || return 1
    [ -d "$path" ] || return 0
  done
}

# Copy a directory one level at a time along one fixed path. Siblings use
# clonefile on macOS. The final selected directory is never traversed. Return
# 1 for a copy error after all siblings have been tried; 2 for an unsafe path.
probe_clone_except_child() {
  local source="$1" destination="$2" selected="$3" entry mode rc=0 child_rc
  shift 3
  mkdir -m 700 "$destination" || return 2
  for entry in "$source"/*; do
    if [ "${entry##*/}" = "$selected" ]; then
      [ ! -L "$entry" ] || return 2
      if [ -d "$entry" ]; then
        if [ "$#" -gt 0 ]; then
          if probe_clone_except_child "$entry" "$destination/$selected" "$@"; then
            :
          else
            child_rc=$?
            [ "$child_rc" -ne 2 ] || return 2
            rc=1
          fi
        fi
        # The last path component is apps/search/inbox/done. Skip it before cp.
        continue
      fi
    fi
    probe_clone_entry "$entry" "$destination/" || rc=1
  done
  if stat --version >/dev/null 2>&1; then
    mode="$(stat -c '%a' "$source")" || return 2
  else
    mode="$(stat -f '%Lp' "$source")" || return 2
  fi
  chmod "$mode" "$destination" || return 2
  return "$rc"
}

# $1 = primary home, $2 = new temporary probe home. Keep every source path
# except the unrelated Search receipt output directory. Never change source.
# Return 1 for a tolerated copy error, 2 for an unsafe path or structure.
probe_clone_home_without_search_receipts() (
  local source="$1" destination="$2" rc=0
  probe_copy_is_not_primary "$destination" "$source" || return 2
  [ -d "$source" ] && [ ! -L "$source" ] || return 2
  [ ! -e "$destination" ] && [ ! -L "$destination" ] || return 2
  probe_receipt_chain_is_safe "$source" apps search inbox 'done' || return 2
  umask 077
  shopt -s dotglob nullglob
  probe_clone_except_child "$source" "$destination" apps search inbox 'done' || rc=$?
  [ "$rc" -ne 2 ] || return 2
  probe_receipt_chain_is_safe "$destination" apps search inbox 'done' || return 2
  chmod 700 "$destination" || return 2
  return "$rc"
)

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
