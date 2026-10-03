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
scratch="$(cd "$scratch" && pwd -P)"
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

# Same, from a chosen cwd. The off-target check reads the worktree the helper is
# invoked IN, so these cases must run inside the fixture repo. stderr stays
# outside it, or the capture file is itself an untracked change.
run_probe_in() {
  local dir="$1"; shift
  probe_rc=0
  probe_out="$(cd "$dir" && "$helper" "$@" 2>"$scratch/err")" || probe_rc=$?
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

# ================================================================ off-target
# A patch that edits a file outside --target is never snapshotted and never
# restored: the edit survives the probe. The old helper reported that with the
# vocabulary of the no-op case -- `mutated=no`, exit 3, "the probe is invalid" --
# all true of the targets and false of the tree, so the caller fixed the anchor
# and re-ran on a tree that no longer matched the commit.
# brain: papercut-mutation-probe-leaves-an-off-target-mutation-in-the-tree-and-calls-it-no-op-20261003

repo="$scratch/repo"
mkdir -p "$repo/sub"
git -c init.defaultBranch=main init -q "$repo"
git -C "$repo" config user.email probe@example.invalid
git -C "$repo" config user.name probe
printf 'keep1\nkeep2\nMARKED=1\nMARKED=2\nMARKED=3\n' > "$repo/offtarget.py"
printf '#!/usr/bin/env bash\n            check_pin_behind "$row"\n' > "$repo/product.sh"
printf 'under a target directory\n' > "$repo/sub/nested.txt"
cat > "$repo/patch-offtarget.py" <<'PATCH'
import pathlib, re
# an ANCHORED miss on the target: 6 spaces where the file holds 12, so the
# target does not move at all -- the recorded shape
t = pathlib.Path("product.sh")
t.write_text(re.sub(r'(?m)^      check_pin_behind', '      noop_pin', t.read_text()))
o = pathlib.Path("offtarget.py")
o.write_text(o.read_text().replace("MARKED=3\n", ""))
PATCH
cat > "$repo/patch-both.py" <<'PATCH'
import pathlib
t = pathlib.Path("product.sh")
t.write_text(t.read_text().replace("check_pin_behind", "noop_pin"))
o = pathlib.Path("offtarget.py")
o.write_text(o.read_text().replace("MARKED=2\n", ""))
PATCH
git -C "$repo" add -A
git -C "$repo" commit -qm fixture
repo_guard="$scratch/repo-guard.sh"
cat > "$repo_guard" <<SRC
#!/usr/bin/env bash
: > "$ran_marker"
grep -q 'check_pin_behind' "$repo/product.sh"
SRC
chmod +x "$repo_guard"

# ---------------------------------------------------------------- case 9
# THE DEFECT, in the recorded shape: the off-target file is ALREADY modified
# before the probe, so `git status --porcelain` reads the same line before and
# after and a status-list diff is BLIND to it. A content id per dirty path is
# what moves. Exit 5 (not 3), and the file is named.
printf 'keep1\nkeep2 EDITED BEFORE THE PROBE\nMARKED=1\nMARKED=2\nMARKED=3\n' > "$repo/offtarget.py"
status_before="$(git -C "$repo" status --porcelain)"
rm -f "$ran_marker"
run_probe_in "$repo" --name offtarget-with-a-noop-target --target product.sh \
  --patch "python3 patch-offtarget.py" --test "bash '$repo_guard'"
[ "$probe_rc" -eq 5 ] || fail "case9 expected rc 5 for an off-target mutation, got $probe_rc ($probe_err)"
case "$probe_err" in
  *"OUTSIDE --target"*"$repo/offtarget.py"*) ;;
  *) fail "case9 did not name the off-target path: $probe_err" ;;
esac
case "$probe_out" in *"offtarget=1"*) ;; *) fail "case9 line does not count the off-target path: $probe_out" ;; esac
[ -f "$ran_marker" ] && fail "case9 ran the guard test on a tree carrying an unobserved change"
# the precondition that defeats the cheap fix: the status LIST never moved
[ "$status_before" = "$(git -C "$repo" status --porcelain)" ] || \
  fail "case9 fixture is wrong: the porcelain list moved, so it is not the blind case"
[ "$(grep -c MARKED "$repo/offtarget.py")" -eq 2 ] || \
  fail "case9 fixture is wrong: the patch did not edit the off-target file"
printf 'keep1\nkeep2\nMARKED=1\nMARKED=2\nMARKED=3\n' > "$repo/offtarget.py"

# ---------------------------------------------------------------- case 10
# An off-target mutation alongside a REAL target mutation is still fatal, and
# the guard test must not run: a verdict computed on a tree carrying an
# unobserved change is not a verdict.
rm -f "$ran_marker"
run_probe_in "$repo" --name offtarget-with-a-real-target --target product.sh \
  --patch "python3 patch-both.py" --test "bash '$repo_guard'"
[ "$probe_rc" -eq 5 ] || fail "case10 expected rc 5, got $probe_rc ($probe_err)"
case "$probe_out" in *"mutated=yes"*"verdict=NONE"*) ;; *) fail "case10: $probe_out" ;; esac
[ -f "$ran_marker" ] && fail "case10 ran the guard test despite an off-target mutation"
[ "$(git -C "$repo" show HEAD:product.sh)" = "$(cat "$repo/product.sh")" ] || \
  fail "case10 did not restore the target it DID snapshot"
printf 'keep1\nkeep2\nMARKED=1\nMARKED=2\nMARKED=3\n' > "$repo/offtarget.py"

# ---------------------------------------------------------------- case 11
# The direction that would break every caller: a correctly-targeted probe inside
# a git worktree must still pass, reporting offtarget=none. A path UNDER a
# --target directory is on-target, not a stray.
rm -f "$ran_marker"
run_probe_in "$repo" --name correctly-targeted-is-not-refused \
  --target product.sh --target sub \
  --patch "python3 -c \"import pathlib; p=pathlib.Path('product.sh'); p.write_text(p.read_text().replace('check_pin_behind','noop_pin')); q=pathlib.Path('sub/nested.txt'); q.write_text('changed under the target dir\\n')\"" \
  --test "bash '$repo_guard'"
[ "$probe_rc" -eq 0 ] || fail "case11 expected rc 0 for a correctly-targeted probe, got $probe_rc ($probe_err)"
case "$probe_out" in
  *"verdict=RED"*"restored=ok"*"offtarget=none"*) ;;
  *) fail "case11 line does not report offtarget=none: $probe_out" ;;
esac
[ "$(cat "$repo/sub/nested.txt")" = "under a target directory" ] || \
  fail "case11 did not restore the nested file under the --target directory"

# ---------------------------------------------------------------- case 12
# Outside a git worktree the check cannot run. It must say so -- `unchecked`,
# never `none`. A probe that cannot read its dependency must not report clean.
plain="$scratch/plain"
mkdir -p "$plain"
printf 'needle\n' > "$plain/f.txt"
rm -f "$ran_marker"
GIT_CEILING_DIRECTORIES="$plain" run_probe_in "$plain" --name outside-a-worktree --target f.txt \
  --patch "printf 'gone\n' > '$plain/f.txt'" \
  --test "grep -q needle '$plain/f.txt'"
[ "$probe_rc" -eq 0 ] || fail "case12 expected rc 0 outside a worktree, got $probe_rc ($probe_err)"
case "$probe_out" in
  *"offtarget=unchecked"*) ;;
  *) fail "case12 must report offtarget=unchecked, not a clean answer it cannot give: $probe_out" ;;
esac

# ---------------------------------------------------------------- case 13
# --help must keep printing the whole exit-code table. It is a `sed` line range,
# so it silently truncates when the header grows.
help_out="$("$helper" --help)"
case "$help_out" in
  *"OUTSIDE --target"*) ;;
  *) fail "case13 --help does not print the exit-5 row; the sed range is short" ;;
esac

# ---------------------------------------------------------------- docs + wiring
# A helper nobody is told about never runs (the shipped-but-never-called shape).
require 'last-stack-mutation-probe' "$doc"
require 'changed no byte' "$doc"
require 'the patch mutated nothing' "$doc"
require '--expect green' "$doc"
require 'Put the patch in its own file' "$doc"
# A hand `grep` after a probe is not a second opinion on the restore; it is a
# second chance to be wrong, and it reported three destroyed files on 2026-10-03.
require 'IS the restore evidence' "$doc"
# An off-target mutation is not a no-op, and `git status --short` cannot find one
# on a file that was already modified.
require 'OUTSIDE' "$doc"
require 'mutated a file the helper never snapshotted' "$doc"
require "MP_START='<!-- last-stack:mutation-probe:start" "$setup"
require "MP_END='<!-- last-stack:mutation-probe:end -->'" "$setup"
require 'strip_managed_md_block "$file" "$MP_START" "$MP_END"' "$setup"
require 'append_managed_md_block "$file" "$SOURCE_ROOT/instructions/mutation-probe.md" "$MP_START" "$MP_END"' "$setup"

echo "ok last-stack-mutation-probe"
