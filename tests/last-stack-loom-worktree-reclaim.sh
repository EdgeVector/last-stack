#!/usr/bin/env bash
# Regression cover for last-stack-loom-worktree-reclaim.
#
# Every keep case runs in the same sweep as eligible siblings that MUST be
# removed, so a guard that swallows everything fails the test.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="$ROOT/bin/last-stack-loom-worktree-reclaim"

tmp="$(mktemp -d "${TMPDIR:-/tmp}/loom-wt-reclaim-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

repo="$tmp/repo"
wts="$tmp/worktrees"
mkdir -p "$repo" "$wts"
git -C "$repo" init -q -b main
git -C "$repo" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

old() { touch -t 202001010000 "$1"; }
mk() {
  git -C "$repo" worktree add -q --detach "$wts/$1#IMPLEMENT" main
  : >"$wts/$1#IMPLEMENT.loom-guard"
  mkdir -p "$wts/$1#IMPLEMENT/target"
}

mk lx-succeeded-old;  old "$wts/lx-succeeded-old#IMPLEMENT"
mk lx-cancelled-old;  old "$wts/lx-cancelled-old#IMPLEMENT"
mk lx-failed-old
echo dirty >"$wts/lx-failed-old#IMPLEMENT/wip.txt"
old "$wts/lx-failed-old#IMPLEMENT"
mk lx-succeeded-young
mk lx-failed-young
mk lx-running-old;    old "$wts/lx-running-old#IMPLEMENT"
mk lx-unreadable-old; old "$wts/lx-unreadable-old#IMPLEMENT"
mk lx-succeeded-live; old "$wts/lx-succeeded-live#IMPLEMENT"

stub="$tmp/stub"
mkdir -p "$stub"
cat >"$stub/loom" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  lx-succeeded-*) echo "status: succeeded" ;;
  lx-cancelled-*) echo "status: cancelled" ;;
  lx-failed-*) echo "status: failed" ;;
  lx-running-*) echo "status: running" ;;
  *) echo "no such execution" >&2; exit 1 ;;
esac
EOF
cat >"$stub/lsof" <<EOF
#!/usr/bin/env bash
printf 'p1\nn/\np2\nn$(cd "$wts" && pwd -P)/lx-succeeded-live#IMPLEMENT/sub\n'
EOF
cat >"$stub/lsof-broken" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$stub"/*

run() {
  LOOM_WORKTREES_DIR="$wts" LOOM_BIN="$stub/loom" \
    LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches" "$bin" "$@"
}

fail() { echo "FAIL: $*"; exit 1; }
gone() { [ ! -e "$wts/$1#IMPLEMENT" ] || fail "$1 should be removed"; [ ! -e "$wts/$1#IMPLEMENT.loom-guard" ] || fail "$1 guard should be removed"; }
kept() { [ -d "$wts/$1#IMPLEMENT" ] || fail "$1 should be kept"; }

# lsof fails: fail closed, nothing removed.
out="$(LAST_STACK_LOOM_RECLAIM_LSOF="$stub/lsof-broken" run)"
echo "$out" | grep -q 'loom_wt_reclaimed=0 .*loom_wt_liveness_unavailable=1' || fail "fail-closed tokens: $out"
kept lx-succeeded-old

# Dry run: nothing removed.
LAST_STACK_LOOM_RECLAIM_LSOF="$stub/lsof" run --dry-run >/dev/null
kept lx-succeeded-old

out="$(LAST_STACK_LOOM_RECLAIM_LSOF="$stub/lsof" run)"
echo "$out" | tail -n 1 | grep -q 'loom_wt_seen=8 loom_wt_reclaimed=3 loom_wt_kept=5' || fail "tokens: $out"
gone lx-succeeded-old
gone lx-cancelled-old
gone lx-failed-old
kept lx-succeeded-young
kept lx-failed-young
kept lx-running-old
kept lx-unreadable-old
kept lx-succeeded-live
ls "$tmp/patches"/loom-lx-failed-old_IMPLEMENT-*.patch >/dev/null 2>&1 || fail "dirty patch not saved"
git -C "$repo" worktree list | grep -q 'lx-succeeded-old' && fail "git still lists a removed worktree"

echo "ok last-stack-loom-worktree-reclaim"

# --- Active CI owner race: IMPLEMENT is terminal but REPAIR sibling is live -------
# 2026-09-25: disk reclaim removed an IMPLEMENT worktree while a corresponding
# REPAIR step was running in a sibling worktree. The reclaim checked liveness by
# process cwd/cmd on each tree individually, but didn't check if a sibling step
# was live. Now we check for live sibling steps before reclaiming.
tmp2="$(mktemp -d "${TMPDIR:-/tmp}/loom-wt-active-owner.XXXXXX")"
trap 'rm -rf "$tmp" "$tmp2"' EXIT

repo2="$tmp2/repo"
wts2="$tmp2/worktrees"
mkdir -p "$repo2" "$wts2"
git -C "$repo2" init -q -b main
git -C "$repo2" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init

mk2() {
  git -C "$repo2" worktree add -q --detach "$wts2/$1#$2" main
  : >"$wts2/$1#$2.loom-guard"
  mkdir -p "$wts2/$1#$2/target"
  touch "$wts2/$1#$2/target/KEEP_ME"
}

# Terminal IMPLEMENT, but active REPAIR sibling
mk2 lx-with-repair IMPLEMENT
old "$wts2/lx-with-repair#IMPLEMENT"
mk2 lx-with-repair REPAIR
old "$wts2/lx-with-repair#REPAIR"  # Make REPAIR old too so it passes age check

# Purely terminal (both steps terminal)
mk2 lx-no-repair IMPLEMENT
old "$wts2/lx-no-repair#IMPLEMENT"

# Start a process in the REPAIR worktree to make it "live"
(
  cd "$wts2/lx-with-repair#REPAIR"
  exec sleep 600
) &
repair_pid=$!

# lsof stub that includes the live REPAIR worktree
cat >"$stub/lsof-with-repair" <<EOF
#!/usr/bin/env bash
printf 'p1\nn/\np2\nn$(cd "$wts2" && pwd -P)/lx-with-repair#REPAIR\n'
EOF
chmod +x "$stub/lsof-with-repair"

# Add loom stub response for REPAIR step
cat >"$stub/loom" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  lx-with-repair|lx-no-repair)
    echo "status: succeeded"
    ;;
  *)
    echo "no such execution" >&2
    exit 1
    ;;
esac
EOF

run2() {
  LOOM_WORKTREES_DIR="$wts2" LOOM_BIN="$stub/loom" \
    LAST_STACK_WORKTREE_PATCH_DIR="$tmp2/patches" "$bin" "$@"
}

# Give kernel a moment to register the cwd
sleep 0.3

out2="$(LAST_STACK_LOOM_RECLAIM_LSOF="$stub/lsof-with-repair" run2)"
kill "$repair_pid" 2>/dev/null || true
wait "$repair_pid" 2>/dev/null || true

# lx-with-repair#IMPLEMENT must be kept because lx-with-repair#REPAIR is live
[ -d "$wts2/lx-with-repair#IMPLEMENT" ] || fail "IMPLEMENT worktree removed while active REPAIR sibling exists: $out2"
[ -d "$wts2/lx-with-repair#REPAIR" ] || fail "active REPAIR worktree should exist"
# lx-no-repair#IMPLEMENT must be removed (no active repair)
[ ! -d "$wts2/lx-no-repair#IMPLEMENT" ] || fail "purely terminal IMPLEMENT should be reclaimed: $out2"
echo "ok active CI owner keeps terminal worktree"
