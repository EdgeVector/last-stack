#!/usr/bin/env bash
# papercut-disk-reclaim-process-inspection-denied-20260921
#
# The scheduled disk-reclaim sandbox denies /bin/ps (setuid) and pgrep, but
# `lsof -u <uid>` still works. A working lsof is a real process view: the
# sweep must NOT fall into liveness_unavailable / liveness_soft, must keep a
# tree whose cwd holds a build tool or whose executable image runs from it,
# and must still reclaim an idle finished tree.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-worktree-reclaim"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ls-wt-lsof.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
WT="$(cd "$tmp" && pwd -P)/worktrees"
mkdir -p "$WT"

mk_clean_wt() {
  local d="$WT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  touch -t 202001010000 "$d"
}
mk_clean_wt build-wt
mk_clean_wt exec-wt
mk_clean_wt idle-wt

fake="$tmp/fakebin"
mkdir -p "$fake"
cat >"$fake/ps" <<'SH'
#!/bin/sh
echo "execvp() of '/bin/ps' failed: Operation not permitted" >&2
exit 1
SH
cat >"$fake/pgrep" <<'SH'
#!/bin/sh
echo "pgrep: Cannot get process list" >&2
exit 3
SH
cat >"$fake/lsof" <<SH
#!/bin/sh
case "\$*" in
  *"-d cwd"*)
    printf 'p101\ncargo\nfcwd\nn$WT/build-wt\n'
    printf 'p102\nczsh\nfcwd\nn/\n'
    ;;
  *"-d txt"*)
    printf 'p103\ncapp\nftxt\nn$WT/exec-wt/target/release/app\n'
    printf 'p102\nczsh\nftxt\nn/bin/zsh\n'
    ;;
esac
SH
chmod +x "$fake/ps" "$fake/pgrep" "$fake/lsof"
: >"$tmp/open-heads.tsv"

out="$(PATH="$fake:$PATH" HOME="$tmp" WORKTREES_DIR="$WT" \
  LAST_STACK_RECLAIM_SKIP_BOARD=1 LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$tmp/open-heads.tsv" \
  LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches" \
  "$bin" --sweep-stale --max-age-hours 999999 --dry-run 2>&1)" || {
  echo "FAIL: sweep exited non-zero: $out" >&2; exit 1; }

fail() { echo "FAIL: $*" >&2; printf '%s\n' "$out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'ps_unavailable fallback=lsof' || fail "no ps_unavailable fallback=lsof log"
printf '%s\n' "$out" | grep -q 'liveness_unavailable=0' || fail "liveness must stay available with a working lsof"
printf '%s\n' "$out" | grep -q 'liveness_soft=0' || fail "liveness must not soft-degrade with a working lsof"
printf '%s\n' "$out" | grep -q 'keep protected build-wt' || fail "build tool cwd tree was not kept"
printf '%s\n' "$out" | grep -q 'keep protected exec-wt' || fail "exec image tree was not kept"
printf '%s\n' "$out" | grep -q 'reclaim finished idle-wt' || fail "idle tree was not reclaimed"

# Both instruments denied still fails closed (no board -> nothing removed).
cat >"$fake/lsof" <<'SH'
#!/bin/sh
exit 1
SH
out="$(PATH="$fake:$PATH" HOME="$tmp" WORKTREES_DIR="$WT" \
  LAST_STACK_RECLAIM_SKIP_BOARD=1 LAST_STACK_RECLAIM_OPEN_HEADS_FILE="$tmp/open-heads.tsv" \
  LAST_STACK_WORKTREE_PATCH_DIR="$tmp/patches" \
  "$bin" --sweep-stale --max-age-hours 999999 --dry-run 2>&1)" || true
if printf '%s\n' "$out" | grep -q 'reclaim finished idle-wt'; then
  fail "with lsof AND ps denied and no board, nothing may be reclaimed"
fi

echo "ok last-stack-worktree-reclaim-lsof-fallback"
