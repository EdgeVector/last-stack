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

# The one path, relative to the home, that a PROBE copy leaves out.
#
# apps/search/inbox/done holds the Search app's processed batches (215,628
# files on 2026-10-08). The daemon only writes the Search inbox. It never reads
# done/. A probe boots the daemon and the CLIs, never the Search app, so nothing
# on a probe reads done/. One APFS clone of it took about 13 minutes and one
# removal about 8 minutes
# (papercut-safe-upgrade-probes-copy-search-receipts-20261007).
#
# The rollback point (step 1), the DEV photograph copy and the stopped-home
# backup copy do NOT use this list. done/ is the replay source of
# `search bootstrap`, so a copy that can restore the primary keeps it.
probe_copy_excluded_path() {
  printf '%s\n' 'apps/search/inbox/done'
}

# $1 = path. Print its permission bits in octal (BSD or GNU stat).
probe_clone_mode_of() {
  if stat --version >/dev/null 2>&1; then
    stat -c '%a' "$1"
  else
    stat -f '%Lp' "$1"
  fi
}

# $1 = source path, $2 = destination (must not exist). One clone of one entry.
# The exit code is ignored on purpose: a live socket under data/ cannot be
# copied and makes cp exit non-zero. The caller checks the copy is complete.
probe_clone_entry() {
  if stat --version >/dev/null 2>&1; then
    cp -R "$1" "$2" 2>/dev/null || true
  else
    cp -cR "$1" "$2" 2>/dev/null || true
  fi
}

# $1 = source dir, $2 = destination dir (created), $3 = path of $1 relative to
# the home ("" for the home), $4 = relative path to leave out.
# Clone every entry of $1 except $4. A directory on the way to $4 is created and
# filled one level at a time. Every other entry is one clone. A symlink on the
# way to $4 is copied as a link and never followed, so nothing outside the home
# is read through it.
probe_clone_dir_without() {
  local src="$1" dst="$2" rel="$3" skip="$4" entry name child_rel mode
  mode="$(probe_clone_mode_of "$src")" || mode=""
  mkdir "$dst" || return 1
  for entry in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    if [ ! -e "$entry" ] && [ ! -L "$entry" ]; then
      continue
    fi
    name="${entry##*/}"
    if [ -n "$rel" ]; then
      child_rel="$rel/$name"
    else
      child_rel="$name"
    fi
    if [ "$child_rel" = "$skip" ]; then
      continue
    fi
    case "$skip" in
      "$child_rel"/*)
        if [ -d "$entry" ] && [ ! -L "$entry" ]; then
          probe_clone_dir_without "$entry" "$dst/$name" "$child_rel" "$skip" \
            || return 1
          continue
        fi
        ;;
    esac
    probe_clone_entry "$entry" "$dst/$name"
  done
  if [ -n "$mode" ]; then
    chmod "$mode" "$dst" || return 1
  fi
}

# $1 = primary home, $2 = probe copy (must not exist). Clone the home for a
# probe, without probe_copy_excluded_path. Each top-level entry is its own
# clone, so the entries are not one point in time; data/ is still one clone.
# LASTDB_PROBE_COPY_FULL=1 clones everything (the behaviour before 2026-10-08),
# to reproduce a problem on a full copy. Returns non-zero when the copy cannot
# start; the caller still checks identity.key and data/ afterwards.
probe_clone_home() {
  local src="$1" dst="$2"
  if [ ! -d "$src" ] || [ -e "$dst" ] || [ -L "$dst" ]; then
    return 1
  fi
  probe_copy_is_not_primary "$dst" "$src" || return 1
  if [ "${LASTDB_PROBE_COPY_FULL:-0}" = "1" ]; then
    probe_clone_entry "$src" "$dst"
    return 0
  fi
  probe_clone_dir_without "$src" "$dst" "" "$(probe_copy_excluded_path)"
}
