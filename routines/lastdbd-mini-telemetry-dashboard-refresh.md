---
name: lastdbd-mini-telemetry-dashboard-refresh
description: Hourly: regenerate the LastDB Mini telemetry dashboard from the live brain (read-only) and republish it to its stable Claude Artifact URL.
---

Refresh the LastDB Mini brain telemetry dashboard Artifact. This keeps Tom's headless primary brain observable (North Star north-star-mini-brain-observability, criterion 4; fbrain reference `lastdbd-mini-telemetry-dashboard-artifact` has the full context).

## Portal model (won't-undo)

`~/code/edgevector/fold` is a **portal** (no product source / no `.git`). Do
**not** run scripts from that path. Resolve the regen wrapper from the fold
bare mirror (or a dedicated worktree), then execute the extracted copy.

Do EXACTLY this, then stop:

1. Resolve and run the regeneration wrapper (it queries the running `lastdbd`
   READ-ONLY over its owner socket and reads the session ledger — it NEVER
   restarts, writes to, or otherwise mutates the primary brain):

   ```bash
   last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
   . "$last_stack/bin/last-stack-shell-prelude" 2>/dev/null || true

   FOLD_MIRROR="${FOLD_MIRROR:-$HOME/.cache/edgevector-git/fold.git}"
   SCRIPT_REL="scripts/lastdbd/telemetry-dashboard-regen.sh"
   work_dir="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-telemetry-dashboard-prompt.XXXXXX")"
   trap 'rm -rf "$work_dir"' EXIT
   wrapper="$work_dir/telemetry-dashboard-regen.sh"

   if [ -d "$FOLD_MIRROR" ] && git -C "$FOLD_MIRROR" rev-parse --git-dir >/dev/null 2>&1; then
     git -C "$FOLD_MIRROR" fetch --quiet origin 2>/dev/null || true
     if ! git -C "$FOLD_MIRROR" show "refs/heads/main:${SCRIPT_REL}" >"$wrapper" 2>/dev/null; then
       echo "RESULT: noop reason=DASHBOARD_SKIP=regen-script-missing-on-main"
       exit 0
     fi
     chmod +x "$wrapper"
   else
     # Fallback: dedicated fold worktree via portal (never raw portal path).
     FOLD_PORTAL="${FOLD_PORTAL:-$HOME/code/edgevector/fold}"
     if [ ! -x "$FOLD_PORTAL/bin/wt" ]; then
       echo "RESULT: error reason=no-fold-mirror-and-no-portal-wt"
       exit 1
     fi
     FOLD_WT="$("$FOLD_PORTAL/bin/wt" start lastdbd-telemetry-dashboard-refresh 2>/dev/null | tail -1)"
     if [ ! -f "${FOLD_WT:-}/${SCRIPT_REL}" ]; then
       FOLD_WT="$("$FOLD_PORTAL/bin/wt" path 2>/dev/null | tail -1)"
     fi
     if [ ! -f "${FOLD_WT:-}/${SCRIPT_REL}" ]; then
       echo "RESULT: error reason=no-fold-checkout-for-regen-script"
       exit 1
     fi
     # Guard: refuse portal directory
     if [ -d "$FOLD_WT/.portal" ] && [ ! -e "$FOLD_WT/.git" ]; then
       echo "RESULT: error reason=fold-path-is-portal path=$FOLD_WT"
       exit 1
     fi
     cp "$FOLD_WT/${SCRIPT_REL}" "$wrapper"
     chmod +x "$wrapper"
   fi

   LASTDB_HOME="${LASTDB_HOME:-$HOME/.lastdb}" bash "$wrapper"
   ```

   (The wrapper uses `lastdb` from PATH; if the installed `lastdb` lacks the
   `telemetry-dashboard` subcommand the wrapper simply prints a DASHBOARD_SKIP
   line — that is expected until the telemetry-bearing lastdb build is
   deployed.)

2. Read the wrapper's last meaningful stdout line:
   - If it is `DASHBOARD_SKIP=<reason>`: do NOTHING else. The existing Artifact stays as-is (no telemetry yet, or the brain is unreachable, or the binary lacks the subcommand). Report the skip reason and stop.
   - If it is `DASHBOARD_HTML=<path>`: publish that HTML file to the SAME stable Artifact URL so the link never changes. Call the Artifact tool with:
       file_path = <the path from DASHBOARD_HTML>
       url = https://claude.ai/code/artifact/9c0ba66a-91f4-41b8-9ed3-1fd9aa9a6465
       favicon = 🧠
     Confirm it redeployed to that same URL and report the generated-at time shown in the dashboard.

Hard rules: never kill/restart/`brew restart` the primary brain (`lastdbd` / homebrew.mxcl.lastdb) or `forgejo`. The renderer is read-only; do not pass `--note` (live renders carry no provenance banner). Do not mint a new Artifact URL — always redeploy to the URL above. If anything is ambiguous, prefer doing nothing (leave the existing Artifact) over publishing bad data. Never invoke `$HOME/code/edgevector/fold/scripts/...` (portal path — dead).

## Exit code semantics (required for routinesd health)
- `DASHBOARD_SKIP=<reason>` is a **successful noop**. Report the skip reason and
  finish with a clear success. Do not treat skip as failure.
- `DASHBOARD_HTML=<path>` published successfully → success.
- Only fail if: the wrapper crashed unexpectedly, you published bad HTML, or you
  violated a hard rule (primary-brain mutation, wrong Artifact URL, portal path).
- When skipping, prefer a final line like:
  `RESULT: noop reason=DASHBOARD_SKIP ...`
  so the outcome classifier records noop, not error.
