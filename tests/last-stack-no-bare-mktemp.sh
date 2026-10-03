#!/usr/bin/env bash
# Static gate: no shipped helper may call `mktemp` in a form that ignores TMPDIR
# or never substitutes.
#
# Two properties, both measured on this host 2026-10-03:
#
#   1. NO TEMPLATE. Bare `mktemp` and bare `mktemp -d` BOTH resolve to the
#      per-user temp dir (confstr DARWIN_USER_TEMP_DIR) and IGNORE TMPDIR --
#      `TMPDIR=/private/tmp/... mktemp` answered /var/folders/8n/.../T/tmp.jH5big.
#      Scheduled routine sandboxes deny that path, which made helpers fail hourly
#      until each run hand-built a shim
#      (papercut-routine-mktemp-tempdir-env-denied-20260821,
#      papercut-worktree-reclaim-helper-ignores-routine-tmpdir).
#
#   2. X RUN NOT LAST. BSD mktemp substitutes a run of X's only at the END of the
#      template. `mktemp "$T/probe.XXXXXX.json"` created the LITERAL name
#      `probe.XXXXXX.json`, and the next call answered
#      `mkstemp failed ... File exists` -- so the first call succeeds and every
#      later one dies until someone deletes the literal file
#      (papercut-mktemp-same-template-collides-within-one-second-20260925).
#
# Every mktemp call must pass a template whose X run is last, e.g.:
#   mktemp "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack.XXXXXX"
# When the extension matters, take a directory:
#   "$(mktemp -d "${TMPDIR:-/tmp}/last-stack.XXXXXX")/body.json"
#
# SCOPE. This used to scan `$ROOT/bin` only, and checked only property 1, with a
# matcher ("the line carries XXXXXX somewhere") that `card.XXXXXX.json` satisfies.
# Both real suffix-form instances found on 2026-10-03 were outside bin/ AND passed
# that matcher, and widening the scope found four bare calls that bin/ alone could
# not see -- two of them in lib/lastdb-http.sh, which is SOURCED by
# bin/last-stack-deliver-status and bin/last-stack-publish-status, so this gate was
# certifying two helpers whose defect lived one `source` away
# (papercut-no-bare-mktemp-guard-checks-template-presence-not-x-run-position-and-only-scans-bin-20261003).
# The target set now mirrors bin/last-stack-lint-bin-authoring's `list_targets`
# plus harness/, which that linter does not cover at all.
#
# `tests/` is DELIBERATELY out of scope, and this is not an oversight to repair:
# measured 2026-10-03 it holds 201 bare `mktemp -d` throwaway dirs (a test's own
# scratch dir is not shipped and not sandboxed) and, worse, six DELIBERATE
# suffix-form fixtures in tests/last-stack-routine-shell-lint.sh, which are the
# negative cases proving the sibling guard rejects this shape. Scanning tests/
# would make this gate red forever on the file that proves the rule.
#
# A line that legitimately carries mktemp syntax without a substituting template
# -- a regex that recognises mktemp calls, for instance -- states its reason with
# `# mktemp-ok: <reason>`, the same escape convention as `# walk-ok:` in
# last-stack-lint-bin-authoring.
set -euo pipefail

# LAST_STACK_NO_BARE_MKTEMP_ROOT exists so tests/last-stack-no-bare-mktemp-guard.sh
# can run this gate against fixture trees. Without it this gate could only ever be
# checked by hand against the live repo, which is how a guard's scope and its
# promise drift apart unnoticed.
ROOT="${LAST_STACK_NO_BARE_MKTEMP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# A call: the name is not part of a longer identifier on either side. `.` and `-`
# are excluded so neither `mktemp-suffix` nor `re_mktemp_suffix` reads as a call.
re_call='(^|[^[:alnum:]_.-])mktemp([^[:alnum:]_.-]|$)'
# Property 2. Lifted verbatim from bin/last-stack-routine-shell-lint's
# `re_mktemp_suffix` so the agent-typed guard (rule `mktemp-suffix`) and this
# repo-source guard cannot drift: one spelling, two surfaces. Scoped to mktemp's
# own argument token -- the leading class cannot cross a space or a quote, so an
# unrelated XXX elsewhere on the line cannot match, and the trailing class
# excludes shell punctuation so a correct template that ENDS in X's inside $( )
# is not a false positive.
re_suffix='(^|[^[:alnum:]_-])mktemp([[:space:]]+-[^[:space:]]+)*[[:space:]]+["'"'"']?[^[:space:]"'"'"'`]*XXX+[^[:space:]"'"'"'`(){}|&;<>X]'  # mktemp-ok: this is the recogniser for an mktemp call, not a call

# Mirrors bin/last-stack-lint-bin-authoring list_targets, plus harness/ (which
# that linter does not cover). Bounded depth at every root, as it does.
list_targets() {
  local d
  for d in bin lib hooks; do
    [ -d "$ROOT/$d" ] || continue
    find "$ROOT/$d" -maxdepth 1 -type f -print0
  done
  if [ -d "$ROOT/skills" ]; then
    find "$ROOT/skills" -maxdepth 3 -type f -path '*/scripts/*' -print0
  fi
  if [ -d "$ROOT/harness" ]; then
    find "$ROOT/harness" -maxdepth 4 -type f -print0
  fi
}

# /dev/null forces grep to prefix every hit with its path even when the file list
# happens to hold a single entry. -I skips binaries.
scan() {
  list_targets \
    | xargs -0 grep -I -nE "$1" /dev/null 2>/dev/null \
    | grep -v 'mktemp-ok:' \
    | grep -vE ':[0-9]+:[[:space:]]*#' \
    || true
}

rc=0

# Property 1: a call with no XXXXXX template anywhere on the line.
no_template="$(scan "$re_call" | grep -v 'XXXXXX' || true)"
if [ -n "$no_template" ]; then
  echo "FAIL: mktemp with no explicit template (ignores TMPDIR; sandbox-denied on Darwin):"
  printf '%s\n' "$no_template"
  echo "  fix: mktemp \"\${TMPDIR:-\${TMP:-\${TEMP:-/tmp}}}/last-stack.XXXXXX\""
  rc=1
fi

# Property 2: a template whose X run is not last, so it never substitutes.
bad_suffix="$(scan "$re_suffix" || true)"
if [ -n "$bad_suffix" ]; then
  echo "FAIL: mktemp template whose X run is not LAST (creates the literal name, then every later call fails 'File exists'):"
  printf '%s\n' "$bad_suffix"
  echo "  fix: put the X run last, or take a directory: \"\$(mktemp -d \"\${TMPDIR:-/tmp}/x.XXXXXX\")/body.json\""
  rc=1
fi

[ "$rc" -eq 0 ] || exit 1

echo "PASS last-stack-no-bare-mktemp"
