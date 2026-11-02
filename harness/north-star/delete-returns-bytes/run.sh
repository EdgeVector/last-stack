#!/usr/bin/env bash
# north-star-slug: north-star-lastdb-delete-returns-the-bytes
# Keep the retired contract registered with an explicit failure.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

body="The delete contract for this North Star is retired.
Its gates read the frozen fold source of the retired storage model.
LastDB stores one record per key now, so those gates do not establish the current engine's result.
A current terminal contract remains required before this North Star can pass.
This command does not read a database, execute a product, or accept evidence files."

ns_write_report north-star-lastdb-delete-returns-the-bytes FAIL "$body" || exit 1
exit 1
