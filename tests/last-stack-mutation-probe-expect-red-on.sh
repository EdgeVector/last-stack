#!/usr/bin/env bash
# Contract: a RED that is not the one the caller asked for is NOT a verdict.
#
# Measured 2026-10-04 (brain
# papercut-mutation-probe-cannot-state-which-assertion-the-red-should-be-about-20261004):
# six probes were written for one five-case guard test and all six printed
# `mutated=yes verdict=RED expect=RED restored=ok offtarget=none`. THREE of them
# had reached a different case than the one they targeted, because the cases
# share a predicate and the easiest one trips first; two cases had no
# independent verdict available at all. The helper judged on the exit code
# alone, so the strongest claim a probe could make was "something failed", and
# every reader of that line upgrades it to "the guard caught MY defect".
#
# The load-bearing case here is case 2: a probe whose red is on a DIFFERENT
# assertion must exit 6 and must not exit 0.
#
# Optional positional case filter, e.g. `... 2` to run only case 2. Every case
# drives the SAME helper, so an over-permissive mutation of the helper trips
# whichever case runs first and a probe aimed at a later one gets no verdict --
# which is the very defect this file is about. Probing a case in isolation is
# the fix, so the filter is part of the contract, not a convenience.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
helper="$root/bin/last-stack-mutation-probe"
doc="$root/instructions/mutation-probe.md"

only="${1:-}"
want() { [ -z "$only" ] || [ "$only" = "$1" ]; }

fail() { printf 'mutation-probe-expect-red-on: %s\n' "$1" >&2; exit 1; }
require() { grep -Fq -- "$1" "$2" || fail "missing '$1' in $2"; }

[ -x "$helper" ] || fail "missing or non-executable $helper"
[ -f "$doc" ] || fail "missing $doc"

scratch="$(mktemp -d "${TMPDIR:-/tmp}/mutation-probe-ero.XXXXXX")"
scratch="$(cd "$scratch" && pwd -P)"
trap 'rm -rf -- "$scratch"' EXIT

# A product file with TWO independently guarded properties, and a guard that
# checks them in order and stops at the first failure. That ordering is the
# whole mechanism: a mutation aimed at the second property can only be judged
# if the first one still holds.
mkdir -p "$scratch/work"
src="$scratch/work/product.sh"
guard="$scratch/work/guard.sh"
printf 'ALPHA=1\nBETA=2\n' > "$src"
cat > "$guard" <<SRC
#!/usr/bin/env bash
grep -q 'ALPHA=1' "$src" || { printf 'FAIL: case A: alpha is missing\n' >&2; exit 1; }
grep -q 'BETA=2'  "$src" || { printf 'FAIL: case B: beta is missing\n' >&2; exit 1; }
printf 'ok\n'
SRC
chmod +x "$guard"
src_before="$(cat "$src")"

# A second guard that reports on STDOUT, not stderr. A guard may print its
# failing assertion on either stream, so the capture has to see both.
guard_stdout="$scratch/work/guard-stdout.sh"
cat > "$guard_stdout" <<SRC
#!/usr/bin/env bash
grep -q 'BETA=2' "$src" || { printf 'FAIL: case B: beta is missing\n'; exit 1; }
printf 'ok\n'
SRC
chmod +x "$guard_stdout"

run_probe() {
  probe_rc=0
  probe_out="$("$helper" "$@" 2>"$scratch/err")" || probe_rc=$?
  probe_err="$(cat "$scratch/err")"
}

drop_beta="sed -i '' 's/^BETA=2$/BETA=99/' '$src'"
drop_alpha="sed -i '' 's/^ALPHA=1$/ALPHA=99/' '$src'"

# ---------------------------------------------------------------- case 1
# The red IS the one asked for: exit 0 as before, the verdict line now carries
# the pattern, and the matched assertion is echoed so the operator does not
# have to find it in the test output by eye.
if want 1; then
  run_probe --name beta-is-guarded --target "$src" \
    --patch "$drop_beta" --test "bash '$guard'" \
    --expect-red-on 'FAIL: case B'
  [ "$probe_rc" -eq 0 ] || fail "case 1: a matching red must stay exit 0, got $probe_rc ($probe_err)"
  case "$probe_out" in
    *"verdict=RED"*"expect_red_on='FAIL: case B'"*) ;;
    *) fail "case 1: the verdict line does not carry the pattern: $probe_out" ;;
  esac
  case "$probe_out" in
    *"red-on: FAIL: case B: beta is missing"*) ;;
    *) fail "case 1: the matched assertion is not echoed: $probe_out" ;;
  esac
  [ "$(cat "$src")" = "$src_before" ] || fail "case 1: the target was not restored"
fi

# ---------------------------------------------------------------- case 2
# THE DEFECT. The probe targets case B and the test stops on case A. Before
# --expect-red-on this printed `verdict=RED expect=RED restored=ok` and exited
# 0 -- a line that reads as a clean verdict while carrying none.
if want 2; then
  run_probe --name aimed-at-beta-reds-on-alpha --target "$src" \
    --patch "$drop_alpha" --test "bash '$guard'" \
    --expect-red-on 'FAIL: case B'
  [ "$probe_rc" -eq 6 ] || fail "case 2: an off-target red must be exit 6, got $probe_rc ($probe_err)"
  case "$probe_err" in
    *"nothing in the test output matched"*"FAIL: case B"*) ;;
    *) fail "case 2: stderr does not name the pattern that failed to match: $probe_err" ;;
  esac
  # The point of the message: it hands over the assertion that DID fail, so the
  # operator is not sent back to re-run the test to find out.
  case "$probe_err" in
    *"FAIL: case A: alpha is missing"*) ;;
    *) fail "case 2: stderr does not print the assertion the test actually failed on: $probe_err" ;;
  esac
  [ "$(cat "$src")" = "$src_before" ] || fail "case 2: the target was not restored"
fi

# ---------------------------------------------------------------- case 3
# The direction that would break every existing caller: no pattern, same
# behaviour as before, and the line says so with `expect_red_on=-`. A probe
# without a pattern must be visibly the weaker claim, not indistinguishable
# from a targeted one.
if want 3; then
  run_probe --name no-pattern-still-works --target "$src" \
    --patch "$drop_beta" --test "bash '$guard'"
  [ "$probe_rc" -eq 0 ] || fail "case 3: a probe with no pattern must still be exit 0, got $probe_rc ($probe_err)"
  case "$probe_out" in
    *"verdict=RED"*"expect_red_on=-"*) ;;
    *) fail "case 3: the verdict line must report expect_red_on=- when none was given: $probe_out" ;;
  esac
  case "$probe_out" in
    *"red-on:"*) fail "case 3: echoed a red-on line without a pattern: $probe_out" ;;
    *) ;;
  esac
fi

# ---------------------------------------------------------------- case 4
# A GREEN verdict must still be exit 1, not exit 6. The pattern never matches a
# test that passed, so the obvious implementation reports "wrong assertion"
# about a guard that is simply blind -- the wrong diagnosis for the one result
# --expect red exists to catch.
if want 4; then
  run_probe --name guard-is-blind-with-a-pattern --target "$src" \
    --patch "printf '# an unguarded trailing comment\n' >> '$src'" \
    --test "bash '$guard'" \
    --expect-red-on 'FAIL: case B'
  [ "$probe_rc" -eq 1 ] || fail "case 4: a surviving guard must stay exit 1, got $probe_rc ($probe_err)"
  case "$probe_err" in
    *"does not catch this defect"*) ;;
    *) fail "case 4: stderr must say the guard does not catch the defect: $probe_err" ;;
  esac
fi

# ---------------------------------------------------------------- case 5
# A guard that prints its assertion on STDOUT must match too. The capture
# merges the streams for exactly this reason.
if want 5; then
  run_probe --name assertion-on-stdout --target "$src" \
    --patch "$drop_beta" --test "bash '$guard_stdout'" \
    --expect-red-on 'FAIL: case B'
  [ "$probe_rc" -eq 0 ] || fail "case 5: a pattern on stdout must match, got $probe_rc ($probe_err)"
  case "$probe_out" in
    *"red-on: FAIL: case B"*) ;;
    *) fail "case 5: the stdout assertion was not matched: $probe_out" ;;
  esac
fi

# ---------------------------------------------------------------- case 6
# Usage errors. `--expect green --expect-red-on X` has no red for the pattern
# to be about, and two patterns would read as "either red will do" -- which is
# the weak claim this option exists to remove.
if want 6; then
  for bad in "--name x --target $src --patch true --test true --expect green --expect-red-on FAIL" \
             "--name x --target $src --patch true --test true --expect-red-on A --expect-red-on B" \
             "--name x --target $src --patch true --test true --expect-red-on" ; do
    usage_rc=0
    # shellcheck disable=SC2086
    "$helper" $bad >/dev/null 2>&1 || usage_rc=$?
    [ "$usage_rc" -eq 2 ] || fail "case 6: usage case '$bad' expected rc 2, got $usage_rc"
  done
fi

# ---------------------------------------------------------------- case 7
# A no-op patch is still exit 3, and the test is still not run, with a pattern
# given. Exit 6 must not displace the refusals that come before the test: a
# probe that mutated nothing has no output to match in the first place.
if want 7; then
  run_probe --name no-op-with-a-pattern --target "$src" \
    --patch "sed -i '' 's/^  BETA=2\$/  BETA=99/' '$src'" \
    --test "bash '$guard'" \
    --expect-red-on 'FAIL: case B'
  [ "$probe_rc" -eq 3 ] || fail "case 7: a no-op patch must stay exit 3, got $probe_rc ($probe_err)"
  case "$probe_err" in
    *"changed no byte"*) ;;
    *) fail "case 7: stderr does not report the no-op: $probe_err" ;;
  esac
fi

# ---------------------------------------------------------------- docs
# The option reaches nobody if the instructions do not carry it; this doc is
# the block setup appends to CLAUDE.md, so it is the fleet-wide surface.
if want 8; then
  require '--expect-red-on' "$doc"
  require 'THE RED WAS NOT THE ONE YOU ASKED FOR' "$doc"
  require 'expect_red_on=' "$doc"
  require '| 6 |' "$doc"
fi

if [ -n "$only" ]; then
  printf 'ok last-stack-mutation-probe-expect-red-on (case %s only)\n' "$only"
else
  printf 'ok last-stack-mutation-probe-expect-red-on\n'
fi
