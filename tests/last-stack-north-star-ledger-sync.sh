#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BIN="$ROOT/bin/last-stack-north-star-ledger-sync"
EVAL="$ROOT/bin/last-stack-kanban-done-when-eval"
chmod +x "$BIN"
python3 "$BIN" --self-test

# Compound prevention: generator -> validation-card body -> proof writer path
# -> the real DONE-WHEN evaluator. The mock CLIs isolate board/brain writes;
# the evaluator and generated predicate are production code.
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Do NOT pre-create the proof directory. The production writer must create
# it, so this fixture exercises the real path it chooses.
mkdir -p "$tmp/bin" "$tmp/home"

cat >"$tmp/heading.md" <<'EOF'
## MILESTONE_REQUEST
slug=foo
status=pending

### Outcome
A
EOF
printf '%s\n' 'MILESTONE_REQUEST slug=foo status=pending' >"$tmp/oneline.md"
python3 "$BIN" --parse-body "$tmp/heading.md" >"$tmp/heading.json"
python3 "$BIN" --parse-body "$tmp/oneline.md" >"$tmp/oneline.json"
jq -e '.requests == [{"slug":"foo","status":"pending"}]' "$tmp/heading.json" >/dev/null
jq -e '.requests == []' "$tmp/oneline.json" >/dev/null

cat >"$tmp/bin/brain" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  get)
    cat <<'PROJECT'
title: Example North Star
status: in_progress
---
**Mode:** ship

## Terminal verification
**Card:** `example-ns-terminal-verification`
PROJECT
    ;;
  append|put) cat >/dev/null ;;
  *) exit 2 ;;
esac
EOF

cat >"$tmp/bin/kanban" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "milestone portfolio") printf '%s\n' '{"entries":[],"total":0,"truncated":false}' ;;
  "show example-ns-terminal-verification")
    if [ "${MOCK_EXISTING:-0}" = "1" ]; then
      printf '%s\n' '{"slug":"example-ns-terminal-verification","column":"backlog","body":"Kind: validation\nRepo: EdgeVector/last-stack\nBase: main\n\nDONE-WHEN: file docs/north-star-proofs/north-star-example.md matches /PASS|GREEN/\n"}'
    else
      exit 1
    fi
    ;;
  "add example-ns-terminal-verification") cat >"$MOCK_CARD_BODY" ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$tmp/bin/brain" "$tmp/bin/kanban"

MOCK_CARD_BODY="$tmp/created-card.md" \
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
  python3 "$BIN" --apply --ns north-star-example --json >"$tmp/create.json"
grep -Fq 'DONE-WHEN: file $HOME/.last-stack/north-star-proofs/north-star-example.md matches /^PASS/' "$tmp/created-card.md"
! grep -Fq 'docs/north-star-proofs' "$tmp/created-card.md"

# Write the proof through the PRODUCTION writer, and read the predicate back
# out of the PRODUCTION card body. Neither path is retyped here.
#
# The earlier version of this fixture hand-placed the report file and hand-typed
# the predicate, so the test encoded the path a third time: a drift in
# ns_proof_dir would have kept this test green while every live terminal card
# again claimed DONE-WHEN on a path nothing writes. That is the exact defect
# this test exists to prevent.
proof_report="$(
  HOME="$tmp/home" NORTH_STAR_PROOF_MODE=offline bash -c '
    . "$1/harness/north-star/common.sh"
    ns_write_report north-star-example PASS-OFFLINE "compound fixture"
  ' _ "$ROOT" | sed -n 's/^PROOF_REPORT=//p'
)"
[ -f "$proof_report" ]

predicate="$(sed -n 's/^DONE-WHEN: //p' "$tmp/created-card.md" | head -n 1)"
[ -n "$predicate" ]

# The failure invariant, executable: the path the generated card CLAIMS is the
# path the writer WROTE.
pred_path="$(printf '%s\n' "$predicate" | sed -n 's/^file \([^ ]*\) matches .*$/\1/p')"
pred_path="${pred_path//\$HOME/$tmp/home}"
[ "$pred_path" = "$proof_report" ] || {
  echo "FAIL: card DONE-WHEN path ($pred_path) is not the proof writer path ($proof_report)" >&2
  exit 1
}

HOME="$tmp/home" "$EVAL" --kind validation --predicate "$predicate" >"$tmp/eval.out"
grep -Fq 'satisfied: file' "$tmp/eval.out"

# Red arm: prove the probe can still fail. A writer that lands elsewhere must
# leave the generated predicate pending, not silently satisfied.
HOME="$tmp/home" NORTH_STAR_PROOF_DIR="$tmp/home/drifted-proofs" bash -c '
  . "$1/harness/north-star/common.sh"
  ns_write_report north-star-drift PASS-OFFLINE "drifted writer"
' _ "$ROOT" >/dev/null
set +e
HOME="$tmp/home" "$EVAL" --kind validation \
  --predicate 'file $HOME/.last-stack/north-star-proofs/north-star-drift.md matches /^PASS/' \
  >"$tmp/eval-red.out"
red_rc=$?
set -e
[ "$red_rc" -eq 1 ]
grep -Fq 'pending: file' "$tmp/eval-red.out"

# Existing named terminal shells heal through the same targeted --apply --ns
# pass, with no whole-board scan.
MOCK_EXISTING=1 MOCK_CARD_BODY="$tmp/healed-card.md" \
  HOME="$tmp/home" PATH="$tmp/bin:$PATH" \
  python3 "$BIN" --apply --ns north-star-example --json >"$tmp/heal.json"
grep -Fq 'DONE-WHEN: file $HOME/.last-stack/north-star-proofs/north-star-example.md matches /^PASS/' "$tmp/healed-card.md"
! grep -Fq 'docs/north-star-proofs' "$tmp/healed-card.md"
grep -Fq 'healed_terminal_done_when:example-ns-terminal-verification' "$tmp/heal.json"

# driver mentions ledger-sync
grep -q 'last-stack-north-star-ledger-sync' "$ROOT/routines/north-star-driver.md"
grep -q 'Skip stale pending requests' "$ROOT/routines/north-star-driver.md"
echo "last-stack-north-star-ledger-sync tests ok"
