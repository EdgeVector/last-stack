#!/usr/bin/env bash
# Run both feature drivers' admission gate against one admitted and one paused
# fixture. The paused fixture must create no milestone and no Kind:pr card.
#
# The gate command is extracted from each prompt, so prompt drift fails here.
# decision-2026-08-31-two-admitted-feature-outcomes
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

north="$ROOT/routines/north-star-driver.md"
milestone="$ROOT/routines/milestone-driver.md"
gate="$ROOT/bin/last-stack-feature-portfolio-admission"
file_pr="$ROOT/bin/last-stack-kanban-file-pr"
slug="preference-feature-delivery-portfolio-admission"

# Each prompt must invoke the gate with the feature work class.
for prompt in "$north" "$milestone"; do
  grep -q 'last-stack-feature-portfolio-admission' "$prompt" \
    || fail "$(basename "$prompt") does not call the admission gate"
  grep -q -- '--work-class feature' "$prompt" \
    || fail "$(basename "$prompt") does not gate the feature work class"
  grep -q -- '--north-star' "$prompt" \
    || fail "$(basename "$prompt") does not pass a north star to the gate"
  # The gate must be a point get. A prompt must never rank admission off a list.
  grep -q 'Never use a Brain list or a Brain' "$prompt" \
    || fail "$(basename "$prompt") does not forbid list/search as the gate"
done

# The north-star driver must stop the pass when the gate refuses.
grep -q 'if \[ "\$admission_rc" -ne 0 \]; then' "$north" \
  || fail "north-star-driver does not branch on the admission exit code"
grep -q 'skip_new_cards=1' "$milestone" \
  || fail "milestone-driver does not skip new cards on a refusal"

admitted_ns="north-star-feature-delivery-effective-flow"
paused_ns="north-star-some-paused-feature"

fixture="$tmp/fixture"
mkdir -p "$fixture/get"
cat >"$fixture/get/$slug.txt" <<REC
[preference] $slug
title:      Feature delivery portfolio admission
---
Policy-Version: 1
Primary: $admitted_ns
Secondary: north-star-lastdb-no-scan-access
Paused: all-other-feature-north-stars
Updated-At: 2026-08-31T17:45:00Z
REC
export LAST_STACK_ADMISSION_FIXTURE="$fixture"
export LAST_STACK_DECISION_FIXTURE="$tmp/empty-decision"
mkdir -p "$tmp/empty-decision"

# ------------------------------------------- north-star driver: milestone add
mkdir -p "$tmp/bin"
: >"$tmp/milestone-add.log"
cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "milestone" ] && [ "${2:-}" = "add" ]; then
  printf '%s\n' "$*" >>"$DRIVER_MS_ADD_LOG"
  exit 0
fi
if [ "${1:-}" = "milestone" ] && [ "${2:-}" = "show" ]; then
  printf '{"slug":"%s","state":"active","north_star":"%s"}\n' "${3:-}" "${DRIVER_MS_NS:-}"
  exit 0
fi
if [ "${1:-}" = "add" ]; then
  printf '%s\n' "$*" >>"$DRIVER_CARD_ADD_LOG"
  cat >/dev/null
  exit 0
fi
echo "unexpected kanban $*" >&2
exit 1
SH
chmod +x "$tmp/bin/kanban"
export DRIVER_MS_ADD_LOG="$tmp/milestone-add.log"
export DRIVER_CARD_ADD_LOG="$tmp/card-add.log"
: >"$DRIVER_CARD_ADD_LOG"

# The north-star driver contract: gate, then create only on rc=0.
# `|| rc=$?` keeps errexit intact; toggling `set -e` inside a function leaks
# the setting back to the caller and kills the run on the first refusal.
north_star_driver_pass() {
  local ns="$1" rc=0
  "$gate" --north-star "$ns" --work-class feature --json >/dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    return "$rc"
  fi
  "$tmp/bin/kanban" milestone add "ms-for-$ns" --north-star "$ns" --state planned
}

north_star_driver_pass "$admitted_ns" || fail "admitted north star must create a milestone"
grep -q "ms-for-$admitted_ns" "$DRIVER_MS_ADD_LOG" \
  || fail "admitted fixture created no milestone: $(cat "$DRIVER_MS_ADD_LOG")"

: >"$DRIVER_MS_ADD_LOG"
paused_rc=0
north_star_driver_pass "$paused_ns" || paused_rc=$?
[ "$paused_rc" -eq 2 ] || fail "paused north star must refuse with rc=2, got $paused_rc"
if [ -s "$DRIVER_MS_ADD_LOG" ]; then fail "paused fixture created a milestone: $(cat "$DRIVER_MS_ADD_LOG")"; fi

# A missing admission record blocks creation too.
: >"$DRIVER_MS_ADD_LOG"
mkdir -p "$tmp/no-record/get"
missing_rc=0
LAST_STACK_ADMISSION_FIXTURE="$tmp/no-record" \
  north_star_driver_pass "$admitted_ns" || missing_rc=$?
[ "$missing_rc" -eq 1 ] || fail "a missing record must fail closed with rc=1, got $missing_rc"
if [ -s "$DRIVER_MS_ADD_LOG" ]; then fail "missing record created a milestone: $(cat "$DRIVER_MS_ADD_LOG")"; fi

# ------------------------------------------ milestone driver: Kind:pr filing
body="$tmp/body.md"
cat >"$body" <<'BODY'
**Follow the kanban-agent skill — drive this through to a MERGED PR.**

Repo: EdgeVector/last-stack
Base: main
Kind: pr

## GOAL
Prove the admission gate on the filing boundary.

## END STATE
A paused outcome files no Kind:pr card.
BODY

: >"$DRIVER_CARD_ADD_LOG"
DRIVER_MS_NS="$admitted_ns" "$file_pr" admitted-slice \
  --board-cli "$tmp/bin/kanban" --title "Admitted slice" \
  --repo EdgeVector/last-stack --north-star "$admitted_ns" \
  --milestone ms-admitted <"$body" >/dev/null \
  || fail "admitted north star must file a Kind:pr card"
grep -q 'admitted-slice' "$DRIVER_CARD_ADD_LOG" \
  || fail "admitted fixture filed no card: $(cat "$DRIVER_CARD_ADD_LOG")"

: >"$DRIVER_CARD_ADD_LOG"
set +e
DRIVER_MS_NS="$paused_ns" "$file_pr" paused-slice \
  --board-cli "$tmp/bin/kanban" --title "Paused slice" \
  --repo EdgeVector/last-stack --north-star "$paused_ns" \
  --milestone ms-paused <"$body" >/dev/null 2>"$tmp/paused.err"
paused_file_rc=$?
set -e
[ "$paused_file_rc" -eq 2 ] || fail "paused filing must exit 2, got $paused_file_rc"
grep -q 'admission refused' "$tmp/paused.err" \
  || fail "paused filing message: $(cat "$tmp/paused.err")"
if [ -s "$DRIVER_CARD_ADD_LOG" ]; then fail "paused fixture filed a card: $(cat "$DRIVER_CARD_ADD_LOG")"; fi

printf 'ok last-stack-driver-admission-fixture\n'
