#!/usr/bin/env bash
# papercut-kanban-closeout-end-state-warning-20260921
#
# A card whose END STATE carries a machine DONE-WHEN is evaluated at closeout.
# Satisfied -> no end-state-unverified warning and an END-STATE-EVALUATED mark.
# Pending -> the warning names what is missing (DONE-WHEN=pending).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-card-closeout"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
board="$tmp/board"
export DW_COL="$tmp/col" DW_BODY="$tmp/body" DW_MARKS="$tmp/marks"
cat >"$board" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  show)
    jq -n --arg slug "${2:-}" --arg col "$(cat "$DW_COL")" --rawfile body "$DW_BODY" \
      '{slug:$slug, column:$col, pr_url:"", branch:"", body:$body}'
    ;;
  add) exit 0 ;;
  move) printf '%s\n' "${3:-}" >"$DW_COL" ;;
  mark) printf '%s\n' "${3:-}" >>"$DW_BODY"; printf '%s\n' "${3:-}" >>"$DW_MARKS" ;;
  *) echo "unexpected board call: $*" >&2; exit 2 ;;
esac
EOF
chmod +x "$board"

proof="$tmp/proof.md"
printf 'PASS measured\n' >"$proof"

echo doing >"$DW_COL"; : >"$DW_MARKS"
printf '%s\n' 'Repo: EdgeVector/last-stack' 'Kind: pr' '## END STATE' 'The report passes.' \
  "DONE-WHEN: file $proof matches /^PASS/ AND date >= 2000-01-01" >"$DW_BODY"
out="$("$bin" dw-card --board-cli "$board" 2>&1)" || { echo "FAIL: satisfied DONE-WHEN close failed: $out" >&2; exit 1; }
if printf '%s\n' "$out" | grep -q 'end-state-unverified'; then
  echo "FAIL: a satisfied DONE-WHEN must not warn end-state-unverified: $out" >&2
  exit 1
fi
grep -q '^END-STATE-EVALUATED .* DONE-WHEN satisfied' "$DW_MARKS" || {
  echo "FAIL: expected an END-STATE-EVALUATED mark" >&2; cat "$DW_MARKS" >&2; exit 1; }
[ "$(cat "$DW_COL")" = done ]

echo doing >"$DW_COL"; : >"$DW_MARKS"
printf '%s\n' 'Repo: EdgeVector/last-stack' 'Kind: pr' '## END STATE' 'The report passes.' \
  "DONE-WHEN: file $tmp/missing.md matches /^PASS/" >"$DW_BODY"
out="$("$bin" dw-card-2 --board-cli "$board" 2>&1)" || true
printf '%s\n' "$out" | grep -q 'WARN end-state-unverified' || { echo "FAIL: pending DONE-WHEN must still warn: $out" >&2; exit 1; }
printf '%s\n' "$out" | grep -q 'DONE-WHEN=pending' || { echo "FAIL: warning must name DONE-WHEN=pending: $out" >&2; exit 1; }

echo "ok last-stack-card-closeout-done-when"
