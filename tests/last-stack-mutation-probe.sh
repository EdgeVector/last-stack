#!/usr/bin/env bash
# Contract: a mutation probe that changed nothing is an ERROR, never a green.
#
# Measured 2026-10-03 (brain
# papercut-no-mutation-probe-helper-so-a-no-op-probe-reads-as-a-passing-guard-20261003):
# two of six hand-rolled probes for one new guard came back GREEN because their
# patch anchors never matched the file -- one off by indentation, one by a
# backslash level. Neither guard was weak. The recorded reading of an unexpected
# green is "ask which branch ran" or "the property is protected twice", advice
# that is right for a real green and sends you to the wrong place for a no-op.
#
# The load-bearing case here is no-op-patch-is-exit-3-and-skips-the-test: it
# asserts both the exit code AND that the test command never ran, so a no-op
# probe cannot produce a verdict for anyone to misread.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$root/bin/last-stack-mutation-probe"
doc="$root/instructions/mutation-probe.md"
setup="$root/setup"

fail() { printf 'mutation-probe: %s\n' "$1" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"; }

[ -x "$helper" ] || fail "missing or non-executable $helper"
[ -f "$doc" ] || fail "missing $doc"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/mutation-probe-test.XXXXXX")"
cleanup() {
  chmod -R u+rwX "$scratch" 2>/dev/null || true
  rm -rf -- "$scratch"
}
trap cleanup EXIT

# A fixture "product" file and a "guard" that refuses one property in it.
mkdir -p "$scratch/work"
src="$scratch/work/product.sh"
guard="$scratch/work/guard.sh"
ran_marker="$scratch/work/guard-ran"

cat > "$src" <<'SRC'
#!/usr/bin/env bash
            check_pin_behind "$row"
SRC
cat > "$guard" <<SRC
#!/usr/bin/env bash
: > "$ran_marker"
grep -q 'check_pin_behind' "$src"
SRC
chmod +x "$guard"
src_before="$(cat "$src")"

run_probe() {
  probe_rc=0
  probe_out="$("$helper" "$@" 2>"$scratch/err")" || probe_rc=$?
  probe_err="$(cat "$scratch/err")"
}

# ---------------------------------------------------------------- case 1
# A real probe: the patch lands, the guard goes RED, exit 0, tree restored.
rm -f "$ran_marker"
run_probe --name drops-the-check --target "$src" \
  --patch "sed -i '' 's/check_pin_behind/noop_pin/' '$src'" \
  --test "bash '$guard'"
[ "$probe_rc" -eq 0 ] || fail "case1 expected rc 0, got $probe_rc ($probe_err)"
case "$probe_out" in
  *"mutated=yes"*"verdict=RED"*"restored=ok"*) ;;
  *) fail "case1 line does not report mutated=yes verdict=RED restored=ok: $probe_out" ;;
esac
[ -f "$ran_marker" ] || fail "case1 never ran the guard"
[ "$(cat "$src")" = "$src_before" ] || fail "case1 did not restore the target bytes"

# ---------------------------------------------------------------- case 2
# THE DEFECT. The anchor's indentation is wrong (6 spaces where the file holds
# 12), so the patch replaces nothing. Exit 3, no verdict, and the guard test is
# never run.
rm -f "$ran_marker"
run_probe --name anchor-indentation-wrong --target "$src" \
  --patch "sed -i '' 's/^      check_pin_behind/      noop_pin/' '$src'" \
  --test "bash '$guard'"
[ "$probe_rc" -eq 3 ] || fail "case2 expected rc 3 for a no-op patch, got $probe_rc"
case "$probe_out" in
  *"mutated=no"*"verdict=NONE"*) ;;
  *) fail "case2 line does not report mutated=no verdict=NONE: $probe_out" ;;
esac
[ -f "$ran_marker" ] && fail "case2 ran the guard test on an unmutated tree"
case "$probe_err" in
  *"changed no byte"*) ;;
  *) fail "case2 stderr does not say the probe changed no byte: $probe_err" ;;
esac
[ "$(cat "$src")" = "$src_before" ] || fail "case2 disturbed the target"

# ---------------------------------------------------------------- case 3
# A weak guard: the patch lands and the test still passes. That is the one
# result --expect red exists to catch, and it must be rc 1, not rc 0.
run_probe --name guard-is-blind --target "$src" \
  --patch "printf '# an unguarded trailing comment\n' >> '$src'" \
  --test "bash '$guard'"
[ "$probe_rc" -eq 1 ] || fail "case3 expected rc 1 for a surviving guard, got $probe_rc"
case "$probe_out" in
  *"mutated=yes"*"verdict=GREEN"*) ;;
  *) fail "case3 line does not report mutated=yes verdict=GREEN: $probe_out" ;;
esac
[ "$(cat "$src")" = "$src_before" ] || fail "case3 did not restore the target bytes"

# ---------------------------------------------------------------- case 4
# --expect green proves the other direction: a legitimate variation that the
# guard must NOT refuse.
run_probe --name legitimate-variation-is-allowed --target "$src" --expect green \
  --patch "printf '# an unguarded trailing comment\n' >> '$src'" \
  --test "bash '$guard'"
[ "$probe_rc" -eq 0 ] || fail "case4 expected rc 0 under --expect green, got $probe_rc"
case "$probe_out" in
  *"verdict=GREEN"*"expect=GREEN"*) ;;
  *) fail "case4 line does not report verdict=GREEN expect=GREEN: $probe_out" ;;
esac

# ---------------------------------------------------------------- case 5
# Creating a target that was absent is a mutation. Without this, a probe that
# adds a file reads as a no-op.
absent="$scratch/work/created.txt"
rm -f "$absent"
run_probe --name creates-a-missing-file --target "$absent" \
  --patch "printf 'hello\n' > '$absent'" \
  --test "false"
[ "$probe_rc" -eq 0 ] || fail "case5 expected rc 0, got $probe_rc ($probe_err)"
case "$probe_out" in *"mutated=yes"*) ;; *) fail "case5 did not see the creation as a mutation: $probe_out" ;; esac
[ -e "$absent" ] && fail "case5 left the created file behind; restore must remove it"

# ---------------------------------------------------------------- case 6
# Removing a target that was present is a mutation, and the restore puts it back.
run_probe --name deletes-the-file --target "$src" \
  --patch "rm -f '$src'" \
  --test "bash '$guard'"
[ "$probe_rc" -eq 0 ] || fail "case6 expected rc 0, got $probe_rc ($probe_err)"
case "$probe_out" in *"mutated=yes"*"verdict=RED"*) ;; *) fail "case6: $probe_out" ;; esac
[ -f "$src" ] || fail "case6 did not restore the deleted target"
[ "$(cat "$src")" = "$src_before" ] || fail "case6 restored the wrong bytes"

# ---------------------------------------------------------------- case 7
# A restore that cannot write must report restored=FAILED with exit 4 and keep
# the snapshot, never abort silently and leave a mutated tree with no message.
lockdir="$scratch/locked"
mkdir -p "$lockdir"
locked="$lockdir/product.sh"
cp "$src" "$locked"
run_probe --name restore-cannot-write --target "$locked" \
  --patch "printf 'mutated\n' >> '$locked'" \
  --test "chmod 0444 '$locked'; chmod 0500 '$lockdir'; false"
chmod u+rwx "$lockdir"; chmod u+rw "$locked"
[ "$probe_rc" -eq 4 ] || fail "case7 expected rc 4 for a failed restore, got $probe_rc ($probe_err)"
case "$probe_out" in *"restored=FAILED"*) ;; *) fail "case7 did not report restored=FAILED: $probe_out" ;; esac
case "$probe_err" in
  *"snapshot kept at "*) ;;
  *) fail "case7 did not print the kept snapshot path: $probe_err" ;;
esac
kept="$(printf '%s' "$probe_err" | sed -n 's/.*snapshot kept at \([^ ]*\).*/\1/p')"
[ -d "$kept" ] || fail "case7 named a snapshot dir that does not exist: $kept"
rm -rf -- "$kept"

# ---------------------------------------------------------------- case 8
# Usage errors are rc 2 and never touch the tree.
for bad in "--target $src --patch true --test true" \
           "--name x --patch true --test true" \
           "--name x --target $src --test true" \
           "--name x --target $src --patch true" \
           "--name x --target $src --patch true --test true --expect maybe" \
           "--name x --target $src --patch true --test true --nonsense"; do
  usage_rc=0
  # shellcheck disable=SC2086
  "$helper" $bad >/dev/null 2>&1 || usage_rc=$?
  [ "$usage_rc" -eq 2 ] || fail "usage case '$bad' expected rc 2, got $usage_rc"
done

# ---------------------------------------------------------------- docs + wiring
# A helper nobody is told about never runs (the shipped-but-never-called shape).
require 'last-stack-mutation-probe' "$doc"
require 'changed no byte' "$doc"
require 'the patch mutated nothing' "$doc"
require '--expect green' "$doc"
require 'Put the patch in its own file' "$doc"
require "MP_START='<!-- last-stack:mutation-probe:start" "$setup"
require "MP_END='<!-- last-stack:mutation-probe:end -->'" "$setup"
require 'strip_managed_md_block "$file" "$MP_START" "$MP_END"' "$setup"
require 'append_managed_md_block "$file" "$SOURCE_ROOT/instructions/mutation-probe.md" "$MP_START" "$MP_END"' "$setup"

echo "ok last-stack-mutation-probe"
