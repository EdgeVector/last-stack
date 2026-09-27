#!/usr/bin/env bash
set -euo pipefail

# Fixture for `last-stack-papercut-ledger-append`: the ledger writer must
# roll to a dated successor before the active record hits LastDB's
# 524288-byte atom content limit, and must reuse a successor another writer
# already linked instead of minting a second one on the same day.
# (papercut-reconciler-ledger-reaches-lastdb-atom-limit-20260927)

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tool="$ROOT/bin/last-stack-papercut-ledger-append"
[ -x "$tool" ] || { echo "missing executable ledger-append helper" >&2; exit 1; }

tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
bin_dir="$tmp/bin"
mkdir -p "$bin_dir"

# --- Case 1: base record has room -- append goes straight to it, no rollover.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":"small\\n"}\n'
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$CASE1_LOG"
    ;;
  *)
    echo "unexpected case1 brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/brain"
export CASE1_LOG="$tmp/case1.log"
: >"$CASE1_LOG"
out="$(PATH="$bin_dir:$PATH" "$tool" --base-slug papercut-reconciler-ledger <<<'2026-09-27T00:00:00Z papercut-x -> card:none | pattern:none | skip:none')"
[ "$out" = "papercut-reconciler-ledger" ] || { echo "case1: expected base slug, got: $out" >&2; exit 1; }
grep -q 'papercut-x' "$CASE1_LOG"

# --- Case 2: base record is over the rollover threshold and has no
# Successor pointer yet -- mint a dated successor, link it from the base,
# create it, and append the real text there.
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
today="$(date -u +%Y%m%d)"
successor="papercut-reconciler-ledger-${today}"
case "$*" in
  "get papercut-reconciler-ledger --type reference --json")
    python3 -c "import json; print(json.dumps({'slug': 'papercut-reconciler-ledger', 'body': 'x' * 510000}))"
    ;;
  "append papercut-reconciler-ledger --type reference")
    cat >>"$CASE2_LOG"
    printf 'POINTER-APPEND base\n' >>"$CASE2_LOG"
    ;;
  "get ${successor} --type reference --json")
    echo "no such record" >&2
    exit 1
    ;;
  "put --type reference")
    cat >>"$CASE2_LOG"
    printf 'PUT %s\n' "$successor" >>"$CASE2_LOG"
    ;;
  "append ${successor} --type reference")
    cat >>"$CASE2_LOG"
    printf 'APPEND %s\n' "$successor" >>"$CASE2_LOG"
    ;;
  *)
    echo "unexpected case2 brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/brain"
export CASE2_LOG="$tmp/case2.log"
: >"$CASE2_LOG"
today="$(date -u +%Y%m%d)"
expected_successor="papercut-reconciler-ledger-${today}"
out2="$(PATH="$bin_dir:$PATH" "$tool" --base-slug papercut-reconciler-ledger <<<'2026-09-27T00:00:01Z papercut-y -> card:none | pattern:none | skip:none')"
[ "$out2" = "$expected_successor" ] || { echo "case2: expected $expected_successor, got: $out2" >&2; exit 1; }
grep -q "Successor: ${expected_successor}" "$CASE2_LOG"
grep -q "^PUT ${expected_successor}\$" "$CASE2_LOG"
grep -q "^APPEND ${expected_successor}\$" "$CASE2_LOG"
grep -q 'papercut-y' "$CASE2_LOG"

# --- Case 3: base already points at a successor another writer created and
# linked earlier today, and that successor still has room -- reuse it
# directly. No second pointer append, no `put` (must not re-create it).
cat >"$bin_dir/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "get papercut-reconciler-ledger --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger","body":"full\\nSuccessor: papercut-reconciler-ledger-20260927\\n"}\n'
    ;;
  "get papercut-reconciler-ledger-20260927 --type reference --json")
    printf '{"slug":"papercut-reconciler-ledger-20260927","body":"already has some lines\\n"}\n'
    ;;
  "append papercut-reconciler-ledger-20260927 --type reference")
    cat >>"$CASE3_LOG"
    printf 'APPEND successor\n' >>"$CASE3_LOG"
    ;;
  *)
    echo "unexpected case3 brain args: $*" >&2
    exit 2
    ;;
esac
SH
chmod +x "$bin_dir/brain"
export CASE3_LOG="$tmp/case3.log"
: >"$CASE3_LOG"
out3="$(PATH="$bin_dir:$PATH" "$tool" --base-slug papercut-reconciler-ledger <<<'2026-09-27T00:00:02Z papercut-z -> card:none | pattern:none | skip:none')"
[ "$out3" = "papercut-reconciler-ledger-20260927" ] || { echo "case3: expected existing successor, got: $out3" >&2; exit 1; }
grep -q 'papercut-z' "$CASE3_LOG"
if grep -q 'PUT' "$CASE3_LOG"; then
  echo "case3: re-created an already-existing successor" >&2
  exit 1
fi

echo "ok"
