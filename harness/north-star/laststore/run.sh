#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

SLUG=north-star-laststore-is-document-store-last-db-is-conventions
MODE="$(ns_mode)"

fail() {
  ns_write_report "$SLUG" FAIL "$1" || exit 1
  exit 1
}

record_from_file() {
  local path="$1"
  [ -f "$path" ] || fail "record fixture missing: $path"
  sed -n '1,$p' "$path"
}

record_from_brain() {
  if command -v fbrain >/dev/null 2>&1; then
    fbrain get "$SLUG" --type project
  elif command -v brain >/dev/null 2>&1; then
    brain get "$SLUG"
  else
    return 127
  fi
}

record=""
source_label=""
if [ -n "${LASTSTORE_PROOF_RECORD_FILE:-}" ]; then
  source_label="fixture:$LASTSTORE_PROOF_RECORD_FILE"
  record="$(record_from_file "$LASTSTORE_PROOF_RECORD_FILE")"
else
  source_label="brain:$SLUG"
  if ! record="$(record_from_brain 2>&1)"; then
    fail "could not read authoritative North Star record from Brain; set LASTSTORE_PROOF_RECORD_FILE for an offline fixture.

Brain read output:
\`\`\`text
$record
\`\`\`"
  fi
fi

require_text() {
  local pattern="$1" label="$2"
  if ! grep -Eiq "$pattern" <<<"$record"; then
    fail "missing Last Store abstraction contract: $label

Source: $source_label"
  fi
}

reject_text() {
  local pattern="$1" label="$2"
  if grep -Eiq "$pattern" <<<"$record"; then
    fail "inverted or unsafe abstraction wording found: $label

Source: $source_label"
  fi
}

require_text 'Last Store[^[:alnum:]]+is[^\n]*(multi-collection )?document store|Last Store[[:space:][:punct:]]+Dumb durable docs' 'Last Store is the document engine'
require_text 'LastDB[^[:alnum:]]+is[^\n]*convention of collections, ids, and documents|LastDB product[[:space:][:punct:]]+Tip id layout' 'LastDB is conventions on top'
require_text 'collections, ids, bodies|put/get/delete|prefix (walk|list)' 'engine primitives stay collection/id/document oriented'
require_text 'schemas|atoms|tips|tip.*atom|hash-range|B-tree-as-docs|upper-layer walk logic' 'schemas, tips, indexes, and list logic stay above the engine'
require_text 'Mini packaging|Mini[^[:alnum:]]+Last Store path|Mini cutover migration|not product (holes|incompleteness)' 'Mini gaps are packaging/adapter/migration work, not LastDB product incompleteness'
require_text 'reference-laststore-collection-naming|storage-v2\.md|north-star-lastdb-no-sled-document-store' 'record links the durable design/reference context'
require_text 'Do not invent[^.\n]*catch-all collection `?main`?|catch-all collection `?main`?[^.\n]*Non-goals' 'new Storage v2 work rejects catch-all main'

reject_text 'LastDB[^.\n]*(is|as)[^.\n]*(multi-collection )?document store' 'LastDB described as the document engine'
reject_text 'Last Store[^.\n]*(is|as)[^.\n]*convention of collections' 'Last Store described as upper-layer conventions'
reject_text 'Mini gaps (are|remain)[^.\n]*LastDB product incompleteness|classified as LastDB product incompleteness|framed as LastDB product incompleteness' 'Mini gaps framed as LastDB product incompleteness'

notes="$(cat <<EOF
Last Store abstraction proof source verified.

Source: $source_label
Mode: $MODE

Covered invariants:
- Last Store is the multi-collection document engine.
- LastDB is collection/id/document conventions on top of that engine.
- Schemas, atoms, tips, molecules, hash-range pages, and B-tree navigation remain upper-layer documents and logic.
- Mini gaps are classified as Mini packaging, adapter, or cutover migration work.
- The record links durable design/reference context and rejects a catch-all \`main\` collection for new Storage v2 work.
EOF
)"

verdict=PASS
[ "$MODE" = offline ] && verdict=PASS-OFFLINE
ns_write_report "$SLUG" "$verdict" "$notes"
