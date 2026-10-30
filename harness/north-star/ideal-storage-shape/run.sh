#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-ideal-storage-shape
# Keep the retired contract registered with an explicit failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

body="The storage-shape contract for this North Star is retired.
Old receipt files do not establish the current engine's result.
Use the current LastDB CI disk, native-node, and latency results for review.
A current terminal contract remains required before this North Star can pass.
This command does not read a database, execute a product, or accept evidence files."

ns_write_report north-star-lastdb-ideal-storage-shape FAIL "$body" || exit 1
exit 1
