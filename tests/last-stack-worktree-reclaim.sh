#!/usr/bin/env bash
# Structural smoke for last-stack-worktree-reclaim (no live board / no real worktrees).
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

# dry-run sweep (no-op or strip-only against real roots — must not crash)
"$bin" --sweep-stale --max-age-hours 99999 --dry-run >/dev/null || true

# card-closeout still documents reclaim step
rg -q 'last-stack-worktree-reclaim' "$ROOT/bin/last-stack-card-closeout"
rg -q 'last-stack-worktree-reclaim' "$ROOT/bin/last-stack-board-closeout-sweep"
rg -q 'sweep-stale' "$ROOT/routines/disk-reclaim.md"
rg -q 'sweep-stale' "$ROOT/routines/worktree-cleanup.md"

echo "ok last-stack-worktree-reclaim"
