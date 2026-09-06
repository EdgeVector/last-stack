#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
north="$root/routines/north-star-driver.md"
milestone="$root/routines/milestone-driver.md"
milestone_snapshot="$root/bin/last-stack-milestone-driver-snapshot"
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
require 'kanban list --column backlog --json' "$north"
require 'kanban list --column todo --json' "$north"
require 'kanban list --column doing --json' "$north"
require "printf 'CREATION_INVENTORY backlog=%s todo=%s doing=%s nonterminal_milestones=%s" "$north"
require 'repeat all four inventory reads' "$north"
require 'do not impose a new global todo cap' "$north"
require 'kanban milestone add <milestone-slug>' "$north"
require '--driver last-stack-milestone-driver' "$north"
require 'Do **not** pass `--proof-card`' "$north"

require 'MILESTONE_DRIVER_TARGET' "$milestone"
require 'Creation inventory gate' "$milestone"
require 'last-stack-milestone-driver-snapshot' "$milestone"
require '"$kanban_bin" list --column backlog --json' "$milestone_snapshot"
require '"$kanban_bin" list --column todo --json' "$milestone_snapshot"
require '"$kanban_bin" list --column doing --json' "$milestone_snapshot"
require '"$kanban_bin" milestone portfolio --json' "$milestone_snapshot"
require "printf 'CREATION_INVENTORY backlog=%s todo=%s doing=%s nonterminal_milestones=%s" "$milestone"
require 'Run each board mutation through the snapshot helper' "$milestone"
require 'preflight_succeeded_epoch' "$milestone_snapshot"
require 'error=stale-or-invalid-artifact' "$milestone_snapshot"
require 'Targeted dispatch is an absolute selection gate' "$milestone"
require 'Skip the portfolio-ranking procedure' "$milestone"
require 'Targeting never relaxes blockers' "$milestone"
require 'read-only lifecycle report' "$milestone"
require 'kanban milestone state <slug> complete --proof-status passing --json' "$milestone"
require 'The CLI rejects this transition unless the proof contract passes.' "$milestone"
require 'Never implement product code' "$milestone"
require 'Create at most **one Kanban card** per run.' "$milestone"

# Deterministic gap-report orchestrator (Tom 2026-07-22)
require 'kanban milestone gap-report --json' "$milestone"
require 'thin orchestrator' "$milestone"
require 'SAFETY_CAP=8' "$milestone"
require 'GAP_FILL IDLE_MILESTONES=' "$milestone"
require 'work_queue' "$milestone"
require 'idle_empty' "$milestone"
require 'idle_promoteable' "$milestone"
require 'Trust the report' "$milestone"
require 'gap-report-unavailable-upgrade-fkanban' "$milestone"
require 'File every next-gate PR' "$milestone"
require 'last-stack-kanban-file-pr' "$milestone"
require 'last-stack-kanban-decision-check' "$milestone"
require '--milestone' "$milestone"
require '--north-star' "$milestone"
require 'unattached-outcome' "$milestone"

snapshot_line="$(grep -nF 'snapshot_result=' "$milestone" | cut -d: -f1 | head -1)"
inventory_line="$(grep -nF 'Creation inventory gate' "$milestone" | cut -d: -f1 | head -1)"
target_line="$(grep -nF 'Targeted dispatch is an absolute selection gate' "$milestone" | cut -d: -f1)"
if (( snapshot_line >= inventory_line )); then
  printf 'run snapshot must precede creation inventory consumption\n' >&2
  exit 1
fi
if (( inventory_line >= target_line )); then
  printf 'creation inventory must precede the targeted selection gate\n' >&2
  exit 1
fi

# Two-outcome portfolio admission (decision-2026-08-31-two-admitted-feature-outcomes)
require 'Portfolio admission gate' "$north"
require 'last-stack-feature-portfolio-admission' "$north"
require '--work-class feature' "$north"
require 'admission-record-unreadable' "$north"
require 'admission-paused' "$north"
require 'never admits a third outcome' "$north"

require 'Portfolio admission gate' "$milestone"
require 'last-stack-feature-portfolio-admission' "$milestone"
require '--work-class feature' "$milestone"
require 'admission-record-unreadable' "$milestone"
require 'admission-paused' "$milestone"

# A stale papercut or design cannot create work before current main, merged
# reviews, closeouts, and driver memory pass the satisfaction check.
require 'Shipped-slice satisfaction gate' "$milestone"
require 'last-stack-milestone-slice-satisfaction' "$milestone"
require 'SATISFACTION-CHECK' "$milestone"
require 'already-satisfied' "$milestone"
require '.remaining_clauses' "$milestone"
require 'Point-read the merged reviews' "$milestone"
require 'Point-read the known closeout cards' "$milestone"
require 'Automation memory:' "$milestone"

# The admission gate must be decided before the driver creates anything.
north_admission_line="$(grep -nF 'Portfolio admission gate' "$north" | cut -d: -f1 | head -1)"
north_create_line="$(grep -nF 'kanban milestone add <milestone-slug>' "$north" | cut -d: -f1 | head -1)"
if (( north_admission_line >= north_create_line )); then
  printf 'admission gate must precede milestone creation\n' >&2
  exit 1
fi

ms_admission_line="$(grep -nF 'Portfolio admission gate' "$milestone" | cut -d: -f1 | head -1)"
ms_file_line="$(grep -nF 'last-stack-kanban-file-pr' "$milestone" | cut -d: -f1 | tail -1)"
if (( ms_admission_line >= ms_file_line )); then
  printf 'admission gate must precede Kind:pr filing\n' >&2
  exit 1
fi

ms_satisfaction_line="$(grep -nF 'Shipped-slice satisfaction gate' "$milestone" | cut -d: -f1 | head -1)"
if (( ms_satisfaction_line >= ms_file_line )); then
  printf 'satisfaction gate must precede Kind:pr filing\n' >&2
  exit 1
fi

require 'must stay paused' "$program"
require 'superseded-by-north-star-driver-and-milestone-driver' "$program"

printf 'hierarchical driver contract: ok\n'
