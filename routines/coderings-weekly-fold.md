---
name: coderings-weekly-fold
cadence: weekly Monday 09:15 local
description: Weekly fold growth scan. Prefer dry-run until store policy is confirmed; material growth may file one deduped card.
---

You are the scheduled **coderings-weekly-fold** routine.

## Shared contract
Honor `sop-routine-shared-contract`. Never kill/restart primary brain or forgejo.

## Portal model (won't-undo)

`~/code/edgevector/<repo>` is a **portal**, not a product checkout — no `.git`,
no source. Do **not** pass `$HOME/code/edgevector/fold` (or any other portal
path) to `--repo`. Resolve a real checkout or the bare mirror first.

## Procedure
1. Situation fence check; exit cleanly if blocked.
2. Resolve CodeRings + fold inputs (fail loudly if either is missing):
   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude"

   # CodeRings itself is a portal — start a disposable worktree.
   CODERINGS_PORTAL="${CODERINGS_PORTAL:-$HOME/code/edgevector/coderings}"
   if [ ! -x "$CODERINGS_PORTAL/bin/wt" ]; then
     echo "RESULT: error reason=coderings-portal-missing path=$CODERINGS_PORTAL"
     exit 1
   fi
   CODERINGS_WT="$("$CODERINGS_PORTAL/bin/wt" start coderings-weekly-fold 2>/dev/null | tail -1)"
   # Prefer path verb when start only prints status noise
   if [ ! -d "${CODERINGS_WT:-}/src" ]; then
     CODERINGS_WT="$("$CODERINGS_PORTAL/bin/wt" path 2>/dev/null | tail -1)"
   fi
   if [ ! -f "${CODERINGS_WT:-}/src/cli.ts" ]; then
     echo "RESULT: error reason=no-coderings-worktree"
     exit 1
   fi

   # Fold scan target: prefer bare mirror (coderings only needs git objects).
   FOLD_MIRROR="${FOLD_MIRROR:-$HOME/.cache/edgevector-git/fold.git}"
   FOLD_REPO=""
   if [ -d "$FOLD_MIRROR" ] && git -C "$FOLD_MIRROR" rev-parse --git-dir >/dev/null 2>&1; then
     git -C "$FOLD_MIRROR" fetch --quiet origin 2>/dev/null || true
     FOLD_REPO="$FOLD_MIRROR"
   else
     # Fallback: portal worktree for fold
     FOLD_PORTAL="${FOLD_PORTAL:-$HOME/code/edgevector/fold}"
     if [ -x "$FOLD_PORTAL/bin/wt" ]; then
       FOLD_REPO="$("$FOLD_PORTAL/bin/wt" start coderings-weekly-fold-target 2>/dev/null | tail -1)"
       if [ ! -d "${FOLD_REPO:-}/.git" ] && [ ! -f "${FOLD_REPO:-}/.git" ]; then
         FOLD_REPO="$("$FOLD_PORTAL/bin/wt" path 2>/dev/null | tail -1)"
       fi
     fi
   fi
   if [ -z "${FOLD_REPO:-}" ] || ! git -C "$FOLD_REPO" rev-parse HEAD >/dev/null 2>&1; then
     echo "RESULT: error reason=no-fold-checkout-or-mirror"
     exit 1
   fi
   # Guard: never accept a portal directory as --repo
   if [ -d "$FOLD_REPO/.portal" ] && [ ! -e "$FOLD_REPO/.git" ]; then
     echo "RESULT: error reason=fold-path-is-portal path=$FOLD_REPO"
     exit 1
   fi
   ```
3. Prefer dry-run first for safety this cycle unless the registry comment or
   product docs say live writes are intentional:
   ```bash
   cd "$CODERINGS_WT"
   bun src/cli.ts weekly fold \
     --repo "$FOLD_REPO" \
     --repo-id EdgeVector/fold \
     --dry-run --json
   ```
   If dry-run is clean and store policy in `docs/weekly-fold-capture.md` allows
   live write on this machine, re-run without `--dry-run` (optionally
   `--no-file-card` if you only want the snapshot). Material growth → at most
   **one** deduplicated kanban card.
4. Report severity (material / info / none), commit scanned, and whether a card
   was filed.
5. Heartbeat `routine-heartbeats` last.

## Hard rules
- Idempotent on same commit — do not spam cards.
- No primary-brain restarts. Snapshots go through the coderings CLI store path only.
- Never use `$HOME/code/edgevector/fold` (or any portal path) as `--repo`.
  False-green scans against empty portals are a hard fail.

## Close-out (always the LAST step)

Steps 4 and 5 above report the result to a reader. Neither reports it to the
fleet. Without the block below, `routines status` records this run as
`outcome=unknown` with `outcomeSource=none` no matter what the scan found, and
the heartbeat line still reads `ok` because it carries the exit code — two
surfaces disagreeing, with the confident one measuring nothing.

In the final tool call, write the verdict to the authoritative sink; do not
rely on final prose or the legacy trailer alone:

```bash
outcome_line="<ok|noop|error> <one-line-outcome>"
if [ -n "${ROUTINES_RUN_DIR:-}" ]; then
  printf '%s\n' "$outcome_line" > "$ROUTINES_RUN_DIR/outcome.txt"
fi
```

Replace both placeholders with the real verdict. Use `ok` when the scan
completed (whether or not growth was material), `noop` when it was skipped for
a stated reason, and `error` when it could not run. Include the severity, the
scanned commit and whether a card was filed — the same three facts step 4 asks
for. Write the sink after the heartbeat, then emit the heartbeat line plus the
`ROUTINE_RESULT` trailer as the final output (contract §1).

Then run the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`, trigger `/close-out`). Its two
brain writes are not optional on a substantive run: the closeout report of what
this run did, and a `papercut-<topic>` brain record for every friction hit
(BRAIN ONLY, never a board card; search first, update in place). On a pure noop
run the heartbeat line may serve as the report.
