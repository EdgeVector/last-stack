#!/usr/bin/env bash
# Asking a helper for help must not be reported as a failure.
#
# The shape, recorded five times over twelve days against one binary and then
# measured across bin/: a helper documents `-h`/`--help` in its own source and
# still exits non-zero when you use it, because the help arm sits behind an
# arity check or behind a positional that swallows the flag. Every agent
# harness marks that call `is_error=true`, so the discovery gesture reads as a
# broken tool and the caller falls back to reading the script.
#
#   papercut-last-stack-kanban-file-pr-help-exits-2                 (the class)
#   papercut-kanban-file-pr-help-hides-work-class-and-admission-refusal-names-no-remedy
#
# Its "Never-again coverage" block read `Current guard/test: NONE` /
# `Prevention: MISSING` through all five recurrences. This is that guard.
#
# Scope. The check EXECUTES `--help` only for helpers enrolled in
# config/help-flag-contract.tsv, and enrollment requires that someone read the
# parser first. A sweep that runs every helper in bin/ with `--help` fires
# last-stack-card-closeout, which parses `--help` as a card slug and escalates
# to a `--force` board move. `--report` prints the unenrolled population from
# source alone, so growing the list stays cheap without ever running one.
#
# A purely static rule was measured against this tree first and rejected: it
# cannot see the two ordering shapes at all (a reachable-looking `exit 0` that
# a `$# -lt 2` test shadows, and a help arm behind a consumed positional), and
# it reported 17 files, most of them false positives from idioms like
# `usage 0` where usage exits "${1:-2}". A guard that needs an opt-out on 17
# files to describe 5 defects is not a guard.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

CONTRACT="${LAST_STACK_HELP_FLAG_CONTRACT:-$ROOT/config/help-flag-contract.tsv}"
BIN_DIR="${LAST_STACK_HELP_FLAG_BIN_DIR:-$ROOT/bin}"

# A helper "documents a help flag" when it names one as its OWN argument: a
# case arm, or a comparison against a positional. Merely passing --help through
# to another tool does not count.
has_help_arm() {
  # A bash case arm or test on --help, or a Python argparse parser: argparse
  # wires -h/--help itself unless the helper passes add_help=False.
  if grep -qE -- '(-h\|--help|--help\|-h)\)|(\[|\[\[)[^\n]*"?\$\{?[0-9][^\n]*=[[:space:]]*"?--help"?' "$1" 2>/dev/null; then
    return 0
  fi
  grep -q 'ArgumentParser(' "$1" 2>/dev/null && ! grep -q 'add_help=False' "$1" 2>/dev/null
}

failures=0
fail() {
  printf 'help-flag-contract: %s\n' "$*" >&2
  failures=$(( failures + 1 ))
}

enrolled=""
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  helper="$(printf '%s' "$line" | cut -f1)"
  verdict="$(printf '%s' "$line" | cut -f2)"
  reason="$(printf '%s' "$line" | cut -f3)"
  [ -n "$helper" ] || continue

  if [ "$verdict" != "exit0" ]; then
    fail "$helper: unknown verdict '$verdict' (only exit0 is defined)"
    continue
  fi
  if [ -z "$reason" ]; then
    fail "$helper: enrolled with no reason — say which parser you read"
    continue
  fi

  path="$BIN_DIR/$helper"
  # A stale row is a real failure: it means the guard silently stopped
  # covering something it claims to cover.
  if [ ! -f "$path" ]; then
    fail "$helper: enrolled but $path does not exist (stale row)"
    continue
  fi
  if [ ! -x "$path" ]; then
    fail "$helper: enrolled but not executable"
    continue
  fi
  if ! has_help_arm "$path"; then
    fail "$helper: enrolled but no longer documents -h/--help (stale row)"
    continue
  fi
  enrolled="$enrolled $helper"

  for flag in --help -h; do
    out="$(mktemp "${TMPDIR:-/tmp}/help-flag-out.XXXXXX")"
    err="$(mktemp "${TMPDIR:-/tmp}/help-flag-err.XXXXXX")"
    set +e
    "$path" "$flag" >"$out" 2>"$err"
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
      fail "$helper $flag exited $rc — asking for help is not an error"
    fi
    if [ ! -s "$out" ]; then
      fail "$helper $flag printed nothing on stdout — usage belongs on stdout"
    fi
    if [ -s "$err" ]; then
      fail "$helper $flag wrote to stderr: $(head -1 "$err")"
    fi
    rm -f "$out" "$err"
  done
done < "$CONTRACT"

[ -n "$enrolled" ] || fail "no helper is enrolled — the contract file is empty"

# A help handler must not carry a hard-coded upper line bound.
#
# The idiom was `print lines 2..N of myself`, where N is a claim about where the
# header comment block ends and nothing checked it. It drifts in both
# directions on every header edit. Measured on main da6b2c5ed3a6 across the 24
# sites that used it: 6 boundaries correct, 17 over-reaching (printing
# `set -euo pipefail`, blank lines and variable assignments as usage — `setup`
# ended its usage with `set -e` and `umask 077`), and 1 UNDER-reaching, which
# is the costly direction and has no symptom:
# bin/last-stack-routines-prompt-doctor dropped its own exit-code contract from
# --help while the text sat in the file looking documented.
#
# The drift is not a set of wrong numbers to correct. Two days earlier the same
# census read 9 / 14 / 1; three merges later it read 6 / 17 / 1, with nobody
# touching a help handler. So the fix is the shared form, and this is the guard
# that keeps it:
#
#   awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
#
# which stops at the first non-comment line and cannot drift. Two helpers
# (bin/last-stack-lint-bin-authoring, bin/last-stack-routine-shell-lint) already
# carried it, each with the same rationale in its own header.
#
# This is a STATIC check, unlike the one the header above rejects. That one had
# to infer whether a help arm was REACHABLE, which needs ordering it cannot see.
# This one matches a literal idiom whose presence is the defect, so it has no
# false positives to opt out of.
# papercut-bin-help-is-a-hardcoded-sed-line-range-so-14-of-24-print-code-as-usage-20261004
help_range_re="sed -n '2,[0-9][0-9]*p'"
range_hits=""
for f in "$BIN_DIR"/* "$ROOT/setup"; do
  [ -f "$f" ] || continue
  # Strip whole-line comments before matching. The two helpers above QUOTE this
  # idiom in their own headers to explain the defect, and a guard that greps
  # source matches the rationale as readily as the thing it describes.
  if sed -e 's/^[[:space:]]*#.*$//' "$f" | grep -qE -- "$help_range_re"; then
    range_hits="$range_hits $(basename "$f")"
  fi
done
if [ -n "$range_hits" ]; then
  for h in $range_hits; do
    fail "$h: --help uses a hard-coded line range; use the awk form that stops at the first non-comment line"
  done
fi


# --report: the unenrolled population, from source only. Never executes.
if [ "${1:-}" = "--report" ]; then
  printf '\nhelpers in %s with a help arm and NOT enrolled:\n' "$BIN_DIR"
  for f in "$BIN_DIR"/*; do
    [ -f "$f" ] || continue
    has_help_arm "$f" || continue
    name="$(basename "$f")"
    case " $enrolled " in *" $name "*) continue ;; esac
    printf '  %s\n' "$name"
  done
fi

if [ "$failures" -gt 0 ]; then
  cat >&2 <<'MSG'

Handle -h/--help BEFORE any arity check and before any positional is consumed;
print the usage on stdout and exit 0. Keep exit 2 on stderr for a genuine
argument error. papercut-last-stack-kanban-file-pr-help-exits-2
MSG
  exit 1
fi

printf 'help-flag-contract: ok (%s enrolled)\n' "$(printf '%s' "$enrolled" | wc -w | tr -d ' ')"
