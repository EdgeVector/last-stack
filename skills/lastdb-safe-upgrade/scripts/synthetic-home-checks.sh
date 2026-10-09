#!/usr/bin/env bash
# Synthetic probe-data helpers for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh, build-synthetic-home.sh and unit tests.
# No side effects at source.
#
# The probes run on a SYNTHETIC home (a "seed") instead of a clone of Tom's
# primary home. The seed is written by the BASELINE daemon (the binary the
# primary runs), so the candidate must read what the installed daemon wrote.
# One seed is cached per key. The key covers everything that changes what the
# seed holds: the baseline bytes, the identity, the live tuning flags, the app
# versions that register schemas, the data sizes, and the generator version.
#
# bash 3.2 compatible (macOS /bin/bash). No nested functions.

# Bump when build-synthetic-home.sh writes different data.
SYNTH_GENERATOR_VERSION="1"
# 120 cards give a todo list of 72, enough that a list touches well over the
# key-cap bar's 100 logical records. Each write waits for a durable persist, so
# a larger seed makes a cold build slow (about 7 s per card on a loaded host).
SYNTH_DEFAULT_CARDS=120
SYNTH_DEFAULT_RECORDS=20

# Live flags the baseline must NOT carry while it writes the seed. They are
# timing policy, not layout, so the on-disk format is the same without them.
# LASTDB_RESIDENT_MODE=write acknowledges a write before it persists. On a
# fresh home under the primary flags the persist lanes never drained (measured
# 2026-10-09, lastdbd 0.23.3-2693): a running node listed 1 of 12 new cards, and
# a graceful stop took 111 to 132 s, logged "queued writes are at risk", wrote no
# flush receipt, and lost the last cards. The probe copies still boot with the
# full live flags, so the candidate and the baseline run in write mode when they
# read the seed. The deferral window has no meaning without write mode.
SYNTH_WRITE_OMIT_KEYS="LASTDB_RESIDENT_MODE LASTDB_RESIDENT_MAX_DEFERRED_BYTES"

# Reads KEY=VAL lines on stdin. Prints the lines whose key the seed build may
# carry. A key is dropped only when it equals an omitted key exactly.
synth_filter_write_env() {
  local line key omit skip
  while IFS= read -r line || [ -n "$line" ]; do
    [ -n "$line" ] || continue
    key="${line%%=*}"
    skip=0
    for omit in $SYNTH_WRITE_OMIT_KEYS; do
      [ "$key" != "$omit" ] || skip=1
    done
    [ "$skip" -eq 1 ] || printf '%s\n' "$line"
  done
}

# $1 = data mode. The driver accepts exactly these two.
synth_data_mode_valid() {
  case "${1:-}" in
    synthetic|real) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a count. A positive integer of at most 100000.
synth_count_valid() {
  case "${1:-}" in
    ''|*[!0-9]*|0|0[0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 6 ] && [ "$1" -le 100000 ]
}

# $1 = card count. Prints how many of cards 1..N the builder places in todo.
# Card n goes to todo when n mod 20 is 0 to 11, to backlog for 12 to 14, and to
# done for 15 to 19. A full block of 20 holds 12 todo cards. A partial block of
# r cards (n mod 20 = 1..r) holds min(r, 11).
synth_expected_todo() {
  local n="${1:-}" full rem
  synth_count_valid "$n" || return 1
  full=$((n / 20))
  rem=$((n % 20))
  [ "$rem" -le 11 ] || rem=11
  printf '%s\n' $((full * 12 + rem))
}

# $1 = written, $2 = requested, $3 = minimum percent. Integer math only.
synth_write_ratio_ok() {
  local ok="${1:-}" total="${2:-}" pct="${3:-}"
  case "$ok" in ''|*[!0-9]*) return 1 ;; esac
  case "$total" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$pct" in ''|*[!0-9]*) return 1 ;; esac
  [ $((ok * 100)) -ge $((total * pct)) ]
}

# $1 = file. Prints the lowercase hex SHA-256, or fails.
synth_sha256_file() {
  [ -f "${1:-}" ] || return 1
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# Reads stdin. Prints the lowercase hex SHA-256.
synth_sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# $1 = a command name or path. Prints a token that changes when the installed
# app changes: the versioned directory name from a host-track style path, or
# else the SHA-256 of the resolved file. Fails when the command is not found.
synth_app_token() {
  local cmd="${1:-}" path hop=0 target dir leaf token
  [ -n "$cmd" ] || return 1
  case "$cmd" in
    */*) path="$cmd" ;;
    *) path="$(command -v "$cmd" 2>/dev/null)" || return 1 ;;
  esac
  [ -e "$path" ] || return 1
  while [ -L "$path" ] && [ "$hop" -lt 10 ]; do
    target="$(readlink "$path")" || return 1
    case "$target" in
      /*) path="$target" ;;
      *) path="$(dirname -- "$path")/$target" ;;
    esac
    hop=$((hop + 1))
  done
  [ ! -L "$path" ] && [ -f "$path" ] || return 1
  dir="$(CDPATH= cd -- "$(dirname -- "$path")" && pwd -P)" || return 1
  leaf="$(basename -- "$path")"
  path="$dir/$leaf"
  case "$path" in
    */versions/*)
      token="${path#*/versions/}"
      token="${token%%/*}"
      [ -n "$token" ] && { printf 'v:%s\n' "$token"; return 0; }
      ;;
  esac
  token="$(synth_sha256_file "$path")" || return 1
  printf 'sha:%s\n' "$token"
}

# $1 = baseline daemon, $2 = identity file, $3 = live env pairs (newline list),
# $4 = cards, $5 = records, $6 = kanban token, $7 = brain token.
# Prints a 20 hex character key. The identity file contributes only through its
# SHA-256, mixed with every other input; no key bytes are printed.
synth_seed_key() {
  local bin="${1:-}" ident="${2:-}" envs="${3-}" cards="${4:-}" recs="${5:-}" kt="${6:-}" bt="${7:-}"
  local bsha isha digest
  bsha="$(synth_sha256_file "$bin")" || return 1
  isha="$(synth_sha256_file "$ident")" || return 1
  [ -n "$cards" ] && [ -n "$recs" ] && [ -n "$kt" ] && [ -n "$bt" ] || return 1
  digest="$(
    {
      printf 'generator=%s\n' "$SYNTH_GENERATOR_VERSION"
      printf 'baseline=%s\n' "$bsha"
      printf 'identity=%s\n' "$isha"
      printf 'cards=%s\n' "$cards"
      printf 'records=%s\n' "$recs"
      printf 'kanban=%s\n' "$kt"
      printf 'brain=%s\n' "$bt"
      printf '%s\n' "$envs" | LC_ALL=C sort
    } | synth_sha256_stdin
  )" || return 1
  [ -n "$digest" ] || return 1
  printf '%s\n' "${digest%"${digest#????????????????????}"}"
}

# $1 = a seed key. Exactly 20 lowercase hex characters.
synth_seed_key_valid() {
  case "${1:-}" in
    *[!0-9a-f]*|'') return 1 ;;
  esac
  [ "${#1}" -eq 20 ]
}

# $1 = seed.meta, $2 = key name. Prints the first value, or nothing.
synth_meta_value() {
  [ -f "${1:-}" ] || return 0
  sed -n "s/^${2}=//p" "$1" 2>/dev/null | head -1
}

# $1 = seed dir, $2 = expected key. A seed is usable only when the builder
# finished: .complete exists, seed.meta carries the same key, the home holds an
# identity and a data dir, the CLI home exists, and the card count is positive.
synth_seed_is_complete() {
  local dir="${1:-}" key="${2:-}" cards
  synth_seed_key_valid "$key" || return 1
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -f "$dir/.complete" ] || return 1
  [ "$(synth_meta_value "$dir/seed.meta" key)" = "$key" ] || return 1
  [ -f "$dir/home/identity.key" ] && [ ! -L "$dir/home/identity.key" ] || return 1
  [ -d "$dir/home/data" ] && [ ! -L "$dir/home/data" ] || return 1
  [ -d "$dir/cli-home" ] && [ ! -L "$dir/cli-home" ] || return 1
  cards="$(synth_meta_value "$dir/seed.meta" cards)"
  case "$cards" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

# $1 = seed root, $2 = path. Remove one direct child of the root and nothing
# else. A link is removed as a link and never followed.
synth_rm_seed_child() {
  local root="${1:-}" path="${2:-}"
  case "$root" in /?*) ;; *) return 1 ;; esac
  [ "$root" != "/" ] || return 1
  [ -n "$path" ] || return 1
  [ "$(dirname -- "$path")" = "$root" ] || return 1
  if [ -L "$path" ]; then
    rm -f -- "$path"
    return $?
  fi
  [ -e "$path" ] || return 0
  rm -rf -- "$path"
}

# $1 = seed root, $2 = key to keep. Remove every other seed and every stale
# build directory. Only direct children of the root are touched.
synth_seed_reclaim_others() {
  local root="${1:-}" keep="${2:-}" d base n=0
  [ -d "$root" ] && [ ! -L "$root" ] || return 0
  for d in "$root"/* "$root"/.build-*; do
    [ -e "$d" ] || [ -L "$d" ] || continue
    base="$(basename -- "$d")"
    case "$base" in
      "$keep") continue ;;
      .build-*) ;;
      *[!0-9a-f]*) continue ;;
      *) [ "${#base}" -eq 20 ] || continue ;;
    esac
    synth_rm_seed_child "$root" "$d" && n=$((n + 1))
  done
  printf '%s\n' "$n"
}

# Where seeds live. The driver and the warm-up script must agree, or a warm
# seed is never found. Same rule as the driver's probe WORK dir: a TMPDIR under
# HOME, or one longer than 12 bytes, is too deep for the node's Unix socket, so
# the base becomes /tmp. LASTDB_SYNTHETIC_SEED_ROOT overrides.
synth_seed_root_default() {
  local base="${TMPDIR:-/tmp}" base_real home_real
  home_real="$(CDPATH= cd -- "$HOME" 2>/dev/null && pwd -P)" || home_real="$HOME"
  base_real="$(CDPATH= cd -- "$base" 2>/dev/null && pwd -P)" || base_real="$base"
  case "$base_real" in
    "$home_real"|"$home_real"/*) base=/tmp ;;
  esac
  [ "${#base}" -le 12 ] || base=/tmp
  printf '%s\n' "${LASTDB_SYNTHETIC_SEED_ROOT:-$base/lastdb-safe-upgrade-synthetic-$(id -u)}"
}

# $1 = baseline daemon, $2 = primary home, $3 = LaunchAgent plist (may be empty),
# $4 = cards, $5 = records. Prints the seed key for the installed apps.
# Needs live_lastdb_env_pairs (live-lastdb-env.sh). Exit 2: no kanban CLI;
# exit 3: no brain CLI; exit 1: any other input is unusable.
synth_seed_key_for() {
  local baseline="${1:-}" primary="${2:-}" plist="${3-}" cards="${4:-}" recs="${5:-}" kt bt envs
  kt="$(synth_app_token kanban)" || return 2
  bt="$(synth_app_token brain)" || return 3
  envs="$(live_lastdb_env_pairs "$plist")"
  synth_seed_key "$baseline" "$primary/identity.key" "$envs" "$cards" "$recs" "$kt" "$bt"
}

# $1 = seed root, $2 = key, rest = the builder command. The builder gets
# --out DIR --key KEY appended. Prints the seed dir. Builder output goes to
# stderr so a caller can capture the dir with $(...).
# A cache hit builds nothing. Anything incomplete or mismatched is removed
# first, so a half-built seed never serves a probe.
synth_seed_ensure() {
  local root="${1:-}" key="${2:-}" dir build rc=0
  shift 2 || return 1
  synth_seed_key_valid "$key" || return 1
  case "$root" in /?*) ;; *) return 1 ;; esac
  [ "$root" != "/" ] || return 1
  [ ! -L "$root" ] || return 1
  mkdir -p "$root" || return 1
  chmod 700 "$root" || return 1
  dir="$root/$key"
  if synth_seed_is_complete "$dir" "$key"; then
    printf '%s\n' "$dir"
    return 0
  fi
  synth_rm_seed_child "$root" "$dir" || return 1
  build="$root/.build-$$"
  synth_rm_seed_child "$root" "$build" || return 1
  "$@" --out "$build" --key "$key" >&2 || rc=$?
  if [ "$rc" -ne 0 ]; then
    synth_rm_seed_child "$root" "$build" || true
    return 1
  fi
  # Another builder (the post-cutover warm-up) may have finished this key while
  # this one ran. Keep the complete seed; do not nest this build inside it.
  if synth_seed_is_complete "$dir" "$key"; then
    synth_rm_seed_child "$root" "$build" || true
    printf '%s\n' "$dir"
    return 0
  fi
  mv "$build" "$dir" || { synth_rm_seed_child "$root" "$build" || true; return 1; }
  # A builder that exits 0 but leaves a half seed must not serve a probe.
  if ! synth_seed_is_complete "$dir" "$key"; then
    synth_rm_seed_child "$root" "$dir" || true
    return 1
  fi
  printf '%s\n' "$dir"
}
