#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pickup="$ROOT/routines/kanban-pickup.md"
gate="$ROOT/bin/last-stack-kanban-pickup-gate"

test -x "$gate"
grep -q 'exit 10' "$gate"
grep -q 'pickup status --json' "$gate"
grep -q 'ready=0' "$gate"

grep -q 'The candidate is pickup work with `Kind: pr`' "$pickup"
grep -q 'Existing terminal, capstone, tracker, meta, or validation cards stay in' "$pickup"
grep -q 'pickup must not force them into `todo`' "$pickup"
grep -q 'file a concrete `Kind: pr` follow-up' "$pickup"
grep -q 'fresh budget' "$pickup"
grep -q 'last-stack-park-terminal-validation-todo' "$pickup"
grep -q 'last-stack-park-stuck-merge-poison-cards' "$pickup"
grep -q 'last-stack-lastgit-ci-coverage' "$pickup"
grep -q 'Park stuck-merge poison cards before claim' "$pickup"
grep -q 'excludes `Kind: pr`' "$pickup"
grep -q 'idle=terminal-validation-parked' "$pickup"
grep -q 'Continue to idle mode only when the helper reports zero changes' "$pickup"
grep -q 'Only `Kind: pr` child frontiers are pickup work' "$pickup"
grep -q 'terminal proof card already drifted into default `todo`' "$pickup"
grep -q 'Direct `prompt_path` freshness guard' "$pickup"
grep -q 'last-stack-self-upgrade" --check-only --reason=kanban-pickup-prompt-freshness' "$pickup"
grep -q 'stale-last-stack-install class-a-heal-failed no_card_claimed' "$pickup"
grep -q 'stale-last-stack-install class-a-heal-timeout no_card_claimed' "$pickup"
grep -q 'Ready-queue credit gate' "$pickup"
grep -q 'gateProceeded' "$pickup"
grep -q 'last-stack-kanban-pickup-gate' "$pickup"
grep -q 'ready=0' "$pickup"
grep -q 'last-stack-pickup-work-policy' "$pickup"
grep -q 'forbids WORK on a cooldown slug' "$pickup"
grep -q 'PICKUP_GATE_PROCEED' "$gate"
if grep -q 'TODO_INVENTORY count=' "$gate"; then
  echo "gate still proceeds from TODO_INVENTORY" >&2
  exit 1
fi
grep -q 'Default: `exit`' "$pickup"
grep -q 'Idle mode: smart-heal' "$pickup"
grep -q 'opt-in only' "$pickup"

echo ok
