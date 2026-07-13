---
name: morning-digest
description: >-
  Produce the recurring "what happened overnight / where do things stand" status
  digest Tom keeps asking for by hand. Stitches git activity, scheduled-routine
  outcomes, open-PR states, and human-gated blockers into one briefing — rolled up
  BY FEATURE/PROGRAM (not by individual PR) — and ends with a sharp "⚠️ Waiting on
  you" section: the decisions only Tom can make, each with enough context to resolve
  on the spot. Use when he says any of: "summarize what's done overnight", "what
  happened overnight", "tell me about the code committed in the last 24h", "what's
  the status", "where do things stand", "are there any blockers (that wait for me)?",
  "what's blocked / figure out what to do with the blocked PRs", "check the routines
  and the PRs", "morning digest", "standup", or otherwise asks for an overnight /
  cross-program status briefing. Read-only by default.
---

# Morning digest

Tom asks for this constantly, in a dozen phrasings ("what's done overnight",
"any blockers that wait for me?", "tell me about the last 24h", "summarize the
routines and PRs"). It's the same job every time: assemble the scattered state
into one briefing organized **by feature/program**, and make crystal-clear **what
is waiting on him**. This skill codifies that job so it's fast and consistent.

The default is **read-only** — a report. Do not file cards, push, merge, or write
brain unless Tom explicitly asks in the same breath.

## 1. Gather the raw data (one command)

```bash
~/.claude/skills/morning-digest/gather.sh 24      # window in hours; default 24
```

This prints four sections, all read-only:
1. **Commits** per active repo (fold, schema-infra, exemem-infra, fold_dev_node, kanban)
2. **Open PRs** per repo — number, mergeable state, auto-merge armed?, review decision
3. **Routine runs** in the window — every scheduled-task session, grouped by routine,
   each showing its *final assistant words* (the run's self-reported outcome)
4. **Human-present sessions** — what Tom drove by hand (recurring-request signal)

Use a wider window if asked ("this week" → `gather.sh 168`).

Then gather **usage + bugs** (the product's error weather + adoption), read-only:

```bash
~/.claude/skills/morning-sync/usage-bugs.sh        # 🐛 Sentry + 📈 PostHog blocks
```

- **🐛 Bugs (Sentry)** — unresolved totals, new-in-24h, and actively-firing storms
  across `rust` (backend/cloud) and `javascript-react` (frontend). A 🔴 storm that's
  new or escalating is a strong "Waiting on you" / "By program" signal.
- **📈 Usage (PostHog)** — DAU/WAU + event volume. Prints its own one-line setup
  instruction until a personal read key is stashed; surface that gap rather than
  dropping the section.

## 2. Enrich (only what the raw data can't tell you)

The raw data is mechanical. Layer on the *meaning*:

- **What's gated — SOURCE THE "Waiting on you" SECTION ONLY FROM `open-decisions`.**
  `brain get open-decisions --type reference` is the SINGLE authoritative ledger of
  human gates ([[human-gate-single-source-and-crosscheck]]); its live (un-cleared)
  lines ARE the "waiting on you" set. Do NOT build that section from `active-programs`
  prose or rollup `needs-human:`/`blocked-needs-human:` tokens — those are derived
  views that drift (a stale §13 prose line produced a false `ai_router` gate on
  2026-06-29). You MAY read the rollup tokens + `active-programs` only as a
  CROSS-CHECK: if a token names a gate with no live `open-decisions` line, it's
  noise (reconcile, don't surface); if `open-decisions` lists a gate, verify it's
  still live against the durable records (linked `done`/project record + `origin/main`
  + the board) before surfacing — if the work landed/moot, it's resolved, not waiting.
- **What's stuck but NOT yours — the "🔧 Stuck in the machine" section.** Read the
  `blocked-on-engineering:` tokens across the `active-programs` rollup blocks (`brain
  get active-programs --type project`). These are the engineering/dev blockers the
  autonomous loop owns — red CI, dep bugs, dep-gated cards — NOT decisions for Tom.
  List each: slug · program · the one-line reason · and a moving-vs-wedged read (open
  PR + auto-merge armed / CI red / dep-blocked behind <slug> / idle >48h = genuinely
  wedged). This section gives Tom confidence the loop is grinding and flags anything
  truly stuck. It is DISTINCT from "Waiting on you" — never put an engineering blocker
  there, and never put a human gate here. If a `blocked-on-engineering:` line's reason
  is actually human-only (hardware, approval, spend) with no `open-decisions` line, say
  so — it's an untracked gate that should be promoted to `open-decisions`.
- **Why is a PR blocked?** For any PR not auto-merging cleanly, look before asserting:
  `CONFLICTING` = needs rebase; `UNKNOWN`/`BLOCKED` = CI in flight (auto-merge will
  land it — NOT a problem, don't flag it as one); red checks = real failure. Per
  Tom's standing rule, a BLOCKED/queued/red-check state is "re-poll", not "broken".
  Check with `gh pr checks <n> --repo <slug>` only if a PR looks genuinely stuck
  (open + mergeable + auto-armed but sitting for many hours).
- **Map commits/PRs to features.** Don't list 31 commits. Bucket them by program:
  at-rest encryption (Gap G1–G6), app-isolation / UDS data-plane, onboarding/CLI UX,
  remote-identity, dogfood findings, etc. The commit prefixes (`fix(at-rest)`,
  `feat(cli)`, `[sec-review-later]`) and the tracker tell you the buckets.

## 3. Write the digest

Structure — lead with the answer, keep it skimmable:

```
## Overnight digest — <date>, last <N>h

### ⚠️ Waiting on you   ← ALWAYS FIRST. The whole point.
- <decision/blocker>, why it's blocked, the options, and your recommendation.
  (e.g. "schema-infra#142 is parked in review on purpose — merging ships PROD.
   Merge only when you're ready for the app-isolation cutover. Recommend: hold.")
- If nothing is waiting: say so in one line. Don't manufacture blockers.

### 🔧 Stuck in the machine (not yours)   ← engineering blockers the loop owns
- <slug> (<program>) — <one-line reason> · <moving: PR #N auto-merge armed | CI red | dep-blocked behind <slug> | ⚠️ wedged, idle >48h>.
- Sourced from `blocked-on-engineering:` rollup tokens. If nothing is stuck: "loop is clear." Flag any untracked human gate hiding here.

### By program   ← roll up here, NOT a PR list
- **At-rest encryption** — N PRs merged (G1 strict-flip, G4 passphrase params…).
  Where it stands: <1 line>. Next: <1 line>.
- **App-isolation / UDS** — …
- (one bucket per active program; 1–3 lines each)

### Routines
One line per routine that ran: did it ship / heal / park / fail, and anything
notable (a wedged node, a dogfood paper-cut, a disk-pressure event). Call out
any routine that did NOT run but should have, or that reported a real failure.

### 🐛 Bugs & 📈 Usage
The two blocks from `usage-bugs.sh`, verbatim. Lead with any firing Sentry storm;
note the PostHog DAU/WAU trend (or the "not configured" gap) in one line.

### Open PRs needing attention
Only the ones that aren't cleanly auto-merging. Each: state + the one action.
Skip the healthy auto-merging ones (just note the count).
```

Rules of thumb:
- **Feature altitude, not PR altitude.** Tom explicitly asks for "where they are
  relative to features instead of [individual PRs]." A wall of PR titles is a fail.
- **The "waiting on you" section is the deliverable.** Everything else is context
  for it. If you're unsure whether something needs him, it probably belongs there
  with your recommendation.
- **Ground every claim** in the gathered data / tracker / `gh` — never report
  program state from memory. If a routine's final words say "wedged node" or
  "blocked", surface it; if they say "auto-merge armed, exiting", that's healthy.
- **Honor the standing rules:** don't treat BLOCKED/queued PRs as failures; never
  propose touching the primary folddb_server brain or a prod deploy as a casual "next step"; flag the
  human-gated lines (schema-infra#142, the shipping-build flip, business calls) as
  *hold*, not *do*.

## 4. If Tom asked you to act (not just report)

Only if he explicitly said so ("…and unblock them", "…and file cards for the gaps"):
do the action, then still give the digest. For PR-merge babysitting use the
`wait-merge` skill; for filing work use the `kanban` skill. Otherwise stop at the
report — the report is the correct default output.
