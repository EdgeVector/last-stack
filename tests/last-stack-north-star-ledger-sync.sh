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
mkdir -p "$tmp/bin" "$tmp/home/.last-stack/north-star-proofs"

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

printf 'PASS-OFFLINE\ncompound fixture\n' >"$tmp/home/.last-stack/north-star-proofs/north-star-example.md"
HOME="$tmp/home" "$EVAL" --kind validation \
  --predicate 'file $HOME/.last-stack/north-star-proofs/north-star-example.md matches /^PASS/' \
  >"$tmp/eval.out"
grep -Fq 'satisfied: file' "$tmp/eval.out"

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
