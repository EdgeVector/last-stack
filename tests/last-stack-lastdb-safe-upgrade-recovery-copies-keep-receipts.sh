#!/usr/bin/env bash
# Only a PROBE copy leaves out apps/search/inbox/done. Every copy that can
# restore the primary stays a full clone, because `search bootstrap` replays
# done/. The probe-copy test checks the exclusion itself; this test checks where
# the exclusion is allowed to appear.
# papercut-safe-upgrade-probes-copy-search-receipts-20261007
#
# Optional $1 = one case number (1-4). Each failure prints "FAIL: case N ..." so
# a mutation probe can state which case it expects to go red.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
SCRIPTS="$ROOT/skills/lastdb-safe-upgrade/scripts"
DRIVER="$SCRIPTS/safe-upgrade-lastdb.sh"
WRITE_PROBE="$SCRIPTS/write-path-cow-probe.sh"
HELPER='probe_clone_home_without_search_receipts'

ONLY="${1:-}"
CASE=0
fail() { printf 'FAIL: case %s %s\n' "$CASE" "$*" >&2; exit 1; }
want() { CASE="$1"; [ -z "$ONLY" ] || [ "$ONLY" = "$1" ]; }

# Count the lines of a file that call the helper (not the comments about it).
calls_in() { grep -F "$HELPER" "$1" | grep -vc '^[[:space:]]*#' || true; }

if want 1; then
  # The rollback point is the way back from a bad cutover. It is a full clone.
  grep -Fq 'cp -cR "$PRIMARY_HOME" "$BACKUP"' "$DRIVER" \
    || fail 'the rollback point is no longer a full clone of the primary home'
fi

if want 2; then
  # The driver calls the helper once: the metrics probe copy. A second call site
  # is the rollback point or another recovery copy losing done/.
  n="$(calls_in "$DRIVER")"
  [ "$n" = 1 ] || fail "the driver calls $HELPER $n times (want 1: the metrics probe copy)"
  grep -Fq "$HELPER \"\$PRIMARY_HOME\" \"\$copy\"" "$DRIVER" \
    || fail 'the driver metrics probe copy does not use the receipt-free copy'
fi

if want 3; then
  # The DEV photograph copy and every stopped-home script stay full clones.
  for f in dev-photograph-candidate-proof.sh dev-photograph-stamp-gate.sh \
    stopped-home-copy.sh cleanup-stopped-copy.py cleanup-retained-rollback.sh \
    claim-stopped-copy-waiver.py write-stopped-copy-marker.py; do
    [ -f "$SCRIPTS/$f" ] || fail "script $f is absent; update this test"
    if grep -Fq "$HELPER" "$SCRIPTS/$f"; then
      fail "$f uses $HELPER; a copy that can restore the primary must keep done/"
    fi
  done
fi

if want 4; then
  # The write-path probe is a probe, so it uses the helper, once.
  n="$(calls_in "$WRITE_PROBE")"
  [ "$n" = 1 ] || fail "the write-path probe calls $HELPER $n times (want 1)"
fi

printf 'PASS: recovery copies keep Search receipts; probe copies skip them\n'
