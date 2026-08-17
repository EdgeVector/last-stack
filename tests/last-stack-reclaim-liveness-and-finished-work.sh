#!/usr/bin/env bash
# Regression cover for three defects that together made the hourly
# last-stack-disk-reclaim routine reclaim ~nothing while the worktree pool grew
# unbounded (2026-08-15: 75 worktrees / 7.0 GB, 64 of them finished scan trees).
#
#   1. liveness fails OPEN — build_live_index swallowed lsof/ps failures with
#      `2>/dev/null || true`, leaving an EMPTY index that is indistinguishable
#      from an idle machine. Under a sandbox denying ps/lsof (observed in the
#      routine heartbeats as ps_denied=1 / ps_unavailable=sandbox) every
#      worktree classified as idle. Only the 48h age gate stood between that
#      and deleting live work.
#   2. doing_slugs never returned anything — `... --json | python3 - <<'PY'`
#      lets the heredoc override the pipe, so json.load(sys.stdin) read an
#      exhausted stream and the bare `except: sys.exit(0)` hid it. The
#      doing-card protect set was empty on every run (shellcheck SC2259).
#   3. finished work waited out --max-age-hours before becoming reclaimable, so
#      a generator producing ~10 worktrees/hour kept the whole population
#      permanently "young" and the sweep never caught up.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bin="${LAST_STACK_RECLAIM_BIN:-$ROOT/bin/last-stack-worktree-reclaim}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

WT="$tmp/worktrees"
mkdir -p "$WT"

# A finished worktree: clean git tree, nothing running, older than the grace.
mk_clean_wt() {
  # Split the declarations: bash 3.2 (macOS system bash) evaluates the whole
  # `local a=… b=…` list before binding, so referencing $name there trips set -u.
  local name
  local d
  name="$1"
  d="$WT/$name"
  mkdir -p "$d"
  git -C "$d" init -q 2>/dev/null
  git -C "$d" config user.email t@e.com
  git -C "$d" config user.name t
  echo hi >"$d/f.txt"
  git -C "$d" add -A
  git -C "$d" commit -qm init
  # age it past the default 60m grace
  touch -t 202001010000 "$d"
}

mk_clean_wt finished-a
mk_clean_wt finished-b

# LAST_STACK_RECLAIM_SKIP_LSOF=1 is the helper's documented test escape hatch:
# it skips the bulk lsof AND its instrument verification, so liveness reads as
# available. That is required here — CI itself runs in a sandbox where lsof is
# denied (`liveness_probe_failed instrument=lsof rows=0`), which correctly
# trips the new fail-closed path and would make every "was it reclaimed?"
# assertion below fail for a reason unrelated to what it tests. The fail-closed
# behaviour gets its own section further down, where the probe runs for real.
run() {
  HOME="$tmp" WORKTREES_DIR="$WT" \
    LAST_STACK_RECLAIM_SKIP_BOARD=1 LAST_STACK_RECLAIM_SKIP_LSOF=1 "$@"
}

# ---------------------------------------------------------------- 3. finished
# Finished work must be reclaimed WITHOUT waiting out --max-age-hours.
out="$(run "$bin" --sweep-stale --max-age-hours 999999 --dry-run 2>&1 || true)"
if ! printf '%s' "$out" | grep -q 'reclaim finished finished-a'; then
  echo "FAIL: clean idle worktree not reclaimed under a huge --max-age-hours" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# ...but a worktree inside the grace window is never touched.
mk_clean_wt fresh-one
touch "$WT/fresh-one"
out="$(run "$bin" --sweep-stale --max-age-hours 999999 --dry-run 2>&1 || true)"
if ! printf '%s' "$out" | grep -q 'keep fresh fresh-one'; then
  echo "FAIL: worktree inside the min-age grace was not kept" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# ---------------------------------------------------------------- 1. liveness
# Hard-closed: lsof denied AND no real board protect set (SKIP_BOARD) must
# refuse to remove ANYTHING and exit non-zero.
# NOTE: deliberately does NOT set SKIP_LSOF — the probe must run for real here.
# A host that already denies lsof (CI does) reaches the same state without the
# shim, so this assertion holds in both environments.
shim="$tmp/shim"
mkdir -p "$shim"
printf '#!/bin/sh\nexit 1\n' >"$shim/lsof"
chmod +x "$shim/lsof"

set +e
out="$(PATH="$shim:$PATH" HOME="$tmp" WORKTREES_DIR="$WT" \
  LAST_STACK_RECLAIM_SKIP_BOARD=1 \
  "$bin" --sweep-stale --max-age-hours 0 2>&1)"
rc=$?
set -e

if [ "$rc" -eq 0 ]; then
  echo "FAIL: hard-blind run (lsof denied, no board) exited 0 — a no-op must not report success" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q 'liveness_unavailable=1'; then
  echo "FAIL: hard-blind run did not report liveness_unavailable=1" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if printf '%s' "$out" | grep -q 'liveness_soft=1'; then
  echo "FAIL: hard-blind run (no board) must not soft-degrade" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if printf '%s' "$out" | grep -qE '^last-stack-worktree-reclaim: (remove|reclaim finished)'; then
  echo "FAIL: hard-blind run removed a worktree despite being unable to prove it idle" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
# The trees must still be there.
if [ ! -d "$WT/finished-a" ]; then
  echo "FAIL: hard-blind run deleted finished-a" >&2
  exit 1
fi

# Soft-degrade: same denied lsof, but a real board protect set is present.
# Unprotected finished worktrees must still reclaim; doing-card trees must not.
fakebin_soft="$tmp/fakebin-soft"
mkdir -p "$fakebin_soft"
cat >"$fakebin_soft/kanban" <<'FAKE'
#!/bin/sh
printf '{"cards":[{"slug":"doing-keep-me"}]}\n'
FAKE
chmod +x "$fakebin_soft/kanban"
mk_clean_wt doing-keep-me-wt
# dir name must contain the doing slug for protect matching
rm -rf "$WT/doing-keep-me-wt"
mk_clean_wt "repo-doing-keep-me"

set +e
out="$(PATH="$fakebin_soft:$shim:$PATH" HOME="$tmp" WORKTREES_DIR="$WT" \
  "$bin" --sweep-stale --max-age-hours 999999 --dry-run 2>&1)"
rc=$?
set -e

if [ "$rc" -ne 0 ]; then
  echo "FAIL: soft-degrade run (lsof denied + board ok) exited $rc — should exit 0" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q 'liveness_soft=1'; then
  echo "FAIL: soft-degrade run did not report liveness_soft=1" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q 'reclaim finished finished-a'; then
  echo "FAIL: soft-degrade did not reclaim unprotected finished-a" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
if ! printf '%s' "$out" | grep -q 'keep protected repo-doing-keep-me'; then
  echo "FAIL: soft-degrade did not protect doing-card worktree" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

# ------------------------------------------------------------- 2. doing_slugs
# The defect is reading the board from STDIN while a heredoc also owns stdin.
# Passing the program on stdin and the DATA as a file argument is fine, so
# assert on the actual failure: the board must never be json.load-ed off stdin.
if grep -v '^[[:space:]]*#' "$bin" | grep -q 'json.load(sys.stdin)'; then
  echo "FAIL: doing_slugs still reads the board JSON from stdin (heredoc clobbers it, SC2259)" >&2
  exit 1
fi

# And it must genuinely emit slugs when the board answers. Feed a fake CLI.
fakebin="$tmp/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/kanban" <<'FAKE'
#!/bin/sh
printf '{"cards":[{"slug":"alpha-card"},{"slug":"beta-card"}]}\n'
FAKE
chmod +x "$fakebin/kanban"

mkdir -p "$WT/repo-alpha-card"
git -C "$WT/repo-alpha-card" init -q 2>/dev/null
touch -t 202001010000 "$WT/repo-alpha-card"

# SKIP_LSOF is essential here, not incidental: with liveness unavailable every
# tree is treated as live and logged "keep protected", so this assertion would
# pass without the protect set doing any work at all.
out="$(PATH="$fakebin:$PATH" HOME="$tmp" WORKTREES_DIR="$WT" \
  LAST_STACK_RECLAIM_SKIP_LSOF=1 \
  "$bin" --sweep-stale --max-age-hours 999999 --dry-run 2>&1 || true)"
if ! printf '%s' "$out" | grep -q 'keep protected repo-alpha-card'; then
  echo "FAIL: a doing-card worktree was not protected — protect set is empty" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi
# ...and prove it was the PROTECT SET, not a blind liveness fallback, by
# confirming an unprotected sibling in the same run was still reclaimed.
if ! printf '%s' "$out" | grep -q 'reclaim finished finished-a'; then
  echo "FAIL: protect assertion passed vacuously — nothing was reclaimed in that run" >&2
  printf '%s\n' "$out" >&2
  exit 1
fi

echo "PASS: liveness hard-closed without board, soft-degrades with board, finished work reclaims promptly, board parse sound"
