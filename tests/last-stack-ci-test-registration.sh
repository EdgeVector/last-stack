#!/usr/bin/env bash
# Every tests/*.sh must be either scheduled by the required gate or recorded as
# a deliberate exclusion with a reason.
#
# Ground truth: papercut-last-stack-tests-can-land-unregistered-in-required-gate
# (filed 2026-08-30, five recurrences to 2026-09-06). `.lastgit/ci.sh` schedules
# tests through an explicit `ci_test tests/<name>.sh` enumeration and shards by
# LIST POSITION, so a new file is discovered by nothing. The `tests/*.sh` globs
# that do appear in ci.sh are lint-only (`bash -n`, shellcheck) plus the
# LAST_STACK_CI_FULL=1 branch the required gate never takes. The measured
# result: 63 of 215 files unrun on 2026-08-30, 70 of 251 on 2026-09-06 -- a
# steady ~29%, because nothing rejects the omission. Three separate passes
# noticed only by grepping a green gate log for their own test's output line.
#
# 2026-09-26: an unlisted test is no longer "forgotten". The auto-discovery
# block at the end of .lastgit/ci.sh runs every present, unlisted, non-exempt
# test in a shard chosen by a hash of its path, so the list positions (and the
# shard pairing they fix) do not move. A test that must not run in the merge
# path still needs a '<path><TAB><reason>' line in tests/.ci-exempt; that file
# stays the audited record of every deliberate exclusion.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CI="$ROOT/.lastgit/ci.sh"
EXEMPT="$ROOT/tests/.ci-exempt"

fail() {
  echo "$*" >&2
  exit 1
}

[ -f "$CI" ] || fail "no .lastgit/ci.sh at $CI"
[ -f "$EXEMPT" ] || fail "no exemption manifest at $EXEMPT"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# Present: every test file in the suite's own naming convention.
( cd "$ROOT" && ls tests/*.sh ) | sort -u > "$tmp/present"

# Scheduled: the explicit ci_test enumeration the required gate actually runs.
grep -oE '^ci_test tests/[^ ]+' "$CI" | awk '{print $2}' | sort -u > "$tmp/scheduled"

# Exempt: "<path><TAB><reason>". Blank lines and whole-line comments ignored.
# A reason is mandatory -- an exemption without one is the forgetting this
# guard exists to catch, wearing a manifest entry as a disguise.
: > "$tmp/exempt"
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$((lineno + 1))
  case "$line" in
    ''|'#'*) continue ;;
  esac
  path="${line%%$'\t'*}"
  reason="${line#*$'\t'}"
  [ "$reason" != "$line" ] || fail "tests/.ci-exempt:$lineno: no TAB, so no reason: $line"
  # shellcheck disable=SC2001
  reason="$(echo "$reason" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -n "$reason" ] || fail "tests/.ci-exempt:$lineno: empty reason for $path"
  [ "${#reason}" -ge 20 ] || fail "tests/.ci-exempt:$lineno: reason too short to be a decision ($path): $reason"
  echo "$path" >> "$tmp/exempt"
done < "$EXEMPT"
sort -u "$tmp/exempt" -o "$tmp/exempt"

status=0

# 1. Unaccounted: present, but neither listed nor exempt. These are no longer
# an error: the auto-discovery block at the end of .lastgit/ci.sh runs them in
# a hash-assigned shard. Name them so the gate log shows what it discovered.
comm -23 "$tmp/present" <(sort -u "$tmp/scheduled" "$tmp/exempt") > "$tmp/unaccounted"
if [ -s "$tmp/unaccounted" ]; then
  echo "auto-discovered (run by ci_test_discovered, no ci.sh edit needed):"
  sed 's/^/  /' "$tmp/unaccounted"
fi
grep -qx 'ci_test_discovered' "$CI" || {
  echo "the auto-discovery call ci_test_discovered is missing from .lastgit/ci.sh," >&2
  echo "so an unlisted, non-exempt test runs in no required gate" >&2
  status=1
}

# 2. Dangling: scheduled, but the file is gone. The gate would die on it.
comm -13 "$tmp/present" "$tmp/scheduled" > "$tmp/dangling"
if [ -s "$tmp/dangling" ]; then
  status=1
  echo "these paths are scheduled by .lastgit/ci.sh but do not exist:" >&2
  sed 's/^/  /' "$tmp/dangling" >&2
fi

# 3. Stale: exempt, but the file is gone. The manifest is describing nothing.
comm -13 "$tmp/present" "$tmp/exempt" > "$tmp/stale"
if [ -s "$tmp/stale" ]; then
  status=1
  echo "these paths are listed in tests/.ci-exempt but do not exist:" >&2
  sed 's/^/  /' "$tmp/stale" >&2
fi

# 4. Contradiction: both scheduled and exempt. The manifest then records a
# decision that is not the one in force, which is worse than no entry.
comm -12 "$tmp/scheduled" "$tmp/exempt" > "$tmp/both"
if [ -s "$tmp/both" ]; then
  status=1
  echo "these paths are BOTH scheduled and exempt; remove the exemption:" >&2
  sed 's/^/  /' "$tmp/both" >&2
fi

[ "$status" -eq 0 ] || exit 1

echo "ok last-stack-ci-test-registration present=$(wc -l < "$tmp/present" | tr -d ' ') scheduled=$(wc -l < "$tmp/scheduled" | tr -d ' ') discovered=$(wc -l < "$tmp/unaccounted" | tr -d ' ') exempt=$(wc -l < "$tmp/exempt" | tr -d ' ')"
