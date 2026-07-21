#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
north="$root/routines/north-star-driver.md"
milestone="$root/routines/milestone-driver.md"
program="$root/routines/program-driver.md"

require() {
  local pattern="$1" file="$2"
  grep -Fq -- "$pattern" "$file" || {
    printf 'missing hierarchical driver contract: %s in %s\n' "$pattern" "$file" >&2
    exit 1
  }
}

require 'Create or update at most **one milestone record** per run.' "$north"
require 'Never create, edit, tag, rank, move, or remove a Kanban card.' "$north"
require 'NORTH_STAR_DRIVER_TARGET' "$north"
require 'NORTH_STAR_DRIVER_REQUEST' "$north"
require 'fkanban milestone add <milestone-slug>' "$north"
require '--driver last-stack-milestone-driver' "$north"
require 'Do **not** pass `--proof-card`' "$north"

require 'sole routine owner for turning' "$milestone"
require 'Create at most **one Kanban card** per run.' "$milestone"
require 'MILESTONE_DRIVER_TARGET' "$milestone"
require 'If the milestone has no `proof_card`' "$milestone"
require '--proof-card <proof-slug> --proof-status pending' "$milestone"
require 'file exactly one PR-sized child' "$milestone"
require 'Never implement product code' "$milestone"

require 'must stay paused' "$program"
require 'superseded-by-north-star-driver-and-milestone-driver' "$program"

printf 'hierarchical driver contract: ok\n'
