#!/usr/bin/env bash
# host-track-install-lock.sh — the ONE mutex over an app's `current` symlink.
#
# `bin/host-track` has always serialized its own installs with a mkdir-mutex at
# $HOST_TRACK_LOCK_DIR/install-<app>.lock.d. That lock only ever covered
# host-track against host-track. Two OTHER programs in this repo write the same
# `<install_root>/current` symlink and took no lock at all:
#
#   bin/last-stack-class-a-heal      heal_dangling_current: ln -sfn previous current
#   bin/last-stack-safe-activate-cli activate / rollback:  current <- versions/<id>
#
# So the install lock was not a mutex over the pointer, and a writer that read
# `current`, did slow work, and wrote it back could clobber a flip that landed
# in between. Measured 2026-09-26 on EdgeVector/last-stack: `current` went
# BACKWARD to an older version tree 99 seconds after another process activated
# a newer one, `previous` ended up equal to `current` (the shape of "set current
# to previous and leave previous alone"), and the install stamp still named the
# newer tree for 45 minutes.
# papercut-host-track-two-schedulers-race-the-current-symlink-and-one-moves-it-backward-20260926
#
# host-track's own copy of this mutex is NOT refactored to source this file: it
# is the delivery path for everything else on the host, and a sourcing failure
# there cannot be healed by anything that installs. The two implementations must
# agree on the lock DIRECTORY and the lock NAME, and
# tests/host-track-current-writers-share-the-install-lock.sh asserts that they do.
#
# Usage (both functions are no-ops when the caller already holds the lock):
#   . "$ROOT/lib/host-track-install-lock.sh"
#   if ht_install_lock_acquire last-stack 20; then
#     ...  # re-read the pointer HERE; what you read before the wait is stale
#     ht_install_lock_release
#   fi

HT_INSTALL_LOCK_DIR="${HOST_TRACK_LOCK_DIR:-$HOME/.host-track/locks}"
HT_INSTALL_LOCK_STALE_S="${HOST_TRACK_INSTALL_LOCK_STALE_S:-900}"
HT_INSTALL_LOCK_HELD=""

# ht_install_lock_path <app> — the lock this app's writers contend on.
ht_install_lock_path() {
  printf '%s/install-%s.lock.d\n' "${HOST_TRACK_LOCK_DIR:-$HOME/.host-track/locks}" "$1"
}

# ht_install_lock_acquire <app> [wait_s] — 0 acquired, 1 busy. Never dies:
# every caller here has a correct "do nothing this pass" answer, and a heal
# path that aborts on a busy lock is worse than one that waits for the next tick.
ht_install_lock_acquire() {
  local app="$1" wait_s="${2:-20}"
  local lock waited=0 mtime now age lock_pid pid_dead
  lock="$(ht_install_lock_path "$app")"
  # Reentrancy, and it is not hypothetical: `host-track rollback <local-safe
  # app>` takes this exact lock and THEN execs last-stack-safe-activate-cli,
  # which now takes it too. Without this the child waits out the full timeout
  # and rollback dies. The marker names the LOCK PATH, not a boolean, so a
  # parent holding app A's lock cannot let a child skip app B's.
  if [ -n "${HOST_TRACK_INSTALL_LOCK_HELD:-}" ] \
    && [ "$HOST_TRACK_INSTALL_LOCK_HELD" = "$lock" ] && [ -d "$lock" ]; then
    HT_INSTALL_LOCK_HELD=""   # the holder releases it; a child must not
    return 0
  fi
  mkdir -p "$(dirname "$lock")" 2>/dev/null || true
  while ! mkdir "$lock" 2>/dev/null; do
    if [ -d "$lock" ]; then
      if stat --version >/dev/null 2>&1; then
        mtime="$(stat -c %Y "$lock" 2>/dev/null || echo 0)"
      else
        mtime="$(stat -f %m "$lock" 2>/dev/null || echo 0)"
      fi
      now="$(date +%s)"
      age=$((now - mtime))
      # Same reclaim rule as bin/host-track: a LIVE owner keeps the lock for its
      # whole transaction however long that runs (a stage plus probe is minutes),
      # and age alone can only reclaim a lock nobody recorded a pid for.
      lock_pid="$(tr -d '[:space:]' <"$lock/pid" 2>/dev/null || true)"
      pid_dead=0
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        pid_dead=1
      fi
      if [ "$pid_dead" -eq 1 ] \
        || { [ -z "$lock_pid" ] && [ "$age" -ge "$HT_INSTALL_LOCK_STALE_S" ]; }; then
        rm -rf -- "$lock" 2>/dev/null || true
        continue
      fi
    fi
    if [ "$waited" -ge "$wait_s" ]; then
      return 1
    fi
    sleep 1
    waited=$((waited + 1))
  done
  printf '%s\n' "$$" >"$lock/pid" 2>/dev/null || true
  printf '%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$lock/started_at" 2>/dev/null || true
  HT_INSTALL_LOCK_HELD="$lock"
  export HOST_TRACK_INSTALL_LOCK_HELD="$lock"
  return 0
}

ht_install_lock_release() {
  if [ -n "${HT_INSTALL_LOCK_HELD:-}" ] && [ -d "$HT_INSTALL_LOCK_HELD" ]; then
    rm -rf -- "$HT_INSTALL_LOCK_HELD" 2>/dev/null || true
    unset HOST_TRACK_INSTALL_LOCK_HELD
  fi
  HT_INSTALL_LOCK_HELD=""
}

# ht_symlink_swap <target> <link> — replace a symlink with no window in which
# the link is ABSENT. `rm -f "$link"; mv tmp "$link"` leaves a gap that a
# concurrent watcher reads as a dangling/missing pointer and "heals".
ht_symlink_swap() {
  local target="$1" link="$2" tmp
  mkdir -p "$(dirname "$link")"
  tmp="${link}.tmp-$$-$(date +%s)"
  rm -f "$tmp"
  ln -s "$target" "$tmp"
  if mv -f -h "$tmp" "$link" 2>/dev/null; then
    return 0
  fi
  if mv -fT "$tmp" "$link" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}
