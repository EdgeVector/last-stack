#!/usr/bin/env bash
# Synthetic probe-data helpers for lastdb-safe-upgrade.
# Sourced by safe-upgrade-lastdb.sh and build-synthetic-home.sh.
# No side effects at source.
#
# The probes run on a SYNTHETIC home (a "seed"). They never copy Tom's primary
# home (Tom, 2026-10-12: decision-2026-10-12-never-run-copies-of-primary-database-
# use-synthetic-data). The seed is written by the BASELINE daemon (the binary the
# primary runs), so the candidate must read what the installed daemon wrote.
# One seed is cached per key. The key covers everything that changes what the
# seed holds: the baseline bytes, the identity, the live tuning flags, the app
# versions that register schemas, the data sizes, and the generator version.
#
# bash 3.2 compatible (macOS /bin/bash). No nested functions.

# Bump when build-synthetic-home.sh writes different data.
SYNTH_GENERATOR_VERSION="3"
# 10 cards give a todo list of 10 and 8 records give the brain reads data. That is
# enough for the keyed-read, row-count and latency bars. One complete batch
# waits for durable persistence. The seed is cached per key, so most runs
# build nothing.
SYNTH_DEFAULT_CARDS=10
SYNTH_DEFAULT_RECORDS=8

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

# $1 = data mode. The driver accepts exactly one: synthetic. There is no mode
# that copies the primary home (Tom, 2026-10-12).
synth_data_mode_valid() {
  case "${1:-}" in
    synthetic) return 0 ;;
    *) return 1 ;;
  esac
}

# $1 = a count. A positive integer of at most 64 for one complete seed batch.
synth_count_valid() {
  case "${1:-}" in
    ''|*[!0-9]*|0|0[0-9]*) return 1 ;;
  esac
  [ "${#1}" -le 2 ] && [ "$1" -le 64 ]
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
  dir="$(CDPATH='' cd -- "$(dirname -- "$path")" && pwd -P)" || return 1
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
  [ ! -L "$dir/.complete" ] && [ ! -L "$dir/seed.meta" ] || return 1
  [ "$(synth_meta_value "$dir/seed.meta" key)" = "$key" ] || return 1
  [ "$(synth_meta_value "$dir/seed.meta" generator)" = "$SYNTH_GENERATOR_VERSION" ] || return 1
  [ "$(synth_meta_value "$dir/seed.meta" known_keys_verified)" = true ] || return 1
  [ "$(synth_meta_value "$dir/seed.meta" shutdown_flush_verified)" = true ] || return 1
  synth_owned_directory "$dir" || return 1
  jq -e --arg meta "$(synth_sha256_file "$dir/seed.meta")" '
    (keys | sort) == (["version","seed_meta_sha256","known_keys_verified","shutdown_flush_verified"] | sort)
    and .version == 1 and .seed_meta_sha256 == $meta
    and .known_keys_verified == true and .shutdown_flush_verified == true
  ' "$dir/.complete" >/dev/null || return 1
  [ -f "$dir/home/identity.key" ] && [ ! -L "$dir/home/identity.key" ] || return 1
  [ -d "$dir/home/data" ] && [ ! -L "$dir/home/data" ] || return 1
  [ -d "$dir/cli-home" ] && [ ! -L "$dir/cli-home" ] || return 1
  synth_owned_directory "$dir/home" && synth_owned_directory "$dir/cli-home" || return 1
  cards="$(synth_meta_value "$dir/seed.meta" cards)"
  case "$cards" in ''|*[!0-9]*|0) return 1 ;; esac
  return 0
}

# Exact owner-only container guard; it never changes a foreign directory.
synth_owned_directory() {
  local path="${1:-}" owner mode
  [ -d "$path" ] && [ ! -L "$path" ] || return 1
  if stat --version >/dev/null 2>&1; then
    owner="$(stat -c %u "$path")" && mode="$(stat -c %a "$path")" || return 1
  else
    owner="$(stat -f %u "$path")" && mode="$(stat -f %Lp "$path")" || return 1
  fi
  [ "$owner" = "$(id -u)" ] && [ "$mode" = 700 ]
}

# A marker grants no cleanup by itself. The operator closes every consumer
# and uses the normal exact-home route only after this driver exits.
synth_mark_trial_owner() {
  local dir="${1:-}" dev ino marker
  synth_owned_directory "$dir" || return 1
  marker="$dir/.synthetic-seed-owner.json"
  [ ! -e "$marker" ] && [ ! -L "$marker" ] || return 1
  if stat --version >/dev/null 2>&1; then
    dev="$(stat -c %d "$dir")" && ino="$(stat -c %i "$dir")" || return 1
  else
    dev="$(stat -f %d "$dir")" && ino="$(stat -f %i "$dir")" || return 1
  fi
  (umask 077; set -C
    jq -n --argjson uid "$(id -u)" --argjson dev "$dev" --argjson ino "$ino" --argjson pid "$$" \
      '{version:1,kind:"synthetic-trial",owner_uid:$uid,device:$dev,inode:$ino,creator_pid:$pid}' >"$marker"
  )
}

# Where seeds live. The driver and the warm-up script must agree, or a warm
# seed is never found. Same rule as the driver's probe WORK dir: a TMPDIR under
# HOME, or one longer than 12 bytes, is too deep for the node's Unix socket, so
# the base becomes /tmp. LASTDB_SYNTHETIC_SEED_ROOT overrides.
synth_seed_root_default() {
  local base="${TMPDIR:-/tmp}" base_real home_real
  home_real="$(CDPATH='' cd -- "$HOME" 2>/dev/null && pwd -P)" || home_real="$HOME"
  base_real="$(CDPATH='' cd -- "$base" 2>/dev/null && pwd -P)" || base_real="$base"
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
# A cache hit builds nothing. An incomplete or foreign path refuses. No seed
# or build is removed here. The operator releases exact containers only after
# all PROBE, CUTOVER and recovery consumers close (see the skill).
synth_seed_ensure() (
  local root="${1:-}" key="${2:-}" dir build rc=0 lock token nonce
  shift 2 || return 1
  synth_seed_key_valid "$key" || return 1
  case "$root" in /?*) ;; *) return 1 ;; esac
  [ "$root" != "/" ] || return 1
  [ ! -L "$root" ] || return 1
  if [ ! -e "$root" ]; then (umask 077; mkdir "$root") || return 1; fi
  synth_owned_directory "$root" || return 1
  root="$(CDPATH='' cd -- "$root" && pwd -P)" || return 1
  lock="$root/.seed-$key.lock"
  token="$$.$RANDOM.$RANDOM"
  (umask 077; mkdir "$lock") || return 1
  printf '%s\n' "$token" >"$lock/owner" || return 1
  # Remove only this invocation's empty coordination lock, never a data home.
  trap '[ ! -L "$lock" ] && [ "$(cat "$lock/owner" 2>/dev/null)" = "$token" ] && { rm -- "$lock/owner"; rmdir "$lock"; }' EXIT
  dir="$root/$key"
  if synth_seed_is_complete "$dir" "$key"; then
    printf '%s\n' "$dir"
    return 0
  fi
  [ ! -e "$dir" ] && [ ! -L "$dir" ] || return 1
  nonce="$(uuidgen | tr 'A-Z' 'a-z')" || return 1
  # Keep the path short enough for the native macOS Unix socket.
  build="$root/.build-${key:0:8}-${nonce%%-*}"
  [ ! -e "$build" ] && [ ! -L "$build" ] || return 1
  "$@" --out "$build" --key "$key" >&2 || rc=$?
  if [ "$rc" -ne 0 ]; then
    printf '[synthetic-home] retained failed owned build: %s\n' "$build" >&2
    return 1
  fi
  [ ! -e "$dir" ] && [ ! -L "$dir" ] || return 1
  synth_seed_is_complete "$build" "$key" || return 1
  mv "$build" "$dir" || return 1
  # A builder that exits 0 but leaves a half seed must not serve a probe.
  if ! synth_seed_is_complete "$dir" "$key"; then
    return 1
  fi
  printf '%s\n' "$dir"
)
