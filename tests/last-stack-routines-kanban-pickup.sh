#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pickup="$ROOT/routines/kanban-pickup.md"

grep -q 'The candidate is pickup work with `Kind: pr`' "$pickup"
grep -q 'Existing terminal, capstone, tracker, meta, or validation cards stay in' "$pickup"
grep -q 'pickup must not force them into `todo`' "$pickup"
grep -q 'file a concrete `Kind: pr` follow-up' "$pickup"
grep -q 'fresh budget' "$pickup"
grep -q 'last-stack-park-terminal-validation-todo' "$pickup"
grep -q 'excludes `Kind: pr`' "$pickup"
grep -q 'idle=terminal-validation-parked' "$pickup"
grep -q 'Continue to idle mode only when the helper reports zero changes' "$pickup"
grep -q 'Only `Kind: pr` child frontiers are pickup work' "$pickup"
grep -q 'terminal proof card already drifted into default `todo`' "$pickup"
grep -q 'Direct `prompt_path` freshness guard' "$pickup"
grep -q 'last-stack-self-upgrade" --check-only --reason=kanban-pickup-prompt-freshness' "$pickup"
grep -q 'stale-last-stack-install upgraded-before-claim no_card_claimed' "$pickup"
grep -q 'stale-last-stack-install upgrade-failed no_card_claimed' "$pickup"

echo ok
