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


# A self-printing help handler must STRIP the source comment marker.
#
# Every helper here documents itself in its own leading comment block and prints
# that block as usage. Two renderings were in the tree. 15 sites stripped the
# marker; 13 printed it verbatim, so `--help` read as source rather than as
# documentation, and a blank separator in the header rendered as a line holding
# one punctuation mark:
#
#   $ ./setup --help | head -3
#   # The Last Stack - setup / installer
#   #
#   # Registers each skill in skills/ into whatever agent harnesses you have
#
# The split predates the line-range fix above, which deliberately kept each
# site's existing rendering so a 24-file rewrite stayed mechanical. This rule is
# the other half.
#
# Scope note, measured rather than assumed. The rule matches a self-print header
# line -- an awk program that skips line 1 and prints /^#/ lines, or the
# `sed -n '2,/^[^#]/p'` spelling, naming $0 or BASH_SOURCE -- and requires
# sub(/^# ?/, "") on that same line. Run against the tree before the fix it
# selected exactly the 13 sites whose `--help` actually printed a leading `#`,
# and none of the 15 correct ones: no opt-out list, which is what separates this
# from the reachability rule the header above rejects.
#
# Three spellings existed (spaced strip, spaced raw, and one unspaced raw in
# bin/last-stack-board-closeout-sweep that a literal-match census had missed),
# so the matcher is whitespace-tolerant on purpose. A fourth spelling would be
# caught as long as it still skips line 1 and prints /^#/ from itself.
# papercut-bin-help-prints-the-source-comment-marker-on-11-of-25-helpers-20261004
help_printer_re="(NR[[:space:]]*==[[:space:]]*1.*/\^#/|sed -n '2,/\^\[\^#\]/p')"
help_self_re='(\$0|BASH_SOURCE)'
help_strip_re='sub\(/\^# \?/'
marker_hits=""
for f in "$BIN_DIR"/* "$ROOT/setup"; do
  [ -f "$f" ] || continue
  # Strip whole-line comments first, for the same reason as the rule above: the
  # helpers that carry this idiom correctly also QUOTE it in their own headers.
  # Measured for THIS rule: exactly one line in the tree would false-positive
  # without the strip, and it is in this file, which the loop below never reads.
  # So the strip is defensive here rather than load-bearing, unlike in the rule
  # above where it is both -- and the probe that drops it is GREEN on its own and
  # RED only when paired with a quoting comment planted in bin/. Keeping it means
  # a helper may explain the defect in its own header without tripping the guard.
  #
  # One pipeline per file, not one per line. The first draft tested each source
  # line in its own grep, which is ~4 processes per line of bin/ and took over
  # two minutes; this is the same predicate in a fixed number of processes.
  if sed -e 's/^[[:space:]]*#.*$//' "$f" \
    | grep -E -- "$help_printer_re" \
    | grep -E -- "$help_self_re" \
    | grep -qvE -- "$help_strip_re"; then
    marker_hits="$marker_hits $(basename "$f")"
  fi
done
if [ -n "$marker_hits" ]; then
  for h in $marker_hits; do
    fail "$h: --help prints its own comment markers; add sub(/^# ?/, \"\") so usage reads as documentation"
  done
fi


# A help arm must not route the usage text to stderr.
#
# The third contract clause, and the one that does NOT need execution. The
# executed check above asserts `usage belongs on stdout` and `wrote to stderr`
# for the 15 enrolled helpers; `--report` says 162 helpers in bin/ document a
# help flag and are NOT enrolled, so that clause covered under 9% of the
# population it describes. Enrollment stays deliberate for the reason the
# contract file gives — a sweep that runs every helper with `--help` fires
# last-stack-card-closeout, which reads the flag as a card slug and escalates
# to a `--force` board move — so the reach has to come from a static rule.
#
# A `usage()` that redirects to `>&2` and is called from a `-h|--help` arm is a
# static fact: nothing about it depends on ordering or reachability, which is
# what sank the static reachability rule the top of this file rejects.
#
# Measured on main fc1eb9d9a988 before the fix. The predicate selected 19
# helpers, and all 19 were then EXECUTED: every one printed 0 bytes on stdout
# and its whole usage on stderr. Zero false positives, so there is no opt-out
# list — the same bar the two rules above meet. One of the 19,
# last-stack-sccache-health, also exited 2, which is this file's PRIMARY class
# (papercut-last-stack-kanban-file-pr-help-exits-2, five recurrences) living
# unseen in an unenrolled helper.
#
# The fix the rule asks for is a stream, not a bare `cat`: 18 of the 19 call
# the same `usage` from their argument-error path too, so dropping `>&2` from
# the function alone moves the error text to stdout and trades one violation
# for another. `usage` prints on stdout; the error arms call `usage >&2`.
# papercut-host-track-help-prints-its-entire-usage-to-stderr-and-nothing-to-stdout-20261004
stream_hits=""
for f in "$BIN_DIR"/* "$ROOT/setup"; do
  [ -f "$f" ] || continue
  # Strip whole-line comments first, for the same reason as the two rules
  # above: a helper may quote `cat >&2` while explaining this very defect, and a
  # guard that greps source matches the rationale as readily as the thing it
  # describes. Measured today the strip changes nothing (0 hits with it, 0
  # without), so it is DEFENSIVE here rather than load-bearing -- but the probe
  # that drops it is RED as soon as one comment inside a usage() body mentions
  # `>&2`, which is exactly the note this fix invites someone to leave. The
  # first draft of that probe put the comment ABOVE `usage() {`, outside the
  # body the loop reads, and came back GREEN: the fixture, not the guard.
  if sed -e 's/^[[:space:]]*#.*$//' "$f" | awk '
      { line[NR] = $0 }
      END {
        fn = ""
        for (i = 1; i <= NR; i++) {
          if (line[i] ~ /(-h\|--help|--help\|-h)[[:space:]]*\)/) {
            rest = line[i]
            sub(/^.*(-h\|--help|--help\|-h)[[:space:]]*\)[[:space:]]*/, "", rest)
            j = i
            # the arm may wrap, putting the call on the next line
            while (rest == "" && j < NR) { j++; rest = line[j]; sub(/^[[:space:]]+/, "", rest) }
            if (match(rest, /^[A-Za-z_][A-Za-z0-9_]*/)) fn = substr(rest, 1, RLENGTH)
            break
          }
        }
        if (fn == "") exit 1
        start = 0
        for (i = 1; i <= NR; i++) {
          if (line[i] ~ "^[[:space:]]*" fn "[[:space:]]*\\(\\)[[:space:]]*\\{") { start = i; break }
        }
        if (start == 0) exit 1
        for (i = start + 1; i <= NR; i++) {
          if (line[i] ~ /^\}/) break
          if (line[i] ~ />&2/) exit 0
        }
        exit 1
      }
    '; then
    stream_hits="$stream_hits $(basename "$f")"
  fi
done
if [ -n "$stream_hits" ]; then
  for h in $stream_hits; do
    fail "$h: --help routes usage to stderr; print usage on stdout and call \"usage >&2\" from the error arms only"
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
