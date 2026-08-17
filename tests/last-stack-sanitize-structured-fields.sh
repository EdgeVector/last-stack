#!/usr/bin/env bash
# Drive the shipped sanitizer — the same functions closeout and card-closeout use.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
lib="$ROOT/lib/sanitize_structured_fields.py"
[ -f "$lib" ] || { echo "missing $lib" >&2; exit 1; }
python3 "$lib" --self-test

dirty='lastgit://last-stack/cr/cr-mskqwa3y-78c9`'
got="$(python3 "$lib" pr-url "$dirty")"
want="lastgit://last-stack/cr/cr-mskqwa3y-78c9"
if [ "$got" != "$want" ]; then
  echo "FAIL: CLI pr-url sanitize: got $got want $want" >&2
  exit 1
fi
got="$(python3 "$lib" north-star '`north-star-org-cloud-principal-membership`')"
want="north-star-org-cloud-principal-membership"
if [ "$got" != "$want" ]; then
  echo "FAIL: CLI north-star sanitize: got $got want $want" >&2
  exit 1
fi
echo "ok last-stack-sanitize-structured-fields"
