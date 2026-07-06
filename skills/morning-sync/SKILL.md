---
name: morning-sync
description: >-
  The repeatable morning ritual: surface every decision waiting on Tom, capture
  his answers durably, and turn each answer into board movement so the existing
  pickup→agent pipeline drives the unblocked features to completion. Two modes —
  BRIEF (read-only; assemble + deliver the ranked decision queue, run by the
  scheduled morning-sync routine each day at 7:00) and WORK (interactive; walk
  Tom through the decisions one at a time, write each as its own fbrain
  `decision` record, and execute it onto the fkanban board — clear a gate to todo, scope a
  program into a card, or record a hold). Use when Tom says "morning sync", "let's
  do the morning sync", "what decisions are waiting on me", "let's plan through
  things", "work through the blockers", "clear the gates", or when the scheduled
  morning-sync routine fires (BRIEF). This is the decision-capture + execute loop
  that sits ON TOP of program-driver/groom/pickup/agent — it does not replace
  them. Read-only in BRIEF; writes board + fbrain only in WORK.
---

# morning-sync — decisions in, completed features out

The job: make Tom's morning hour the highest-leverage hour of the day. Most
EdgeVector programs are not starved for ideas — they're stalled on **decisions
only Tom can make** (enable a gate, run a cutover, scope a fuzzy next-move). This
skill surfaces every one of those decisions sharply, remembers his answer
forever, and turns the answer into work the rest of the pipeline executes.

It is the missing **edge** of the existing pipeline, not a replacement:

```
generators FILE cards → program-driver/groom PROMOTE → pickup FANS OUT → agent DRIVES to merged → watch/rollup RECONCILE
                                          ▲                                                   │
                            morning-sync WORK feeds decisions in            morning-sync BRIEF surfaces the next gate out
```

Two modes. Pick by how you were invoked:

- **BRIEF** — the scheduled `morning-sync` routine (cron `0 7 * * *`) runs this,
  and Tom asking "what's waiting on me" runs this. **Read-only.** Assemble and
  deliver the ranked decision queue.
- **WORK** — Tom sits down for his hour (`/morning-sync`, "let's do the morning
  sync", "let's work the blockers"). Interactive. Walk the queue; capture +
  execute each decision.

---

## Setup (both modes)

- The board + brain live on the **local folddb node**, reached over the Unix
  socket `~/.folddb/data/folddb.sock`. NEVER kill, restart, or touch the primary
  folddb_server brain or any `folddb_server` you didn't start. If the node is
  unreachable, STOP and report — do not restart anything.
- fkanban CLI: prefer the shim, but the Bash tool is sandboxed (stripped `$PATH`),
  so **prepend the full PATH every call** and run from the repo if the shim is
  missing:
  ```bash
  export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
  fkanban doctor            # or: cd ~/code/edgevector/fkanban && bun run src/cli.ts doctor
  ```
  Read the `fkanban` skill (`~/.claude/skills/fkanban/SKILL.md`) for the current
  CLI contract before any board write.
- fbrain CLI is on PATH after the same prepend (`$HOME/.bun/bin/fbrain`). Write
  multi-line bodies via **stdin** (`fbrain put ... < /tmp/body.md`), never
  `--body "$(...)"` — that mangles/clobbers the record (memory
  `feedback_mcp_args_no_shell_expansion`).
- `fkanban list --json` is valid JSON; parse from a file, iterate slugs with a
  bash array (`for s in "${arr[@]}"`), never a bare `$var`.
- Columns: `backlog → todo → doing → review → done`. `add` is an upsert;
  `move <slug> <column>`.

## The data the loop reads/writes

- **`active-programs`** (fbrain project) — the driving index: ~11 programs, each
  with a "Next move", its DAG cards, and `needs-human`/`blocked-needs-human`
  lines. This is the program work-list.
- **`decision` records** (fbrain type `decision`, one record per decision) —
  every call Tom makes, dated, with what it unblocked. The durable memory. WORK
  writes ONE `decision` record per call (`fbrain list --type decision`, newest
  first). This replaced the old monolithic `decisions-log` reference record
  (archived 2026-07-06 with a tombstone pointer) — appending is now a tiny
  per-record write, not a full-ledger rewrite. Read a specific one with
  `fbrain get <slug> --type decision`; the `program`/`gate_slug`/`decided_by`/
  `decided_on` columns are queryable fields, not buried in prose.
- **`open-decisions`** (fbrain reference) — the standing queue of pending
  decisions. `fkanban-agent` escalates gated next-steps here (Component C); BRIEF
  reads it so a stall becomes a dated line, never silence.
- **`routine-heartbeats`** (fbrain reference) — one line per routine run
  (`<routine> <ISO-ts> <ok|error|noop> <outcome>`). BRIEF §3 flags any routine
  that didn't run or errored.

---

## BRIEF mode (read-only) — assemble + deliver the decision queue

Produce a **decision-first** briefing, not a status dump. Lead with what's
waiting on Tom. Steps:

1. **Snapshot.** `fkanban list --json` (counts + every card's column + body head).
   `fbrain get active-programs`. `fbrain get open-decisions --type reference` and
   `fbrain get routine-heartbeats --type reference`.

2. **§1 — Decisions that GENUINELY need you (keep it SHORT).** Per Tom's standing
   correction (`feedback_autonomous_drive_dev_not_gated`), most old "gates" are NOT
   human — dev flips, security reviews, and design-first cards are DRIVEN
   autonomously by program-driver/fkanban-agent, NOT surfaced here. Only include
   the genuinely-human set (`fbrain get north-star` taxonomy):
   - **prod cutovers / public launches** (irreversible, outward),
   - **shipping NEW capability to END USERS** (e.g. the shipping-build WASM flip),
   - **brand / naming / tagline**, **business / legal / patent**,
   - a **genuinely novel architecture fork** with no reasonable default + high
     blast radius,
   **The authoritative source for this set is `open-decisions`** — the SINGLE
   ledger of human gates ([[human-gate-single-source-and-crosscheck]]); its live
   (un-cleared) lines ARE the decision queue. `active-programs` `needs-human:` /
   rollup tokens are a derived CROSS-CHECK only: if one names a gate with no live
   `open-decisions` line, write the line (dedup) or treat it as noise — do NOT
   surface a gate that isn't in `open-decisions`. **Dedup** by slug. Before listing
   any gate, verify it is still live against the durable records (linked
   `done`/project record + `origin/main` + the board) — index prose lags (the
   2026-06-29 stale `ai_router` false-gate); a landed/moot gate is resolved, not
   waiting. Do NOT list dev-enable, `[sec-review-later]`, `AWAITING GREEN-LIGHT`,
   or `[design-first]` cards here — those are being driven; note them in §0 instead.
   For each genuine decision: one-line ELI5, what it unblocks, a **recommendation**
   + options, and **waiting since** (mark `🔴 STALE` if > 7 days). Rank by leverage.
   If this list is empty, say so plainly — that's the goal, it means everything is
   being driven.

   **§0 — What I'm driving (autonomously).** Before §1, a short list of the
   dev/security/design work program-driver promoted or generated toward the North
   Star this cycle — so Tom can SEE progress and redirect if any of it is wrong,
   without having to approve it. (This is the reassurance that replaces the old
   decision-fatigue queue.)

3. **§2 — Programs that need scoping (not a decision).** For each program in
   `active-programs`: if it has NO card in `todo`/`doing`/`review` AND its "Next
   move" is concrete but un-carded (e.g. #6 desktop's 3-in-1), list it as a
   "scope me" candidate with a suggested first PR-sized slice. These are un-gated
   work that's falling through because no generator covers the program.

4. **§3 — Routine health (make silent failure loud).** Two signals, combined:
   - **Did it run?** Primary signal = the scheduled-tasks system's own
     `lastRunAt`/`nextRunAt` (call `list_scheduled_tasks` if the MCP is available
     this run; it always tracks every routine's last fire). Flag any enabled
     routine whose `lastRunAt` is older than its cadence (hourly routine not run in
     >90 min; daily not run in >26 h) — that's a routine that silently stopped
     firing.
   - **Did it succeed?** Read `routine-heartbeats` (fbrain) for the *outcome* of
     the last run: flag any routine whose latest heartbeat is `error`, or that has
     a recent `lastRunAt` but NO matching heartbeat (ran but died before its
     heartbeat = a silent mid-run failure). A routine with no heartbeat at all yet
     just predates Component D — note it once, don't alarm.
   Cross-check the driving-layer set explicitly: `program-driver`,
   `groom-fkanban-board`, `fkanban-pickup`, `fkanban-watch`, `program-rollup`,
   plus the generators. If `list_scheduled_tasks` is unavailable in a headless
   run, fall back to `routine-heartbeats` alone and say so.

5. **§4 — What moved overnight (context, keep short).** Reuse
   `~/.claude/skills/morning-digest/gather.sh 24` and roll up BY PROGRAM (not a
   PR wall). 1–3 lines per program that changed.

6. **§5 — Usage & Bugs (visibility across the board).** Run the helper
   `~/.claude/skills/morning-sync/usage-bugs.sh` and paste its two blocks
   verbatim (it is read-only and self-guards every call):
   - **🐛 Bugs (Sentry)** — unresolved totals + new-in-24h + actively-firing
     storms across the `rust` (backend/cloud) and `javascript-react` (frontend)
     projects. This is a *visibility summary*, NOT the triage pass — the
     `sentry-triage` routine (08:29) still files the cards; here Tom just sees the
     error weather. If a 🔴 storm is firing AND it isn't already on the board /
     in `sentry-triage-ledger`, mention it once in §0 as in-flight (don't file).
   - **📈 Usage (PostHog)** — DAU/WAU + event volume. Until a personal read key is
     stashed the block prints its own one-line setup instruction; leave it as-is so
     the gap stays visible (do not silently drop the section).
   If the helper is missing or errors, print one line saying so — never omit the
   section silently.

7. **Deliver + persist.** Print the brief (this reaches Tom via the scheduled
   task's completion notification). Then write it to fbrain
   `morning-sync-brief-latest` (reference, upsert) so WORK mode and the
   morning-digest can pick it up. Heartbeat: append a `morning-sync <ts> ok
   <n decisions, m scope, k routine-alerts>` line to `routine-heartbeats`.

BRIEF writes ONLY `morning-sync-brief-latest` + the heartbeat. It never moves a
card, never edits a gate card, never clears a gate. That is WORK's job.

Brief skeleton:

```
## 🌅 Morning sync — <date>   ·  North Star: <one-line from `fbrain get north-star`>

### 🚀 What I'm driving (autonomous — FYI, redirect if wrong)
- <program> — <dev/security/design work promoted or generated toward criterion N>.

### ⚠️ Genuinely needs you   (short; empty is good)
1. <gate> — <ELI5>. Unblocks: <program/cards>. Waiting since <date>.
   Recommend: <X>. Options: <a / b / c>.   [ONLY prod/outward/brand/business/novel-arch]

### 🧩 Needs scoping (un-gated, no card yet)
- #6 Desktop — superset bundle / tray / CLI-takeover. Suggested first slice: <…>.

### 🩺 Routine health
- <routine> last ran <when> — <ok | DID NOT RUN | error: …>

<output of usage-bugs.sh — the 🐛 Bugs (Sentry) + 📈 Usage (PostHog) blocks, verbatim>

### 📦 Moved overnight (by program)
- <program> — <1 line>.

Most things are being driven automatically. Run `/morning-sync` (WORK) only if you
want to give direction on the §⚠️ items or redirect anything in §🚀.
```

---

## WORK mode (interactive) — capture each decision + execute it

Tom is here for his hour. Goal: walk §1 (then §2) and, for each, get his call,
**write it down forever, and make it real on the board** — so by the time he
stands up, `todo` is freshly stocked and the pipeline takes over.

1. **Load the queue.** If a fresh `morning-sync-brief-latest` exists (today),
   use its §1/§2. Otherwise run BRIEF's assembly steps live first.

2. **For each decision, in leverage order, ask Tom** with `AskUserQuestion`:
   present the ELI5 + what it unblocks + your recommendation (recommended option
   first) + the literal options. One decision at a time; don't dump all at once.
   Keep his momentum — short, sharp, decision-shaped.

3. **On each answer, do BOTH (capture, then execute):**

   a. **Capture as a `decision` record** (one tiny write per decision — NOT an
      append to a monolith). Write a NEW record of type `decision` via stdin,
      with the queryable columns set in frontmatter and the rationale in the
      body:
      ```bash
      slug="decision-<date>-<short-kebab-of-the-call>"   # unique, stable
      body_file="$(mktemp)"
      cat > "$body_file" <<'EOF'
      ---
      type: decision
      slug: <slug>
      title: <one-line summary of the call>
      status: <go|hold|done|moot|superseded>   # the OUTCOME, not a workflow state
      program: <owning program / North Star slug, empty string if none>
      gate_slug: <open-decisions gate this clears, empty string if none>
      decided_by: Tom
      decided_on: <date, RFC 3339 e.g. 2026-07-06>
      tags: [decisions]
      ---

      Decision: <what Tom chose>
      Unblocks: <cards>
      Rationale: <one line, in Tom's framing>
      EOF
      fbrain put "$slug" --type decision < "$body_file"
      rm -f "$body_file"
      ```
      This is the permanent memory — "remember all the decisions." Each decision
      is its own record (`fbrain list --type decision` shows the whole ledger,
      newest first); NEVER append to the archived `decisions-log` monolith.
      Status mapping: a cleared gate you proceed on = `go`; a deferral = `hold`;
      a decision whose work already landed = `done`; a premise that went away =
      `moot`; a call a later one replaced = `superseded`.

   b. **Execute onto the board**, by decision type:

      - **CLEAR A GATE (go).** Edit the gate card body: replace the gate marker
        line with `✅ DECIDED <date> (Tom): <decision>`; ensure it has a real
        GOAL/STEPS/VERIFY brief, a `Repo:`/`Base:` header, and the fkanban-agent
        header (`Follow the fkanban-agent skill — drive this through to a MERGED
        PR. A card is only done when its code is actually in the repo.`). Then
        `move <slug> todo`. **Then promote anything that was blocked only on this
        gate** — any card whose body declared a dep solely on this slug. Use the
        `fkanban` add-via-stdin pattern to rewrite the body cleanly.
        - DEV-FIRST RULE: if the gate touches a prod surface, the card you promote
          is the **dev** slice; the prod cutover/flip stays a SEPARATE explicit
          card that remains gated (record it in `open-decisions` as "prod cutover
          — human, after dev soak"). Never auto-promote a prod cutover.

      - **SCOPE A PROGRAM (§2).** File ONE PR-sized first-slice card to `todo`
        with a full GOAL/STEPS/VERIFY brief + Repo/Base + fkanban-agent header.
        **Verify facts against `origin/main` first** (`git fetch` + read
        `origin/<base>:<file>`) so you don't file already-merged work. Leave any
        epic/tracker card where it is.

      - **HOLD / defer.** Write the `decision` record with `status: hold` and a
        `revisit <date|when>` note in its body, and add a `hold-until <date>`
        marker to the card body so BRIEF stops re-surfacing it daily until then.
        Do not move it.

      - **NEEDS MORE INFO.** If Tom can't decide because something's unclear,
        DON'T force it — capture `pending: <what he needs>` to `open-decisions`
        and move on. (Offer to pull the missing context with the `eli5` skill.)

   c. After executing, confirm with `fkanban show <slug>` that the card reads back
      correctly (DECIDED line present, `column` correct) before moving on.

4. **Update `active-programs`.** For each program touched, refresh its "Next move"
   line to reflect the decision (edit the prose, NOT the `rollup:start…end`
   auto-block — that's program-rollup's). Keep it to the one settled next step.

5. **Close the session.** Report: decisions captured (N), gates cleared → cards
   promoted (list slugs + new column), programs scoped (new card slugs), holds.
   End with the resulting `todo` count and: "the :15 fkanban-pickup will start
   driving these within the hour." Heartbeat: append `morning-sync <ts> ok
   WORK: <n cleared, m scoped>` to `routine-heartbeats`.

---

## Guardrails (EdgeVector standing rules — apply to WORK writes)

- **Never** kill/restart the primary folddb_server brain or any folddb_server. The board lives there.
- **Dev, not prod.** Any card you promote/file that touches a prod surface says
  "dev-first, one clean cutover" in its brief; the prod cutover/flip is always a
  separate, still-gated, human step — record it, never auto-promote it.
- **Capture before you execute.** Every decision lands as its own `decision`
  record BEFORE you touch the board, so nothing is lost if a write fails midway.
- **Verify against `origin/main`** before writing any fact into a card brief —
  local checkouts lag and the work may already be merged.
- **Don't fabricate decisions.** If §1 is empty (everything in flight, nothing
  gated), say so plainly and stop — a clean board is a good outcome, not a prompt
  to manufacture busywork.
- **One record per decision; never clobber.** Each decision is a NEW `decision`
  record (a tiny write) — never rewrite a prior decision or the archived
  `decisions-log` monolith. For the standing `open-decisions`/`active-programs`
  ledgers you still edit, read-modify-write; big bodies via stdin.
- This skill is the only place decisions get *captured + executed*. It does NOT
  ship code, open PRs, or run fkanban-agent — the pickup→agent pipeline does that
  once the cards are in `todo`.
