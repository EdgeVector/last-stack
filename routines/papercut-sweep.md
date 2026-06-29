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
- For Codex/Aline history, the canonical agent path is the installed
  `onecontext` skill. Do not tell agents to run an `aline` CLI unless
  `command -v aline` succeeds in the expected agent shell. Guard any direct
  `aline search ...` suggestion like this:
  ```bash
  if command -v aline >/dev/null 2>&1; then
    aline search "<pattern>"
  else
    sessions_root="${CODEX_HOME:-$HOME/.codex}/sessions"
    cutoff_iso="$(date -u -v-24H '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d '24 hours ago' '+%Y-%m-%dT%H:%M:%SZ')"
    find "$sessions_root" -type f -name '*.jsonl' -print0 |
      xargs -0 jq -r --arg cutoff "$cutoff_iso" 'select((.timestamp // .time // .created_at // "") >= $cutoff) | @json' 2>/dev/null |
      rg -i "<pattern>" || true
  fi
  ```
  If the installed `onecontext` skill recommends Aline commands but the binary
  is absent, skip the stale command and use the raw transcript fallback above.
- Grepping gotchas (same as the self-improvement loop): unreliable mtimes →
  filter by an in-content timestamp; session id ≠ transcript filename →
  `grep -l "<id>"`; in `zsh`, quote globs, append `|| true`, and never assign
  to a variable named `status` because it is read-only.
- Look for papercut signals: a command that errored then was retried with a
  tweak; permission-prompt friction; the agent hunting for a file/script/
  endpoint; "that's deprecated, use X" corrections; repeated manual setup steps;
  flaky/hanging tests; confusing CLI output; a stale doc that misled an agent; or
  the same workaround across multiple sessions.
- Cluster the findings. Prioritize papercuts that show up in MORE THAN ONE
  session or recur across days. Ignore one-off, user-specific mistakes.

## Step 2 — Triage each papercut
For each distinct papercut, classify it:
- ALREADY KNOWN / COVERED: already captured by an OPEN board card that still
  accurately covers this fresh evidence (check the board first). Do NOT file a
  duplicate card, but update the existing card with the new evidence if it would
  help the worker.
- RECURRING KNOWN: already mentioned somewhere, but the issue is still recurring
  after the prior card/doc/memory entry. This is ACTIONABLE, not a terminal
  skip. If the existing card is `done`, stale, too broad, or only a Brain/doc
  note, file a follow-up card or reopen/update the board state so the recurrence
  has live work attached to it.
- ACTIONABLE: anything worth fixing — a doc correction, a helper script, a
  clearer error message, a permission-allowlist entry, a stale-reference
  cleanup, OR a product code change. ALL of these become CARDS — you do not fix
  any inline.
- NOT ACTIONABLE / one-off: skip.

## Step 3 — Act — FILE CARDS ONLY (do not ship fixes yourself)
- For EVERY actionable papercut, FILE one board card (do NOT open a worktree,
  write code, or open a PR — `fkanban-pickup` + `fkanban-agent` build the
  cards). Dedupe against existing cards first.
- For EVERY recurring-known papercut, record the board action you took: updated
  live card, reopened/moved stale card, or filed a follow-up. Never report only
  "already known" when fresh evidence shows the issue still recurs.
- Make each card pickup-eligible and cold-start-ready. Example with the fkanban
  CLI:
  ```bash
  body_file="$(mktemp)"
  cat > "$body_file" <<'EOF'
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
  <board CLI> add <slug> --title "<title>" --column todo --tags papercut,<repo-tag> < "$body_file"
  rm -f "$body_file"
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
slugs), what recurring-known issues received follow-up board action, and what
you skipped as already-known because an open card already covers the fresh
evidence. If the last day had no agent activity or no actionable papercuts, say
so plainly.
