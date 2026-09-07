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
# No forge/lastgit round-trip in a unit test: inject an empty open-head index.
: >"$fixture/open-heads.tsv"
export LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$fixture/open-heads.tsv"

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

# --- Open change requests protect their worktree (2026-09-07) ----------------
# 2026-09-06: the sweep deleted a clean, hour-old worktree twice while its
# branch had an open CR and then an open PR (`reclaim finished … clean=1`).
# A worktree whose (repo, branch) is the head of an open change request is
# kept; one with no open change request is reclaimed; an unreadable index
# disables the finished-work path instead of reclaiming blind.
git_bin=/usr/bin/git
[ -x "$git_bin" ] || git_bin="$(command -v git)"
prfix="$(mktemp -d "${TMPDIR:-/tmp}/ls-wt-reclaim-pr.XXXXXX")"
trap 'cleanup; rm -rf "$prfix"' EXIT
export WORKTREES_DIR="$prfix/worktrees"
mkdir -p "$WORKTREES_DIR"
mk_wt() { # mk_wt <dirname> <branch>
  local d="$WORKTREES_DIR/$1"
  "$git_bin" init -q -b "$2" "$d"
  "$git_bin" -C "$d" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  # Make the tree old enough for any grace window.
  touch -t 202601010000 "$d"
}
mk_wt open-pr-wt kanban/has-open-pr
mk_wt finished-wt kanban/nothing-open
printf 'open-pr-wt\tkanban/has-open-pr\n' >"$prfix/open-heads.tsv"

# Hermetic: no process-table scan in a unit test. --force-live skips the
# liveness checks the scan feeds, so the finished-work path is reached on the
# index verdict alone; SKIP_LSOF keeps the fixture off ps/lsof entirely.
unset LAST_STACK_RECLAIM_EXTRA_LIVE_PATHS LAST_STACK_RECLAIM_EXTRA_LIVE_EXEC_PATHS
export LAST_STACK_RECLAIM_SKIP_LSOF=1
export LAST_STACK_RECLAIM_SKIP_BOARD=1
export LAST_STACK_RECLAIM_FREE_FLOOR_GIB=0
export LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$prfix/open-heads.tsv"
out="$("$bin" --sweep-stale --force-live --min-age-minutes 0 --max-age-hours 99999 2>&1 || true)"
printf '%s\n' "$out" | grep -E 'open-pr|finished-wt|open-pr index' | head -n 8
if [ ! -d "$WORKTREES_DIR/open-pr-wt" ]; then
  echo "FAIL: worktree with an open change request was reclaimed" >&2; exit 1
fi
printf '%s\n' "$out" | grep -q 'keep open-pr open-pr-wt repo=open-pr-wt branch=kanban/has-open-pr' \
  || { echo "FAIL: the keep must name the repo and branch it matched" >&2; exit 1; }
if [ -d "$WORKTREES_DIR/finished-wt" ]; then
  echo "FAIL: finished worktree with no open change request must still be reclaimed" >&2; exit 1
fi
printf '%s\n' "$out" | grep -q 'kept_open_pr=1 open_pr_index_ok=1' \
  || { echo "FAIL: the done line must count the open-pr keeps" >&2; exit 1; }
echo "ok   open change request keeps its worktree; finished work still goes"

# Unreadable index: fail closed on the finished path (age gate only).
mk_wt finished-wt kanban/nothing-open
export LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$prfix/does-not-exist.tsv"
out="$("$bin" --sweep-stale --force-live --min-age-minutes 0 --max-age-hours 99999 2>&1 || true)"
if [ ! -d "$WORKTREES_DIR/finished-wt" ]; then
  echo "FAIL: with an unreadable open-pr index a clean tree must wait out the age gate" >&2; exit 1
fi
printf '%s\n' "$out" | grep -q 'open-pr index UNREADABLE' \
  || { echo "FAIL: an unreadable index must be logged as such" >&2; exit 1; }
echo "ok   unreadable open-pr index disables the finished-work path"

# The sweep must consult the index before the finished-work reclaim.
keep_line="$(grep -n 'log "keep open-pr' "$bin" | head -1 | cut -d: -f1)"
fin_line="$(grep -n 'log "reclaim finished' "$bin" | head -1 | cut -d: -f1)"
[ -n "$keep_line" ] && [ -n "$fin_line" ] && [ "$keep_line" -lt "$fin_line" ] \
  || { echo "FAIL: open-pr keep must precede the finished-work reclaim (keep=$keep_line fin=$fin_line)" >&2; exit 1; }
echo "PASS last-stack-worktree-reclaim open-pr guard"
