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
require 'Creation inventory gate' "$north"
require 'fkanban list --column backlog --json' "$north"
require 'fkanban list --column todo --json' "$north"
require 'fkanban list --column doing --json' "$north"
require "printf 'CREATION_INVENTORY backlog=%s todo=%s doing=%s nonterminal_milestones=%s" "$north"
require 'repeat all four inventory reads' "$north"
require 'do not impose a new global todo cap' "$north"
require 'fkanban milestone add <milestone-slug>' "$north"
require '--driver last-stack-milestone-driver' "$north"
require 'Do **not** pass `--proof-card`' "$north"

require 'sole routine owner for turning' "$milestone"
require 'Create at most **one Kanban card** per run.' "$milestone"
require 'MILESTONE_DRIVER_TARGET' "$milestone"
require 'Creation inventory gate' "$milestone"
require 'fkanban list --column backlog --json' "$milestone"
require 'fkanban list --column todo --json' "$milestone"
require 'fkanban list --column doing --json' "$milestone"
require "printf 'CREATION_INVENTORY backlog=%s todo=%s doing=%s nonterminal_milestones=%s" "$milestone"
require 'Immediately before any `fkanban add`, repeat all four inventory reads' "$milestone"
require 'noop existing-live-frontier' "$milestone"
require 'Targeted dispatch is an absolute selection gate' "$milestone"
require 'Do not select,' "$milestone"
require 'Skip the portfolio-ranking procedure' "$milestone"
require 'Targeting never relaxes blockers,' "$milestone"
require 'Reconciliation is a read-only lifecycle report' "$milestone"
require 'fkanban milestone state <slug> complete --proof-status passing --json' "$milestone"
require 'The CLI rejects this transition unless the proof contract passes.' "$milestone"
require 'If the milestone has no `proof_card`' "$milestone"
require '--proof-card <proof-slug> --proof-status pending' "$milestone"
require 'file exactly one PR-sized child' "$milestone"
require 'Never implement product code' "$milestone"
# Factory-fill contract (2026-07-22 tightened): empty todo is starvation; don't
# burn the pass on proof-only scaffolding under pressure.
require 'Factory-fill contract' "$milestone"
require 'idle_hint=starving' "$milestone"
require 'portfolio-not-feedable' "$milestone"
require 'Pickup only eats `todo`' "$milestone"
require 'Body-level stops count as holds' "$milestone"

inventory_line="$(grep -nF 'Creation inventory gate' "$milestone" | cut -d: -f1 | head -1)"
target_line="$(grep -nF 'Targeted dispatch is an absolute selection gate' "$milestone" | cut -d: -f1)"
portfolio_line="$(grep -nF 'fkanban milestone portfolio --json' "$milestone" | cut -d: -f1)"
if (( inventory_line >= target_line )); then
  printf 'creation inventory must precede the targeted selection gate\n' >&2
  exit 1
fi
if (( portfolio_line >= target_line )); then
  printf 'milestone inventory must precede the targeted selection gate\n' >&2
  exit 1
fi

require 'must stay paused' "$program"
require 'superseded-by-north-star-driver-and-milestone-driver' "$program"

printf 'hierarchical driver contract: ok\n'
