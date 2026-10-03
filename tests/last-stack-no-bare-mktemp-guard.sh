#!/usr/bin/env bash
# Guard for the guard: tests/last-stack-no-bare-mktemp.sh must catch BOTH mktemp
# defects across its WHOLE advertised scope, and must not fire on the correct form.
#
# Why this exists. Until 2026-10-03 that gate scanned `bin/` only and checked a
# property ("the line carries XXXXXX somewhere") that `card.XXXXXX.json` satisfies,
# while its own header promised to stop mktemp calls that break under the routine
# sandbox. It passed, so the files it certified looked audited; the two real
# suffix-form instances and four real bare calls were all found by hand
# (papercut-no-bare-mktemp-guard-checks-template-presence-not-x-run-position-and-only-scans-bin-20261003).
# A scope/property pair can only drift silently if nothing asserts the pair, so
# every directory in the target set gets a case here. Add a directory to
# `list_targets` and you add a case here, or the widening is unproven.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GATE="$ROOT/tests/last-stack-no-bare-mktemp.sh"
[ -x "$GATE" ] || { echo "FAIL: gate not executable: $GATE"; exit 1; }

work="$(mktemp -d "${TMPDIR:-/tmp}/no-bare-mktemp-guard.XXXXXX")"
trap 'rm -rf "$work"' EXIT

fails=0

# Build a fixture tree holding one file at $1 whose body is $2.
fixture() {
  local rel="$1" body="$2" dir
  rm -rf "$work/tree"
  dir="$work/tree/$(dirname "$rel")"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$work/tree/$rel"
}

# $1 label, $2 expected rc (0 pass / 1 fail), $3 substring the output must contain
# ("-" for none).
expect() {
  local label="$1" want="$2" needle="$3" out rc
  out="$(LAST_STACK_NO_BARE_MKTEMP_ROOT="$work/tree" bash "$GATE" 2>&1)" && rc=0 || rc=$?
  if [ "$rc" -ne "$want" ]; then
    echo "FAIL [$label]: expected rc=$want, got rc=$rc"
    printf '%s\n' "$out" | sed 's/^/    /'
    fails=$((fails + 1))
    return
  fi
  if [ "$needle" != "-" ] && ! printf '%s' "$out" | grep -q "$needle"; then
    echo "FAIL [$label]: output lacks '$needle'"
    printf '%s\n' "$out" | sed 's/^/    /'
    fails=$((fails + 1))
    return
  fi
  echo "ok   [$label]"
}

# --- Property 1 (no template) must be caught in EVERY scoped directory. -------
# These are the directories bin/-only scanning could not see. A bare call here is
# a WRONG value, not an absent one: the file exists and is scanned, and the only
# question is whether the gate reads it.
for rel in bin/helper lib/some-lib.sh hooks/a-hook skills/thing/scripts/do.sh \
           harness/north-star/x/run.sh; do
  fixture "$rel" 'f="$(mktemp)"'
  expect "no-template in $(dirname "$rel")/" 1 'no explicit template'
done

# `mktemp -d` is the same defect: measured 2026-10-03, bare `mktemp -d` also
# ignores TMPDIR and answers /var/folders/.../T. Three of the four real instances
# were this spelling, so a gate that only knew plain `mktemp` would miss them.
fixture lib/d.sh 'd="$(mktemp -d)"'
expect "no-template, -d spelling" 1 'no explicit template'

# --- Property 2 (X run not last) must be caught, including in bin/. -----------
# bin/ was always in scope, so a RED here is the PROPERTY being new rather than
# the scope -- the two halves of the fix are asserted separately on purpose.
fixture bin/suffix 'f="$(mktemp "${TMPDIR:-/tmp}/card.XXXXXX.json")"'
expect "suffix form in bin/ (property, not scope)" 1 'X run is not LAST'

fixture harness/north-star/y/run.sh 'p="$(mktemp "${TMPDIR:-/tmp}/g.XXXXXX.json")"'
expect "suffix form in harness/" 1 'X run is not LAST'

# -d does not exempt it: the literal directory name is created just the same.
fixture lib/sd.sh 'd="$(mktemp -d "${TMPDIR:-/tmp}/x.XXXXXX.d")"'
expect "suffix form, -d spelling" 1 'X run is not LAST'

# --- The correct form must PASS, or the gate is unusable. ---------------------
fixture bin/good 'f="$(mktemp "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/ok.XXXXXX")"'
expect "correct template passes" 0 'PASS'

fixture bin/goodd 'd="$(mktemp -d "${TMPDIR:-/tmp}/ok.XXXXXX")"'
expect "correct -d template passes" 0 'PASS'

# A template that legitimately ENDS in X's inside $( ) is not a suffix violation.
fixture bin/goodsub 'echo "$(mktemp "${TMPDIR:-/tmp}/ok.XXXXXX")"'
expect "template ending in X inside \$( ) passes" 0 'PASS'

# --- Escapes and comments keep working. --------------------------------------
fixture bin/escaped 'f="$(mktemp)"  # mktemp-ok: fixture for the escape hatch'
expect "mktemp-ok: escapes" 0 'PASS'

fixture bin/commented '# a comment mentioning mktemp with no template at all'
expect "comment line ignored" 0 'PASS'

# --- tests/ is deliberately NOT scanned. -------------------------------------
# tests/ holds 201 legitimate throwaway `mktemp -d` dirs and six DELIBERATE
# suffix-form fixtures proving the sibling lint rejects that shape (measured
# 2026-10-03). Scanning tests/ would make the gate red forever on the file that
# proves the rule, so the exclusion is asserted, not assumed.
fixture tests/some-test.sh 'f="$(mktemp)"
g="$(mktemp "${TMPDIR:-/tmp}/c.XXXXXX.json")"'
expect "tests/ is out of scope" 0 'PASS'

# --- The two copies of the suffix matcher must stay byte-identical. -----------
# tests/last-stack-no-bare-mktemp.sh says in its own header that its `re_suffix`
# is lifted verbatim from bin/last-stack-routine-shell-lint's `re_mktemp_suffix`
# so "the agent-typed guard and this repo-source guard cannot drift". Nothing
# enforced that, and an unenforced claim in a comment is how the agent surface and
# the repo surface came to check different properties in the first place. Compare
# the two assignments with their trailing comment stripped.
lint_re="$(sed -n 's/^re_mktemp_suffix=//p' "$ROOT/bin/last-stack-routine-shell-lint" | sed 's/[[:space:]]*#.*$//')"
gate_re="$(sed -n 's/^re_suffix=//p' "$GATE" | sed 's/[[:space:]]*#.*$//')"
if [ -z "$lint_re" ] || [ -z "$gate_re" ]; then
  echo "FAIL [matcher shared]: could not read one of the assignments"
  echo "    lint_re=${lint_re:-<empty>}"
  echo "    gate_re=${gate_re:-<empty>}"
  fails=$((fails + 1))
elif [ "$lint_re" != "$gate_re" ]; then
  echo "FAIL [matcher shared]: the suffix matcher has drifted between the two guards"
  echo "    bin/last-stack-routine-shell-lint re_mktemp_suffix: $lint_re"
  echo "    tests/last-stack-no-bare-mktemp.sh  re_suffix:       $gate_re"
  echo "    change both, or drop the 'lifted verbatim' claim from the gate header"
  fails=$((fails + 1))
else
  echo "ok   [matcher shared: byte-identical in both guards]"
fi

if [ "$fails" -ne 0 ]; then
  echo "FAIL last-stack-no-bare-mktemp-guard ($fails case(s))"
  exit 1
fi
echo "PASS last-stack-no-bare-mktemp-guard"
