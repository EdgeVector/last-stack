#!/usr/bin/env bash
# sec-review-later/scan.sh — discover the [sec-review-later] backlog on origin/main,
# group commits into sprint buckets, and emit a review digest (range + PRs + changed
# files per bucket) so a security-review fan-out can be driven off it.
#
# Usage:
#   scan.sh                      # everything flagged since the last reviewed checkpoint
#   scan.sh --since <ref|date>   # override the checkpoint (e.g. --since "30 days ago" or a sha)
#   scan.sh --theme <bucket>     # restrict to one bucket key (e.g. at-rest-encryption)
#   scan.sh --all                # ignore the checkpoint; show the full 30d backlog
#   scan.sh --mark <sha>         # record <sha> (default origin/main) as reviewed-through, then exit
#
# Buckets are derived from the conventional-commit scope/keywords. The checkpoint
# lives in this skill dir as .reviewed-through (a sha). Nothing here writes to the repo.
set -euo pipefail

REPO="${FOLD_REPO:-$HOME/code/edgevector/fold}"
SKILL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CKPT="$SKILL_DIR/.reviewed-through"

SINCE=""
THEME=""
ALL=0
MARK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="$2"; shift 2 ;;
    --theme) THEME="$2"; shift 2 ;;
    --all)   ALL=1; shift ;;
    --mark)  MARK="${2:-origin/main}"; shift; [ $# -gt 0 ] && shift || true ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

cd "$REPO"
git fetch origin -q 2>/dev/null || true

if [ -n "$MARK" ]; then
  sha="$(git rev-parse "$MARK")"
  printf '%s\n' "$sha" > "$CKPT"
  echo "marked reviewed-through = $sha ($(git log -1 --pretty=%s "$sha"))"
  exit 0
fi

# Decide the lower bound for the log range.
if [ -n "$SINCE" ]; then
  RANGE_ARGS=(--since "$SINCE")
  BOUND_DESC="--since $SINCE"
elif [ "$ALL" -eq 1 ]; then
  RANGE_ARGS=(--since "30 days ago")
  BOUND_DESC="full 30d backlog (--all)"
elif [ -f "$CKPT" ] && git rev-parse --verify -q "$(cat "$CKPT")^{commit}" >/dev/null; then
  CK="$(cat "$CKPT")"
  RANGE_ARGS=("${CK}..origin/main")
  BOUND_DESC="since checkpoint ${CK:0:9} ($(git log -1 --pretty=%s "$CK" 2>/dev/null | cut -c1-50))"
else
  RANGE_ARGS=(--since "14 days ago")
  BOUND_DESC="no checkpoint — last 14 days"
fi

# Emit raw flagged commits (sha \t subject), then group + render in group.py.
# NOTE: group.py is a separate file (not a `python3 -` heredoc) so the piped
# commit data stays on stdin instead of being shadowed by the heredoc.
git log origin/main "${RANGE_ARGS[@]}" --no-merges --pretty=format:'%H%x09%s' \
  | { grep -F '[sec-review-later]' || true; } \
  | THEME="$THEME" REPO="$REPO" BOUND_DESC="$BOUND_DESC" python3 "$SKILL_DIR/group.py"
