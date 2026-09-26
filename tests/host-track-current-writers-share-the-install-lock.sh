#!/usr/bin/env bash
# Every program in this repo that writes <install_root>/current must contend on
# ONE lock, and must re-read the pointer after it gets that lock.
#
# Until 2026-09-26 bin/host-track's install lock covered host-track against
# host-track only. bin/last-stack-class-a-heal and bin/last-stack-safe-activate-cli
# wrote the same symlink with no lock, so a writer that read `current`, did slow
# work and wrote it back could clobber a flip that landed in between. Measured
# that day on EdgeVector/last-stack: `current` went backward to an older version
# tree 99s after another process activated a newer one, `previous` ended up
# equal to `current`, and the install stamp named the newer tree for 45 minutes.
# papercut-host-track-two-schedulers-race-the-current-symlink-and-one-moves-it-backward-20260926
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ht-lock.XXXXXX")"
holder_pid=""
cleanup() {
  [ -z "$holder_pid" ] || kill "$holder_pid" 2>/dev/null || true
  rm -rf -- "$tmp"
}
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

# ---------------------------------------------------------------------------
# 1. Structural: the two implementations must name the SAME lock.
# bin/host-track keeps its own copy on purpose (it is the delivery path for
# everything else and cannot depend on a sourced file), so nothing but this
# check stops the two from drifting onto different directories, at which point
# there are two locks and therefore none.
# ---------------------------------------------------------------------------
grep -q 'HOST_TRACK_LOCK_DIR:-\$HOME/\.host-track/locks' "$ROOT/bin/host-track" \
  || fail "bin/host-track no longer defaults HOST_TRACK_LOCK_DIR to ~/.host-track/locks"
grep -q 'HOST_TRACK_LOCK_DIR:-\$HOME/\.host-track/locks' "$ROOT/lib/host-track-install-lock.sh" \
  || fail "lib/host-track-install-lock.sh no longer defaults HOST_TRACK_LOCK_DIR to ~/.host-track/locks"
grep -q 'install-\${app}\.lock\.d' "$ROOT/bin/host-track" \
  || fail "bin/host-track no longer names its lock install-<app>.lock.d"
grep -q "install-%s\.lock\.d" "$ROOT/lib/host-track-install-lock.sh" \
  || fail "lib/host-track-install-lock.sh no longer names its lock install-<app>.lock.d"
pass "host-track and the shared helper contend on the same lock path"

# ---------------------------------------------------------------------------
# 2. Both unlocked writers now take the lock.
# ---------------------------------------------------------------------------
grep -q 'ht_install_lock_acquire' "$ROOT/bin/last-stack-class-a-heal" \
  || fail "class-a-heal writes current without acquiring the install lock"
grep -q 'take_install_lock' "$ROOT/bin/last-stack-safe-activate-cli" \
  || fail "safe-activate-cli writes current without acquiring the install lock"
pass "class-a-heal and safe-activate-cli acquire the install lock"

# class-a-heal cannot REFUSE to heal because a sourced file is missing: $ROOT
# resolves through `current`, which is the pointer it repairs. It falls back to
# a bare mkdir mutex, and that fallback must name the same lock, or there are
# two locks and therefore none.
grep -q 'HOST_TRACK_LOCK_DIR:-\$HOME/\.host-track/locks}/install-\${1}\.lock\.d' \
  "$ROOT/bin/last-stack-class-a-heal" \
  || fail "class-a-heal's inline lock fallback does not name \$HOST_TRACK_LOCK_DIR/install-<app>.lock.d"
pass "the inline lock fallback contends on the same lock path"

# ---------------------------------------------------------------------------
# 3. safe-activate-cli must never unlink a pointer before replacing it.
# `rm -f "$link"; mv tmp "$link"` leaves a window in which `current` is ABSENT,
# which is precisely the state class-a-heal watches for and "heals".
# ---------------------------------------------------------------------------
# Strip comments first: this very file's explanation of the defect contains the
# defective line, and a guard that matches prose certifies nothing.
if awk '/^atomic_symlink\(\)/,/^}/' "$ROOT/bin/last-stack-safe-activate-cli" \
  | sed 's/[[:space:]]*#.*$//' \
  | grep -q 'rm -f "\$link"'; then
  fail "safe-activate-cli atomic_symlink still unlinks the pointer before replacing it"
fi
pass "safe-activate-cli replaces a pointer without unlinking it first"

# ---------------------------------------------------------------------------
# Behavioural fixture. An isolated HOME, a live lock holder, and a dangling
# `current` that class-a-heal would otherwise repoint onto `previous`.
# ---------------------------------------------------------------------------
export HOME="$tmp/home"
export HOST_TRACK_LOCK_DIR="$HOME/.host-track/locks"
export LAST_STACK_ARTIFACT_ROOT="$HOME/artifacts"
export LASTSTACK_CLASS_A_STATE_DIR="$tmp/state"
export LASTSTACK_CLASS_A_HT_APP="demo"
export LASTSTACK_CLASS_A_HT_LOCK_WAIT_S=2
export LAST_STACK_HEARTBEATS_FILE="$tmp/heartbeats.log"
mkdir -p "$HOME/.local/bin" "$HOST_TRACK_LOCK_DIR" "$LASTSTACK_CLASS_A_STATE_DIR"
mkdir -p "$LAST_STACK_ARTIFACT_ROOT/versions/old" "$LAST_STACK_ARTIFACT_ROOT/versions/new"

# A version tree only counts as live when it carries a real install marker.
seed_tree() {
  mkdir -p "$1/bin"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$1/bin/host-track"
  chmod +x "$1/bin/host-track"
}
seed_tree "$LAST_STACK_ARTIFACT_ROOT/versions/old"
seed_tree "$LAST_STACK_ARTIFACT_ROOT/versions/new"

ln -sfn versions/old "$LAST_STACK_ARTIFACT_ROOT/previous"
# `current` points at a tree that is not there: the restage window.
ln -sfn versions/gone "$LAST_STACK_ARTIFACT_ROOT/current"

# Source the heal script's function under test without running its main body.
# It is a single file with a main body, so drive it as a program instead and
# read what it did to the pointer.
run_heal() {
  ( set +e
    "$ROOT/bin/last-stack-class-a-heal" --reason=test >"$tmp/heal.out" 2>"$tmp/heal.err"
    printf '%s\n' "$?" >"$tmp/heal.rc" )
}

hold_lock() {
  # A LIVE owner: the reclaim rule in both implementations keeps the lock for a
  # live pid however old it is, so this must be a real running process.
  local lock="$HOST_TRACK_LOCK_DIR/install-demo.lock.d"
  mkdir -p "$lock"
  sleep 120 &
  holder_pid=$!
  printf '%s\n' "$holder_pid" >"$lock/pid"
}

release_lock() {
  [ -z "$holder_pid" ] || kill "$holder_pid" 2>/dev/null || true
  holder_pid=""
  rm -rf -- "$HOST_TRACK_LOCK_DIR/install-demo.lock.d"
}

# --- 4. Lock held by a live install => the pointer is NOT written. ----------
hold_lock
run_heal
if [ "$(readlink "$LAST_STACK_ARTIFACT_ROOT/current")" != "versions/gone" ]; then
  fail "class-a-heal repointed current while another process held the install lock"
fi
grep -q 'install lock busy' "$tmp/heal.err" \
  || fail "class-a-heal did not say it was deferring on a busy install lock (got: $(cat "$tmp/heal.err"))"
pass "a busy install lock defers the repoint instead of clobbering the pointer"
release_lock

# Same, with the helper made unreachable: the fallback must defer too.
hold_lock
ln -sfn versions/gone "$LAST_STACK_ARTIFACT_ROOT/current"
heal_copy="$tmp/nolib/bin/last-stack-class-a-heal"
mkdir -p "$tmp/nolib/bin"
cp "$ROOT/bin/last-stack-class-a-heal" "$heal_copy"
chmod +x "$heal_copy"
( set +e; "$heal_copy" --reason=test >"$tmp/heal2.out" 2>"$tmp/heal2.err" ) || true
if [ "$(readlink "$LAST_STACK_ARTIFACT_ROOT/current")" != "versions/gone" ]; then
  fail "class-a-heal without its lock helper repointed current under a held lock"
fi
grep -q 'bare mkdir mutex' "$tmp/heal2.err" \
  || fail "class-a-heal did not fall back to the inline mutex (got: $(cat "$tmp/heal2.err"))"
pass "the inline fallback defers on a held lock just like the helper"
release_lock

# --- 5. Re-read under the lock: current recovered while we waited. ---------
# The install finished between the pre-lock read and the lock being granted.
# Nothing may be written: the tree on `current` is the one the installer chose.
ln -sfn versions/gone "$LAST_STACK_ARTIFACT_ROOT/current"
cat >"$tmp/racer.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
lock="$HOST_TRACK_LOCK_DIR/install-demo.lock.d"
mkdir -p "$lock"
printf '%s\n' "$$" >"$lock/pid"
sleep 3
ln -sfn versions/new "$LAST_STACK_ARTIFACT_ROOT/current"
rm -rf -- "$lock"
SH
chmod +x "$tmp/racer.sh"
LASTSTACK_CLASS_A_HT_LOCK_WAIT_S=20 "$tmp/racer.sh" &
racer_pid=$!
sleep 1
LASTSTACK_CLASS_A_HT_LOCK_WAIT_S=20 run_heal
wait "$racer_pid" 2>/dev/null || true
if [ "$(readlink "$LAST_STACK_ARTIFACT_ROOT/current")" != "versions/new" ]; then
  fail "class-a-heal clobbered a pointer an install had already fixed (current=$(readlink "$LAST_STACK_ARTIFACT_ROOT/current"))"
fi
pass "a pointer that recovered while waiting for the lock is left alone"

# --- 6. Free lock, still dangling => the repoint still happens. ------------
# The guard must not have turned the heal off; it must only have made it wait.
ln -sfn versions/gone "$LAST_STACK_ARTIFACT_ROOT/current"
run_heal
if [ "$(readlink "$LAST_STACK_ARTIFACT_ROOT/current")" != "versions/old" ]; then
  fail "class-a-heal stopped repointing a genuinely dangling current (current=$(readlink "$LAST_STACK_ARTIFACT_ROOT/current"))"
fi
pass "a genuinely dangling current is still repointed onto previous"


# ---------------------------------------------------------------------------
# 7. Reentrancy. `host-track rollback <local-safe app>` takes this lock and THEN
# execs last-stack-safe-activate-cli, which now takes it too. A child that does
# not honour the parent's marker waits out the whole timeout and the rollback
# dies -- a deadlock introduced by the fix itself.
# ---------------------------------------------------------------------------
grep -q 'export HOST_TRACK_INSTALL_LOCK_HELD' "$ROOT/bin/host-track" \
  || fail "bin/host-track no longer publishes the lock it holds to its children"

reentrancy_rc=0
( set +e
  . "$ROOT/lib/host-track-install-lock.sh"
  lock="$HOST_TRACK_LOCK_DIR/install-demo.lock.d"
  mkdir -p "$lock"
  printf '%s\n' "$$" >"$lock/pid"
  export HOST_TRACK_INSTALL_LOCK_HELD="$lock"
  # The child must proceed immediately, not wait. The ceiling is the wait
  # budget this call configures: anything at or above it means the carve-out
  # did not fire and the child sat in the acquire loop.
  reentrancy_wait_s=5
  start="$(date +%s)"
  ht_install_lock_acquire demo "$reentrancy_wait_s"
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  rm -rf -- "$lock"
  [ "$rc" -eq 0 ] || exit 21
  [ "$elapsed" -lt "$reentrancy_wait_s" ] || exit 22
  # A parent holding app A's lock must NOT let a child skip app B's.
  other="$HOST_TRACK_LOCK_DIR/install-other.lock.d"
  mkdir -p "$other"
  sleep 60 &
  printf '%s\n' "$!" >"$other/pid"
  export HOST_TRACK_INSTALL_LOCK_HELD="$lock"
  ht_install_lock_acquire other 2
  rc2=$?
  kill "$(cat "$other/pid")" 2>/dev/null || true
  rm -rf -- "$other"
  [ "$rc2" -eq 1 ] || exit 23
  exit 0 ) && reentrancy_rc=0 || reentrancy_rc=$?
case "$reentrancy_rc" in
  0) ;;
  21) fail "a child did not honour the lock its parent already holds" ;;
  22) fail "a child waited for a lock its parent already holds" ;;
  23) fail "a parent's lock on one app let a child skip another app's lock" ;;
  *) fail "reentrancy check errored" ;;
esac
pass "a child honours its parent's lock, and only for the same app"

printf 'PASS %s\n' "$(basename "$0")"
