---
name: coderings-capstone-exerciser
cadence: daily 07:15 local
description: Read-only CodeRings capstone source check against public LastDB; the synthetic exercise is retired.
---

The synthetic CodeRings capstone exercise was deleted under the no-tests policy.
Do not run, repair, or restore it. Situation: `no-tests-all-repos-20261009`.
This routine keeps only the existing read-only `capstone prove-fold` command.

## Shared contract

Honor `sop-routine-shared-contract` for heartbeat, shell discipline, and primary
safety. The no-tests policy supersedes earlier test requirements in that contract.
Never kill or restart the primary LastDB or Forgejo.

## Procedure

1. Check Situations. If a fence blocks this routine, report blocked and exit.
2. Resolve dedicated CodeRings and public LastDB worktrees with the portal helper.
   Never use a portal directory as a product checkout or borrow an active card's
   worktree. The frozen Fold repo is not a target.
3. Run the existing read-only source check:

   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"
   "$last_stack/bin/last-stack-cli-preflight" bun git

   CODERINGS_PORTAL="${CODERINGS_PORTAL:-$HOME/code/edgevector/coderings}"
   LASTDB_PORTAL="${LASTDB_PORTAL:-$HOME/code/edgevector/lastdb}"
   CODERINGS_WT="$("$last_stack/bin/last-stack-portal-live-checkout" \
     --name coderings-proof-caller "$CODERINGS_PORTAL")"
   LASTDB_LIVE="$("$last_stack/bin/last-stack-portal-live-checkout" \
     --name coderings-prove-lastdb "$LASTDB_PORTAL")"
   cd "$CODERINGS_WT"
   bun src/cli.ts capstone prove-fold --repo "$LASTDB_LIVE" --json
   ```

4. Report the command result and the resolved source paths. A source check does
   not prove a live product result. If a path cannot resolve, report the exact
   failure; do not silently skip the check or start the deleted exercise.
5. For a product-source failure, file a Brain papercut with the command output.
   Do not create a test-repair or de-flake card.

## Heartbeat

Stamp `routine-heartbeats` last with `ok|noop|error` and a one-line detail.
Include `prove-fold=ok|failed|resolve-failed`. Use `ok` only when the source check
ran successfully. Do not report the retired synthetic exercise as a pass.
