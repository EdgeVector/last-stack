#!/usr/bin/env bash
# Contract: the safe `--json` capture form reaches every agent BEFORE a denial.
#
# Window 2026-09-07 self-improvement-loop: the unsafe-inline-json hook denied a
# merged stderr stream 135 times in 118 distinct Claude sessions in 24h
# (situations 67, kanban 42, routines 13). The guard was correct; no document
# taught the safe form, so each agent learned it only from the deny text.
# This test pins the instruction file and its setup wiring.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd -P)"
doc="$root/instructions/safe-json-capture.md"
setup="$root/setup"
helper="$root/bin/last-stack-json-capture"

fail() {
  printf 'safe-json-capture-docs: %s\n' "$1" >&2
  exit 1
}

require() {
  local pattern="$1"
  local file="$2"
  grep -Fq -- "$pattern" "$file" || fail "missing '$pattern' in $file"
}

[ -f "$doc" ] || fail "missing $doc"
[ -f "$setup" ] || fail "missing $setup"
[ -x "$helper" ] || fail "missing or non-executable $helper"

# The doc names the denied shapes and the safe replacement.
require '2>&1 | jq' "$doc"
require 'last-stack-json-capture /tmp/sit.json -- situations list --json' "$doc"
require '<file>.err' "$doc"
require '$HOME/.last-stack/bin/last-stack-json-capture' "$doc"
require 'last-stack-json-get' "$doc"
require 'json-guard-ok' "$doc"

# setup installs the block into every harness instruction file, and strips it
# first so a re-run stays byte-identical.
require "JC_START='<!-- last-stack:safe-json-capture:start" "$setup"
require "JC_END='<!-- last-stack:safe-json-capture:end -->'" "$setup"
require 'strip_managed_md_block "$file" "$JC_START" "$JC_END"' "$setup"
require 'append_managed_md_block "$file" "$SOURCE_ROOT/instructions/safe-json-capture.md" "$JC_START" "$JC_END"' "$setup"

# The helper the doc prescribes must actually accept that call shape.
scratch="$(mktemp -d "${TMPDIR:-/tmp}/safe-json-capture.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT
"$helper" "$scratch/ok.json" -- printf '{"a":1}\n' >/dev/null 2>&1 \
  || fail "helper rejected the documented call shape"
[ -f "$scratch/ok.json" ] || fail "helper wrote no output file"
[ -f "$scratch/ok.json.err" ] || fail "helper wrote no <file>.err companion"
grep -Fq '"a"' "$scratch/ok.json" || fail "helper output file is not the command stdout"

echo "ok last-stack-safe-json-capture-docs"
