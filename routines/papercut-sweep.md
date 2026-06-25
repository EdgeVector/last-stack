---
name: papercut-sweep
cadence: daily
description: Sweep the last day's agent sessions for dev-process papercuts and FILE a board card for each (does not ship fixes itself — the pickup pipeline builds them).
---

You are running an unattended daily routine in `<WORKSPACE>`. Objective: surface
"papercuts" — recurring friction, repeated errors, manual workarounds, confusing
tooling, missing docs — that agent sessions hit in the LAST 24 HOURS, then FILE a
board card for each so they get fixed by the build pipeline. The goal is to make
the dev process incrementally easier each day. You FILE work onto the board; you
do NOT ship fixes yourself — `fkanban-pickup` + `fkanban-agent` workers build the
cards.

Read your project's agent-orientation doc and durable memory index first, and
honor their standing rules.

## Automation memory
If the scheduled prompt includes an `Automation memory:` path, read and write
that exact file. Otherwise use
`${CODEX_HOME:-$HOME/.codex}/automations/<automation-id>/memory.md`. Before any
read/write, fail loudly if the resolved path is empty or starts with
`/automations/`; that means the fallback was computed incorrectly.

## Step 1 — Gather the last day's session signal
- Enumerate recent sessions using whatever your harness offers unattended. A
  full-text transcript *search* tool may be blocked in unattended runs — if so,
  read/grep the raw transcript files directly.
- Grepping gotchas (same as the self-improvement loop): unreliable mtimes →
  filter by an in-content timestamp; session id ≠ transcript filename →
  `grep -l "<id>"`; in `zsh`, quote globs and append `|| true`.
- Look for papercut signals: a command that errored then was retried with a
  tweak; permission-prompt friction; the agent hunting for a file/script/
  endpoint; "that's deprecated, use X" corrections; repeated manual setup steps;
  flaky/hanging tests; confusing CLI output; a stale doc that misled an agent; or
  the same workaround across multiple sessions.
- Cluster the findings. Prioritize papercuts that show up in MORE THAN ONE
  session or recur across days. Ignore one-off, user-specific mistakes.

## Step 2 — Triage each papercut
For each distinct papercut, classify it:
- ALREADY KNOWN: already captured in memory or on the board (check the board
  first). If so, do NOT re-file — skip it.
- ACTIONABLE: anything worth fixing — a doc correction, a helper script, a
  clearer error message, a permission-allowlist entry, a stale-reference
  cleanup, OR a product code change. ALL of these become CARDS — you do not fix
  any inline.
- NOT ACTIONABLE / one-off: skip.

## Step 3 — Act — FILE CARDS ONLY (do not ship fixes yourself)
- For EVERY actionable papercut, FILE one board card (do NOT open a worktree,
  write code, or open a PR — `fkanban-pickup` + `fkanban-agent` build the
  cards). Dedupe against existing cards first.
- Make each card pickup-eligible and cold-start-ready. Example with the fkanban
  CLI:
  ```bash
  <board CLI> add <slug> --title "<title>" --column todo --tags papercut,<repo-tag> \
    --body "$(cat <<'EOF'
  **Follow the fkanban-agent skill — drive this through to a MERGED PR.**

  Repo: <owner>/<repo>
  Base: <DEFAULT_BRANCH>
  Branch: fkanban/<slug>

  ## GOAL — one line, the observable fix.
  ## CONTEXT — the EVIDENCE: which sessions / how often it recurred.
  ## STEPS — the concrete change.
  ## VERIFY — the exact commands that must pass.
  ## DONE WHEN — PR merged into <DEFAULT_BRANCH>.
  EOF
  )"
  ```
  Tiny doc/settings cards still go through the board — just keep STEPS/VERIFY
  minimal.
- If a fix is too ambiguous or large to specify well, file it in `backlog` with
  what you know rather than a half-baked `todo` card.

## Hard constraints (unattended-run safety)
- FILE, don't ship: no code/doc/settings edits, no branches, no PRs from this
  routine — only board cards (+ an optional memory note if a papercut reveals a
  standing-rule gap).
- Dev-only. Never deploy, never touch prod.
- No destructive ops: no `git stash`/`reset`/`clean`, no killing processes,
  never the process hosting your brain/board. Sibling agents share the
  workspace.
- Default to idempotent additions. If nothing actionable is found, file nothing
  and just report.

## Output
End with a concise report: papercuts found (grouped), what you filed (with
slugs), and what you skipped as already-known. If the last day had no agent
activity or no actionable papercuts, say so plainly.
