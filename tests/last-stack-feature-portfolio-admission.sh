#!/usr/bin/env bash
# Hermetic fixtures for last-stack-feature-portfolio-admission.
# Cases: admitted primary, admitted secondary, a paused outcome, a missing
# record, malformed content, and a P0 secondary replacement.
# decision-2026-08-31-two-admitted-feature-outcomes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-feature-portfolio-admission"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

[ -x "$bin" ] || chmod +x "$bin"
slug="preference-feature-delivery-portfolio-admission"

# Write a fixture brain that answers exactly one point get.
write_record() {
  local dir="$1"
  mkdir -p "$dir/get"
  cat >"$dir/get/$slug.txt"
}

# A brain CLI that must never be reached for list or search.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${ADMISSION_BRAIN_LOG:-/dev/null}"
case "${1:-}" in
  get)
    slug="${2:-}"
    src="${ADMISSION_BRAIN_DIR:-}/get/$slug.txt"
    [ -f "$src" ] || exit 1
    cat "$src"
    ;;
  *)
    echo "brain $1 is forbidden on the admission gate path" >&2
    exit 90
    ;;
esac
SH
chmod +x "$tmp/bin/brain"

# stdout carries the JSON; the human reason goes to stderr. Keep them apart so
# a refusal message cannot corrupt the parsed report.
run() {
  # run <expected-rc> <fixture-dir> [args...]
  local want="$1" dir="$2"; shift 2
  local out rc
  set +e
  out="$("$bin" --fixture-dir "$dir" --json "$@" 2>"$tmp/stderr.txt")"
  rc=$?
  set -e
  [ "$rc" -eq "$want" ] || fail "expected rc=$want got rc=$rc for [$*]: $out $(cat "$tmp/stderr.txt")"
  printf '%s' "$out"
}

# ---------------------------------------------------------------- admitted
live="$tmp/live"
write_record "$live" <<'REC'
[preference] preference-feature-delivery-portfolio-admission
title:      Feature delivery portfolio admission
---
# Feature delivery portfolio admission

Policy-Version: 1
Primary: north-star-feature-delivery-effective-flow
Secondary: north-star-lastdb-no-scan-access
Paused: all-other-feature-north-stars
Updated-At: 2026-08-31T17:45:00Z
Updated-By: owner
Reason: Permanent feature-delivery repair.
REC

out="$(run 0 "$live" --north-star north-star-feature-delivery-effective-flow)"
printf '%s' "$out" | jq -e '.verdict == "admitted" and .admitted == true' >/dev/null \
  || fail "primary must be admitted: $out"
printf '%s' "$out" | jq -e '.reason | test("primary admission slot")' >/dev/null \
  || fail "primary reason: $out"

out="$(run 0 "$live" --north-star north-star-lastdb-no-scan-access)"
printf '%s' "$out" | jq -e '.verdict == "admitted" and .admitted == true' >/dev/null \
  || fail "secondary must be admitted: $out"
printf '%s' "$out" | jq -e '.reason | test("secondary admission slot")' >/dev/null \
  || fail "secondary reason: $out"

# The gate reads one exact slug. It never enumerates.
printf '%s' "$out" | jq -e --arg s "$slug" '.point_gets == [$s]' >/dev/null \
  || fail "gate must do exactly one point get: $out"
printf '%s' "$out" | jq -e '.brain_searches == [] and .brain_lists == []' >/dev/null \
  || fail "gate must not search or list: $out"

# Case is normalized; a slug is a slug.
run 0 "$live" --north-star NORTH-STAR-FEATURE-DELIVERY-EFFECTIVE-FLOW >/dev/null

# ------------------------------------------------------------------ paused
out="$(run 2 "$live" --north-star north-star-some-other-feature)"
printf '%s' "$out" | jq -e '.verdict == "paused" and .admitted == false' >/dev/null \
  || fail "unlisted outcome must be paused: $out"
printf '%s' "$out" | jq -e '.reason | test("paused for new feature creation")' >/dev/null \
  || fail "paused reason must be clear: $out"
printf '%s' "$out" | jq -e --arg s "$slug" '.reason | test($s)' >/dev/null \
  || fail "paused reason must name the admission record: $out"
grep -q 'paused for new feature creation' "$tmp/stderr.txt" \
  || fail "a refusal must print the reason on stderr: $(cat "$tmp/stderr.txt")"

# A paused outcome can still close, prove, repair, and respond to an incident.
for wc in closeout proof repair incident; do
  out="$(run 0 "$live" --north-star north-star-some-other-feature --work-class "$wc")"
  printf '%s' "$out" | jq -e '.verdict == "ungated" and .gated == false' >/dev/null \
    || fail "work-class $wc must stay ungated: $out"
  printf '%s' "$out" | jq -e '.point_gets == []' >/dev/null \
    || fail "work-class $wc must not read brain: $out"
done

# ----------------------------------------------------------------- missing
missing="$tmp/missing"
mkdir -p "$missing/get"
out="$(run 1 "$missing" --north-star north-star-feature-delivery-effective-flow)"
printf '%s' "$out" | jq -e '.verdict == "missing" and .admitted == false' >/dev/null \
  || fail "missing record must fail closed: $out"
printf '%s' "$out" | jq -e '.reason | test("blocked")' >/dev/null \
  || fail "missing reason must say blocked: $out"

# --------------------------------------------------------------- malformed
malformed_case() {
  local name="$1" dir="$tmp/bad-$1"
  write_record "$dir"
  out="$(run 1 "$dir" --north-star north-star-feature-delivery-effective-flow)"
  printf '%s' "$out" | jq -e '.verdict == "malformed" and .admitted == false' >/dev/null \
    || fail "$name must be malformed: $out"
}

malformed_case no-version <<'REC'
Primary: north-star-feature-delivery-effective-flow
Secondary: north-star-lastdb-no-scan-access
REC

malformed_case bad-version <<'REC'
Policy-Version: draft
Primary: north-star-feature-delivery-effective-flow
REC

malformed_case below-minimum-version <<'REC'
Policy-Version: 0
Primary: north-star-feature-delivery-effective-flow
REC

# Policy-Version is a change counter, not a schema version — a large but
# well-formed counter value must stay admitted (last-stack-portfolio-auto-refill
# bumps it by one on every rewrite; a fixed allowlist would fail-closed the
# whole gate after enough rewrites).
high_version="$tmp/high-version"
write_record "$high_version" <<'REC'
Policy-Version: 7
Primary: north-star-feature-delivery-effective-flow
Secondary: north-star-lastdb-no-scan-access
Paused: all-other-feature-north-stars
REC
out="$(run 0 "$high_version" --north-star north-star-feature-delivery-effective-flow)"
printf '%s' "$out" | jq -e '.verdict == "admitted"' >/dev/null \
  || fail "a high but well-formed Policy-Version must stay admitted: $out"

malformed_case no-primary <<'REC'
Policy-Version: 1
Secondary: north-star-lastdb-no-scan-access
REC

malformed_case empty-primary <<'REC'
Policy-Version: 1
Primary:
Secondary: north-star-lastdb-no-scan-access
REC

malformed_case three-outcomes <<'REC'
Policy-Version: 1
Primary: north-star-a, north-star-b
Secondary: north-star-c
REC

malformed_case duplicate-primary <<'REC'
Policy-Version: 1
Primary: north-star-a
Primary: north-star-b
Secondary: north-star-c
REC

malformed_case secondary-repeats-primary <<'REC'
Policy-Version: 1
Primary: north-star-a
Secondary: north-star-a
REC

# An explicitly empty secondary slot is valid, not malformed.
one_slot="$tmp/one-slot"
write_record "$one_slot" <<'REC'
Policy-Version: 1
Primary: north-star-feature-delivery-effective-flow
Secondary: none
Paused: all-other-feature-north-stars
REC
out="$(run 0 "$one_slot" --north-star north-star-feature-delivery-effective-flow)"
printf '%s' "$out" | jq -e '.secondary == "" and (.admitted_outcomes | length) == 1' >/dev/null \
  || fail "an empty secondary slot admits one outcome: $out"
run 2 "$one_slot" --north-star north-star-lastdb-no-scan-access >/dev/null

# ------------------------------------------------- P0 secondary replacement
# The controller rewrites the record first. Then the replacement is admitted
# and the displaced outcome is paused. The primary never moves.
replaced="$tmp/replaced"
write_record "$replaced" <<'REC'
Policy-Version: 1
Primary: north-star-feature-delivery-effective-flow
Secondary: north-star-p0-incident-recovery
Paused: all-other-feature-north-stars
Updated-At: 2026-08-31T19:00:00Z
Updated-By: routine:pipeline-health
Reason: P0 incident replaces the secondary slot.
REC
run 0 "$replaced" --north-star north-star-p0-incident-recovery >/dev/null
run 0 "$replaced" --north-star north-star-feature-delivery-effective-flow >/dev/null
out="$(run 2 "$replaced" --north-star north-star-lastdb-no-scan-access)"
printf '%s' "$out" | jq -e '.verdict == "paused"' >/dev/null \
  || fail "the displaced secondary must be paused: $out"
printf '%s' "$out" | jq -e '(.admitted_outcomes | length) == 2' >/dev/null \
  || fail "the record still admits exactly two outcomes: $out"

# ------------------------------------------- live brain path: get, not list
export ADMISSION_BRAIN_DIR="$live"
export ADMISSION_BRAIN_LOG="$tmp/brain.log"
: >"$ADMISSION_BRAIN_LOG"
"$bin" --brain "$tmp/bin/brain" \
  --north-star north-star-feature-delivery-effective-flow >/dev/null \
  || fail "live-path admitted call failed"
[ "$(wc -l <"$ADMISSION_BRAIN_LOG" | tr -d ' ')" = "1" ] \
  || fail "expected one brain call: $(cat "$ADMISSION_BRAIN_LOG")"
grep -q "^get $slug" "$ADMISSION_BRAIN_LOG" \
  || fail "brain call must be a point get: $(cat "$ADMISSION_BRAIN_LOG")"
grep -Eq '(^| )(list|search|ask)( |$)' "$ADMISSION_BRAIN_LOG" \
  && fail "gate used a brain list/search: $(cat "$ADMISSION_BRAIN_LOG")"

# A brain that cannot answer is fail-closed, not silently admitted.
export ADMISSION_BRAIN_DIR="$tmp/missing"
set +e
"$bin" --brain "$tmp/bin/brain" \
  --north-star north-star-feature-delivery-effective-flow >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "unreachable brain must exit 1, got $rc"

# --------------------------------------------------- file-pr wiring is real
file_pr="$ROOT/bin/last-stack-kanban-file-pr"
grep -q 'last-stack-feature-portfolio-admission' "$file_pr" \
  || fail "file-pr does not run the admission gate"
grep -q 'last-stack-feature-portfolio-admission' "$ROOT/routines/north-star-driver.md" \
  || fail "north-star-driver does not run the admission gate"
grep -q 'last-stack-feature-portfolio-admission' "$ROOT/routines/milestone-driver.md" \
  || fail "milestone-driver does not run the admission gate"

printf 'ok last-stack-feature-portfolio-admission\n'
