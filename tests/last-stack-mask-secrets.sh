#!/usr/bin/env bash
# Probe for brain papercut-routine-shell-exports-raw-openrouter-secret.
#
# Failure invariant under test: a secret-shaped environment variable must
# never appear as plaintext in the stdout/stderr of a routine diagnostic,
# regardless of which diagnostic prints it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
MASK="$ROOT/bin/last-stack-mask-secrets"
DUMP="$ROOT/bin/last-stack-env-dump"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-mask-secrets.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# The exact fixture named on the card: a secret-shaped variable carrying a
# canary value that must never survive the diagnostic.
canary='canary-not-a-real-secret-4f3a2b1c9d8e'
export FOLD_OPENROUTER_API_KEY="$canary"
export ORDINARY_VARIABLE='cargo-build-plain-value'

# --- red before -----------------------------------------------------------
# Pin the defect this helper exists to fix. A bare env dump - the thing the
# 2026-08-18 run actually executed - does print the raw credential. If this
# assertion ever fails, the environment no longer carries raw secrets and the
# card's first END STATE clause has landed; revisit this probe then.
env | grep -Fq "$canary" || fail "fixture did not reach a bare env dump"

# --- green after: the safe dump -------------------------------------------
"$DUMP" >"$WORK/dump.txt" 2>"$WORK/dump.err" || fail "env-dump exited nonzero"
if grep -Fq "$canary" "$WORK/dump.txt" "$WORK/dump.err"; then
  fail "raw credential survived last-stack-env-dump"
fi
grep -q '^FOLD_OPENROUTER_API_KEY=<redacted:FOLD_OPENROUTER_API_KEY>$' "$WORK/dump.txt" \
  || fail "masked placeholder missing for FOLD_OPENROUTER_API_KEY"
grep -q '^ORDINARY_VARIABLE=cargo-build-plain-value$' "$WORK/dump.txt" \
  || fail "non-secret variable was altered"

# The filtered form the incident used must be masked too.
"$DUMP" CARGO RUST FOLD >"$WORK/filtered.txt" 2>&1 || fail "filtered dump failed"
grep -Fq "$canary" "$WORK/filtered.txt" && fail "raw credential survived a filtered dump"
grep -q '^FOLD_OPENROUTER_API_KEY=<redacted:FOLD_OPENROUTER_API_KEY>$' "$WORK/filtered.txt" \
  || fail "filtered dump dropped the masked variable"
grep -q 'ORDINARY_VARIABLE' "$WORK/filtered.txt" && fail "name filter leaked a non-matching variable"

# --- value pass: the credential without its name attached -----------------
printf 'openrouter call failed using key %s at 00:00Z\n' "$canary" \
  | "$MASK" >"$WORK/prose.txt"
grep -Fq "$canary" "$WORK/prose.txt" && fail "value pass missed a bare credential in prose"
grep -q '<redacted:FOLD_OPENROUTER_API_KEY>' "$WORK/prose.txt" \
  || fail "value pass did not mark the redaction"

# --- assignment pass: a foreign log this process has no variable for ------
# Fixture values are deliberately NOT token-shaped. The assertion is about
# the secret-shaped NAME driving the redaction, and a realistic token
# literal would trip bin/last-stack-lint-machine-leaks in this same gate.
unset SOME_OTHER_SERVICE_TOKEN || true
cat >"$WORK/foreign.log" <<'LOG'
SOME_OTHER_SERVICE_TOKEN=FIXTURE-SERVICE-VALUE-ONE
export ANOTHER_API_KEY=raw-value-here
{"GITHUB_TOKEN": "FIXTURE-FORGE-VALUE-THREE"}
PATH=/usr/bin:/bin
LOG
"$MASK" <"$WORK/foreign.log" >"$WORK/foreign.masked"
for leaked in 'FIXTURE-SERVICE-VALUE-ONE' 'raw-value-here' 'FIXTURE-FORGE-VALUE-THREE'; do
  grep -Fq "$leaked" "$WORK/foreign.masked" \
    && fail "assignment pass missed $leaked"
done
grep -q '^PATH=/usr/bin:/bin$' "$WORK/foreign.masked" \
  || fail "assignment pass altered a non-secret variable"

# --- locators stay readable ----------------------------------------------
printf 'OBS_SENTRY_DSN=lastsecrets://public-observability-locator\n' >"$WORK/locator.txt"
printf 'SOME_API_KEY=lastsecrets://a-locator-not-a-value\n' >>"$WORK/locator.txt"
"$MASK" <"$WORK/locator.txt" >"$WORK/locator.masked"
grep -q 'lastsecrets://public-observability-locator' "$WORK/locator.masked" \
  || fail "allowlisted locator variable was masked"
grep -q 'lastsecrets://a-locator-not-a-value' "$WORK/locator.masked" \
  || fail "a lastsecrets locator is not a secret value and must stay readable"

# --- a short value must not blank unrelated text --------------------------
DEBUG_TOKEN=1 "$MASK" <<'SHORT' >"$WORK/short.txt"
there was 1 error and 1 warning
SHORT
grep -q '^there was 1 error and 1 warning$' "$WORK/short.txt" \
  || fail "a short secret value corrupted unrelated output"

echo "PASS last-stack-mask-secrets"
