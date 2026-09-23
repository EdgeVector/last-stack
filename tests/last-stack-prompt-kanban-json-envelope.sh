#!/usr/bin/env bash
# Guard: routine prompts and skills must parse `kanban list|search --json` as
# the envelope {cards, total, truncated}, never as a bare array.
#
# On 2026-09-23 a validation worker ran
#   jq -r '(.cards // .[]) | if type=="array" then .[] else . end | [.slug,...]'
# over a list capture and died with `Cannot index array with string "slug"`
# (papercut-kanban-watch-list-json-envelope-20260923). This grep keeps the
# array form out of every prompt an agent copies from.
#
# Flagged on a line that runs jq:
#   1. `(.cards // .[])`                       — mixes the two shapes
#   2. `kanban list|search ... --json ... | jq '.[]` or `'[.[]`
#   3. `.[] | select(.column`                  — card fields over a bare array
#   4. `jq -s 'add'`                           — merges envelopes into one object
# `--json-array` (the legacy compat flag) is exempt from rule 2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"

scan() { # scan <file>...: print offending file:line:text
  awk '
    /jq/ {
      bad = 0
      if (index($0, "(.cards // .[])")) bad = 1
      if ($0 ~ /kanban[ \t]+(list|search)/ && $0 ~ /--json([ \t]|$)/ && $0 !~ /--json-array/ \
          && $0 ~ /\|[ \t]*jq[^|]*'"'"'\[?\.\[\]/) bad = 1
      if ($0 ~ /\.\[\][ \t]*\|[ \t]*select\(\.column/) bad = 1
      if ($0 ~ /jq[ \t]+-s[ \t]+'"'"'add'"'"'/) bad = 1
      if (bad) printf "%s:%d: %s\n", FILENAME, FNR, $0
    }
  ' "$@"
}

# Self-test: the scanner must catch each bad shape and pass the good one.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
cat >"$tmp/bad.md" <<'EOF'
jq -r '(.cards // .[]) | .slug' board.json
kanban list --column doing --json | jq -r '.[] | .slug'
jq -r '.[] | select(.column=="todo") | .slug' /tmp/k.json
jq -s 'add' a.json b.json
EOF
cat >"$tmp/good.md" <<'EOF'
jq -r '.cards[] | .slug' board.json
kanban list --column doing --json | jq -r '.cards[] | .slug'
kanban list --json-array | jq -r '.[] | .slug'
jq -r '.[] | [.repo, .status] | @tsv' deploy-scan.json
EOF
test "$(scan "$tmp/bad.md" | wc -l | tr -d ' ')" -eq 4 || {
  echo "FAIL: scanner self-test missed a bad shape" >&2
  scan "$tmp/bad.md" >&2
  exit 1
}
test -z "$(scan "$tmp/good.md")" || {
  echo "FAIL: scanner self-test flagged a good shape" >&2
  scan "$tmp/good.md" >&2
  exit 1
}

files=()
for f in "$ROOT"/routines/*.md "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/*.md; do
  [ -f "$f" ] && files+=("$f")
done
hits="$(scan "${files[@]}" | sort -u)"
if [ -n "$hits" ]; then
  echo "FAIL: kanban list/search JSON parsed as a bare array (use .cards[]):" >&2
  printf '%s\n' "$hits" >&2
  exit 1
fi
echo "ok last-stack-prompt-kanban-json-envelope (${#files[@]} prompts scanned)"
