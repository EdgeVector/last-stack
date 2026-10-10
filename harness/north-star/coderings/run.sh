#!/usr/bin/env bash
# north-star-slug: north-star-coderings
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-coderings
REPO="$(ns_repo_path coderings)"
if [ ! -f "$REPO/package.json" ]; then
  ns_write_report "$SLUG" FAIL "The product source is absent: $REPO/package.json"
  exit 1
fi
ns_write_report "$SLUG" PASS-OFFLINE "The product source is present: $REPO/package.json.
Situation no-tests-all-repos-20261009 removes the old fixture or test-suite command.
This source check does not prove the live result."
