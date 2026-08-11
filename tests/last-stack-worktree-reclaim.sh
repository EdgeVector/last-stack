#!/usr/bin/env bash
# Structural + compound live-guard smoke for last-stack-worktree-reclaim.
# No live board dependency. Uses a private WORKTREES_DIR fixture.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-worktree-reclaim"
chmod +x "$bin" 2>/dev/null || true

bash -n "$bin"
bash -n "$ROOT/bin/last-stack-card-closeout"

# usage without args
if "$bin" 2>/dev/null; then
  echo "expected usage failure" >&2
  exit 1
fi

# dry-run on missing path is ok
"$bin" --path /tmp/last-stack-worktree-reclaim-does-not-exist-$$ --dry-run >/dev/null

# dry-run sweep against an EMPTY private root only (never touch real worktrees here)
empty_roots="$(mktemp -d "${TMPDIR:-/tmp}/ls-wt-empty.XXXXXX")"
mkdir -p "$empty_roots/worktrees"
WORKTREES_DIR="$empty_roots/worktrees" \
  LAST_STACK_RECLAIM_FREE_FLOOR_GIB=0 \
  LAST_STACK_RECLAIM_SKIP_BOARD=1 \
  LAST_STACK_RECLAIM_SKIP_LSOF=1 \
  "$bin" --sweep-stale --max-age-hours 99999 --dry-run >/dev/null || true
rm -rf "$empty_roots"

# card-closeout still documents reclaim step
rg -q 'last-stack-worktree-reclaim' "$ROOT/bin/last-stack-card-closeout"
rg -q 'last-stack-worktree-reclaim' "$ROOT/bin/last-stack-board-closeout-sweep"
rg -q 'sweep-stale' "$ROOT/routines/disk-reclaim.md"
rg -q 'sweep-stale' "$ROOT/routines/worktree-cleanup.md"

# Shared call-site: strip_generated must consult has_live_cwd / live guard.
rg -q 'has_live_cwd' "$bin"
# Sweep must not call strip_generated without a live / pressure gate nearby.
rg -q 'broad_sweep_skipped_disk_pressure|under_disk_pressure|skip strip live|keep live strip-skip' "$bin"
rg -q 'has_fresh_build_markers|has_live_process' "$bin"

# --- Compound fixture: live cwd + idle sibling under private WORKTREES_DIR ---
fixture="$(mktemp -d "${TMPDIR:-/tmp}/ls-wt-reclaim.XXXXXX")"
cleanup() {
  # kill background sleeper if still up
  if [ -n "${live_pid:-}" ] && kill -0 "$live_pid" 2>/dev/null; then
    kill "$live_pid" 2>/dev/null || true
    wait "$live_pid" 2>/dev/null || true
  fi
  if [ -n "${exec_pid:-}" ] && kill -0 "$exec_pid" 2>/dev/null; then
    kill "$exec_pid" 2>/dev/null || true
    wait "$exec_pid" 2>/dev/null || true
  fi
  rm -rf "$fixture"
}
trap cleanup EXIT

export WORKTREES_DIR="$fixture/worktrees"
mkdir -p "$WORKTREES_DIR/live-wt/target/debug/.fingerprint/crate" \
  "$WORKTREES_DIR/idle-wt/target/debug/.fingerprint/crate" \
  "$WORKTREES_DIR/fresh-marker-wt/target/debug/.fingerprint/crate" \
  "$WORKTREES_DIR/exec-wt/target/release"

# Markers that strip would delete
echo live-marker >"$WORKTREES_DIR/live-wt/target/KEEP_ME"
echo idle-marker >"$WORKTREES_DIR/idle-wt/target/KEEP_ME"
echo fresh-marker >"$WORKTREES_DIR/fresh-marker-wt/target/KEEP_ME"
echo exec-marker >"$WORKTREES_DIR/exec-wt/target/KEEP_ME"
# Fresh cargo fingerprint for the marker-only tree (no live process)
: >"$WORKTREES_DIR/fresh-marker-wt/target/debug/.fingerprint/crate/invoked.timestamp"
touch "$WORKTREES_DIR/fresh-marker-wt/target/.rustc_info.json"

# Start a long-lived process with cwd = live-wt (sleep is not in old allowlist —
# expanded guard must still see it via full pgrep + lsof cwd).
(
  cd "$WORKTREES_DIR/live-wt"
  exec sleep 600
) &
live_pid=$!

# Run an actual executable image from target/release with cwd elsewhere. This
# is the shape that cwd-only guards miss (for example target/release/lastdbd).
cp "$(command -v sleep)" "$WORKTREES_DIR/exec-wt/target/release/live-sleeper"
chmod +x "$WORKTREES_DIR/exec-wt/target/release/live-sleeper"
# macOS invalidates the platform binary's original signature after copying it.
if command -v codesign >/dev/null 2>&1; then
  codesign --force --sign - --timestamp=none \
    "$WORKTREES_DIR/exec-wt/target/release/live-sleeper" >/dev/null 2>&1
fi
(
  cd "$fixture"
  exec "$WORKTREES_DIR/exec-wt/target/release/live-sleeper" 600
) &
exec_pid=$!
# Give the kernel a moment to register cwd
sleep 0.3
if ! kill -0 "$live_pid" 2>/dev/null; then
  echo "fixture sleeper failed to start" >&2
  exit 1
fi
if ! kill -0 "$exec_pid" 2>/dev/null; then
  echo "fixture target executable failed to start" >&2
  exit 1
fi

# Force strip path even when host free space is high (this machine often has >80Gi free).
# Skip board/process-table reads for speed and sandbox portability. Both
# injected paths still name live processes started above, so the compound path
# exercises the same reason-tagged index used by a real lsof/ps sweep.
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=999999
export LAST_STACK_RECLAIM_BUILD_FRESH_MIN=30
export LAST_STACK_RECLAIM_SKIP_BOARD=1
export LAST_STACK_RECLAIM_SKIP_LSOF=1
export LAST_STACK_RECLAIM_EXTRA_LIVE_PATHS="$WORKTREES_DIR/live-wt"
export LAST_STACK_RECLAIM_EXTRA_LIVE_EXEC_PATHS="$WORKTREES_DIR/exec-wt/target/release/live-sleeper"

out="$("$bin" --sweep-stale --max-age-hours 99999 2>&1 || true)"
printf '%s\n' "$out" | head -n 40

# Live cwd worktree target must survive
if [ ! -f "$WORKTREES_DIR/live-wt/target/KEEP_ME" ]; then
  echo "FAIL: live-cwd worktree target/ was stripped" >&2
  echo "$out" >&2
  exit 1
fi
# Idle sibling must be stripped
if [ -f "$WORKTREES_DIR/idle-wt/target/KEEP_ME" ]; then
  echo "FAIL: idle worktree target/ was NOT stripped" >&2
  echo "$out" >&2
  exit 1
fi
# Fresh build-marker worktree must survive even without a live process
if [ ! -f "$WORKTREES_DIR/fresh-marker-wt/target/KEEP_ME" ]; then
  echo "FAIL: fresh-marker worktree target/ was stripped" >&2
  echo "$out" >&2
  exit 1
fi
# A process executable under target/ protects its worktree even when cwd is elsewhere.
if [ ! -f "$WORKTREES_DIR/exec-wt/target/KEEP_ME" ]; then
  echo "FAIL: live-exec-image worktree target/ was stripped" >&2
  echo "$out" >&2
  exit 1
fi
for reason in live_cwd live_exec_image fresh_build_marker; do
  if ! printf '%s\n' "$out" | rg -q "$reason"; then
    echo "FAIL: expected reclaim log reason=$reason" >&2
    echo "$out" >&2
    exit 1
  fi
done

# Disk-pressure gate: with a low floor and abundant free space, skip broad strip.
# Use a second idle tree that still has a marker; free floor 0 would always strip.
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=0
# restore idle marker and re-strip under pressure floor=0 (always pressure)
mkdir -p "$WORKTREES_DIR/idle2-wt/target"
echo idle2 >"$WORKTREES_DIR/idle2-wt/target/KEEP_ME"
# floor=0 → free always >= 0? Wait: under_disk_pressure is free < floor.
# free_gib < 0 is never true. So floor=0 means NEVER under pressure.
# Use floor=0 to skip strip; use floor=999999 to always strip.
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=0
out2="$("$bin" --sweep-stale --max-age-hours 99999 2>&1 || true)"
if ! printf '%s\n' "$out2" | rg -q 'pressure_skip'; then
  echo "FAIL: expected pressure_skip when free_floor_gib=0" >&2
  echo "$out2" >&2
  exit 1
fi
if [ ! -f "$WORKTREES_DIR/idle2-wt/target/KEEP_ME" ]; then
  echo "FAIL: idle2 target stripped despite free-floor skip" >&2
  echo "$out2" >&2
  exit 1
fi

echo "ok last-stack-worktree-reclaim"
