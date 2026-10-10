---
name: close-out
version: 0.4.0
description: Run the full close-out loop after finishing a substantive change — worktree PR + auto-merge, file session papercuts, write a full brain report of what was done, update superseded brain records and stale kanban cards, and file a kanban follow-up card. Use after landing any code/doc change or settled decision, or when the close-out backstop hook fires. These steps are standing-authorized; do them without asking.
allowed-tools:
  - Bash
  - Read
  - Edit
  - Write
triggers:
  - close out
  - close-out
  - wrap this up
  - finish up and PR
  - run the close-out loop
---

# /close-out — finish a piece of work properly

The recurring frustration: substantive work gets done but not *closed out* — no
PR, no papercuts filed, no full report in the brain of what actually happened,
no follow-up card. Run these steps automatically; don't ask permission for the
mechanical parts. Only stop for a genuine fork (branch base? dev vs prod? a
design choice).

Run the steps that apply to what you just did. Skip ones that don't. Do **not**
skip papercut filing, the full brain report, or the superseded-record pass on a
substantive session — those LastDB writes are why this loop exists. See
`preference-always-file-papercuts-in-brain` and
`preference-always-save-to-brain-when-done`.

This loop assumes two LastDB surfaces:
- **Brain** (`brain`) — long-lived notes: the *why*, settled decisions,
  the full closeout report of what was done, and papercuts.
- **Kanban** (`kanban`) — what's in flight: cards moving through columns.

(Adjust the CLI names if your brain/board tools differ.)

## 1. PR it — from a worktree, never the shared main checkout

If your changes are sitting in a shared main checkout, move them to a worktree
first — `git add -A` in a shared checkout can sweep sibling work into your
commit. Always work in an isolated worktree under
`${WORKTREES_DIR:-$HOME/.fkanban/worktrees}`, never inside the repo as
`<repo>/.worktrees`.

After moving, leave the shared checkout clean. Restore only the exact files you
edited, or run `last-stack-repark-shared-checkouts` so any multi-file leftover
state is parked on an attributable salvage branch instead of being abandoned in
the ambient checkout.

Before opening the review artifact, route the repo:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
route_json="$("$last_stack/bin/last-stack-pr-venue" --json <owner>/<repo> "$WT")"
venue="$(printf '%s\n' "$route_json" | jq -r .venue)"
```

Use GitHub `gh` (`gh pr create`, `gh pr merge <n> -R <owner>/<repo> --auto
--squash`, required check `ci-required`) when `venue=github`. This is the
default for every EdgeVector repo except `EdgeVector/lastgit`. Use the local
Forgejo SOP/API helper only when `venue=forgejo` (the `lastgit` repo). LastGit
is retired (brain `decision-2026-09-29-retire-lastgit-all-repos-to-github`): if
`venue=lastgit`, do not push to a `lastdb:///` remote; file a brain papercut.

Close-out/backstop hooks that check for local commits ahead of the canonical
remote should resolve the comparison ref through the same helper:

```bash
compare_ref="$("$last_stack/bin/last-stack-pr-venue" --compare-ref <owner>/<repo> "$WT")"
git -C "$WT" rev-list --count "$compare_ref"..HEAD
```

The helper compares against the upstream/origin ref of the resolved venue.

```bash
REPO="$HOME/code/<repo>"
WT="${WORKTREES_DIR:-$HOME/.fkanban/worktrees}/<short-name>"
BR="<branch>"
# preserve your edit, restore the shared checkout to clean, branch off origin/main
cp "$REPO/<changed-file>" /tmp/closeout.$$ 2>/dev/null || true
git -C "$REPO" fetch origin --quiet
git -C "$REPO" checkout -- <changed-file>        # only if this is your own shared-checkout edit
git -C "$REPO" worktree add "$WT" -b "$BR" origin/main
# re-apply your change into $WT, then:
git -C "$WT" add -A
git -C "$WT" commit -m "<type(scope): summary>

<body>"
git -C "$WT" push -u origin "$BR"
gh pr create --repo <owner>/<repo> --base main --head "$BR" --title "..." --body "..."
```

Proof lives on the **kanban card** (`VERIFY` / `END STATE`) and in the closeout
report below, not in a PR-body `## Proof` block. Those blocks and the fold
`proof-block` CI check were removed 2026-07-03 (Tom: merge-stall churn). Do not
write them, and do not block on their absence. Produce the proof at the tier
§3 demands.

## 2. Auto-merge and babysit to MERGED

Match your repo's merge policy (see the **wait-merge** / **kanban-agent**
skills). For a merge-queue repo use bare `--auto` (no strategy flag); for plain
auto-merge add `--squash` (or your preferred method):

```bash
gh pr merge <N> --repo <owner>/<repo> --auto
```

Then drive it to merged — don't hand off at auto-merge. `BLOCKED` / red checks /
queue churn = re-poll, NOT a failure. Use the `/wait-merge` skill, or
`gh pr checks <N> --watch` (sleepless — never chain `sleep`). Verify state via:

```bash
gh pr view <N> --repo <owner>/<repo> --json state,mergeStateStatus,autoMergeRequest
```

(Auto-merge can show `autoMergeRequest:null` even when enabled — confirm via the
`enabledAt` GraphQL field.)

On GitHub, `gh pr merge <n> -R <owner>/<repo> --auto --squash` is the arm step.
If GraphQL returns a 502, use
`gh api -X PUT repos/<owner>/<repo>/pulls/<n>/merge -f merge_method=squash`.
A red or missing `ci-required` check blocks; do not use `--admin` unless a
human explicitly clears that bypass.

## 3. Produce the relevant non-test proof

No-tests policy: `instructions/no-tests.md`; Situation
`no-tests-all-repos-20261009`. Do not add, restore, run, or require tests,
fixture suites, test mutation probes, or test coverage.

Match the proof to the change:

- **No behavior change** (refactor/rename/docs): review the source and state why
  the behavior stays the same. Keep relevant format, lint, and build checks.
- **Logic change**: use the documented non-test product command or app action.
  Record its output and the result that the user requires.
- **User-visible or stateful change** (passwords, auth, settings, data writes,
  sync, UI): verify the user action through the real app on an isolated copy.
  Keep the primary brain, keyring, and live user data separate.
  Use the existing product operations and safety controls. Do not create a
  test script or fixture harness.

Anchor the proof to the **user story, not the diff** — that is what catches
half-built features ("set" shipped without "unlock", incident 2026-06-30). Record
the result in the full brain closeout report below and on the kanban card (VERIFY /
END STATE). **PR-body `## Proof` blocks and the fold `proof-block` CI check were
REMOVED 2026-07-03 (Tom: merge-stall churn)** — do not write them, and do not
block on their absence. A failing validation is still a blocker, not a footnote.

### Legacy-residue gate

If the kanban card has a `## LEGACY RESIDUE` or `## LEGACY REMOVAL` section, or
the change being closed removed a legacy code path, closeout must prove latest
fetched `main` has zero source hits before the card reaches `done`.

Use the shared helper, which is portal-aware and probes the committed tree, not
the dirty checkout:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-legacy-residue-probe" <repo-or-owner/name> '<regex>'
```

Exit 0 means zero hits. Append the proof to the card under `## OUTCOME` with
the repo/ref and command, ending in `0 hits`, for example:

```
## OUTCOME
- fold@abc1234: `last-stack-legacy-residue-probe EdgeVector/fold 'old_flag|old_fn'` -> 0 hits
```

The closeout helper re-runs this gate and refuses `done` if the proof is absent
or latest `main` still contains source hits.

### Prose-citation gate

If the change touched any agent prose -- `CLAUDE.md`, `AGENTS.md`,
`routines/*.md`, `instructions/*.md`, `skills/*/*.md`, `hooks/*.sh`, `bin/*` or
`lib/*` -- point-get every brain slug it cites before the PR:

```bash
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
"$last_stack/bin/last-stack-prose-citation-check" --root "$WT" --changed-since origin/main --one-hop
```

Scoped to the diff, so it is a few point gets and it can only fail on prose this
change touched. Measured 2026-10-04 in this repo: 0.11 s when the change touches
no prose at all, 2.3 s over an 11-file prose delta, 13.0 s with `--one-hop` over
that same delta (against 29 s for the whole root).

`--one-hop` also point-gets every `[[target]]` inside the records this change's
prose cites. A record you point a reader at, which then points them at nothing,
is the same failure one level down, and the prose extractor can never see it: it
only matches a token that starts with one of the eleven record types, so an
untyped record name is invisible to it. Measured 2026-10-04 one hop from the
installed prose: **23 of 67 targets did not resolve**, four of them inside
`sop-edgevector-portals` and four inside `sop-feature-ship-loop` --- SOPs
CLAUDE.md tells every agent to read first. A `HOP-DANGLING` row is a finding
about a record, not about your change: fix it if it is yours, otherwise report
it and ship.

- **0** -- every citation resolves. Done.
- **1** -- `DANGLING <slug>  INTRODUCED-BY-THIS-CHANGE`: the slug does not
  point-get, with or without `--type`, and it is on a line this change ADDS. Fix
  the citation or QUOTE the fact instead of citing it. Do not ship it: a dangling
  citation reads as an audited ground truth, so the next agent stops looking, and
  the rule it supports arrives with no evidence anyone can check.
- **4** -- there are findings and none is yours: `DANGLING <slug>  pre-existing`
  in a file you touched for another reason, or a `HOP-DANGLING` row one level past
  the prose. Report them -- append the slugs to the owning papercut -- and ship.
- **3** -- `UNKNOWN`: the node was busy. Not a blocker; re-run it.
- **2** -- the changed set could not be computed. Re-run with the full root
  (`--root "$WT"`, no `--changed-since`) rather than treating it as a pass.

`bin/*` and `lib/*` joined the corpus on 2026-10-04 and they are the largest
citation surface in the repo: 344 prose files against 113. A helper's comment has
the same job as an instruction file's -- it names the record holding the reason
the code is shaped this way -- and some of these are not comments at all:
`bin/last-stack-kanban-decision-check` carries a table of slugs it point-gets at
run time, so a dead slug there is a command that fails. `dangling 0` covered this
repo for eight days while **64 of its 238 helpers (27%)** cited a record the brain
cannot serve, and six of those slugs were ones the owning papercut had listed and
believed healed in the `*.md` corpus.

That 27% is also why exit 4 exists. About one change in four opens a helper with
an inherited dead pointer, and `1` carries the instruction "do not ship this". A
gate that refuses correct work over prose its author never wrote is routed around
within a day, which is this checker's own stated failure mode; the split keeps the
refusal for the pointer you just wrote.

This step is the checker's only live caller. Its scheduled one is step 2b of
`routines/papercut-reconciler.md`, and the fleet read 4 active / 77 paused on
2026-10-04, so the sweep had not run on a schedule at all -- every number in
`papercut-shipped-prose-cites-brain-slugs-that-do-not-resolve-20260926` was
produced by hand. It is NOT a merge gate on purpose: the suite must pass on a
GitHub runner with no brain installed, and a busy node must never turn a correct
PR red.

The highest-risk surface is a PreToolUse hook's deny text. It reaches an agent
mid-task, phrased as an instruction, naming a slug as the authority for a
refusal the agent must now work around -- and the agent is in a hurry. Three of
the six citations in this repo's own `hooks/*.sh` were dangling when that
surface was first scanned (2026-10-04), against `dangling 0` on the `*.md`
corpus the same day.

## 4. File papercuts — default is FILE, not judge

Close-out is the last chance to file friction that would otherwise die in chat.
A mention is not a filing. Prose in the closeout report, a PR body, or a
commit message reaches no routine. No `papercut-*` slug → not filed.
Never file a papercut kanban card. The `papercut-reconciler` is the sole
papercut→card path.

Search first (`brain ask` / `brain get`). A hit is a remedy, not just a
duplicate: append measured evidence to the live record instead of forking a
near-duplicate slug.

```bash
pc_body="$(mktemp "${TMPDIR:-/tmp}/papercut.XXXXXX")"
cat > "$pc_body" <<'EOF'
<symptom, exact output, repro, date, repo, suggested fix — `backticks` and $vars safe>
EOF
brain papercut file <slug> --component <c> --symptom "<one line>" \
  --title "<what is wrong>" --severity p0|p1|p2|p3 --body "$(cat "$pc_body")"
```

Build the body in a file with a QUOTED heredoc (`<<'EOF'`). A body typed
inside `--body "..."` runs its backticks and `$(...)` in zsh and pastes
command output into the record. Do not add `rm -f` cleanup: the Codex exec
guard rejects the whole command. Full shell rules: `sop-routine-shared-contract` §5.

If you healed the friction in this same session, file it, then close it with
evidence (a merge reference is not a live check):

```bash
brain papercut close <slug> --status fixed|verified --evidence "<what you
  checked>" --fixed-by "<repo> #<PR>" --verified-by "<live check you ran>"
```

A session that hit friction and files nothing needs an explicit reason in the
closeout report below. "Small", "probably already known", and "that one was my
own mistake" are not reasons.

## 5. Write the full closeout report to the brain

This is the durable *what was done* record — not a one-line "shipped X"
checkpoint. `preference-always-save-to-brain-when-done` already requires it;
close-out is the step that actually writes it. Prefer **update in place**:
`brain append` the design/reference already in play (stdin only — no `--body`
or `--body-path`; those flags exit 2), *and* `brain put` a short
`type: reference` closeout slug if no existing record owns this session.

Skip only for pure Q&A, one-liner answers, and failed dead-ends with no
reusable finding. Pipe the body via **stdin** or a body file, never as
shell-expanded command arguments. If the body contains backticks, `$()`,
`$var`, globs, or other shell metacharacters, write it with a quoted heredoc
so the shell cannot evaluate it. A reference `status` must be `active`,
`parked`, `broken` or `archived`; brain rejects `done`.

```bash
body_file="$(mktemp "${TMPDIR:-/tmp}/closeout.XXXXXX")"
cat > "$body_file" <<'EOF'
---
type: reference
slug: closeout-<YYYYMMDD>-<short-kebab>
title: Closeout — <one-line what shipped>
status: active
tags: [closeout]
---

## What was done
<user-visible outcome, not the diff>

## Why
<the call, the constraint, the thing a future agent would re-derive wrong>

## Proof
<command / CI job / acceptance check, and what it showed>

## Artifacts
- PR: <url>
- Card: <kanban slug or none>
- Worktree: <path or already reclaimed>

## Papercuts filed
- <papercut-slug> — <one line>
- none — <explicit reason if the session hit no fileable friction>

## Follow-ups
<kanban slugs filed in the next step, or none>

## Stale records updated
- <brain-slug> — <one line>
- <kanban-slug> — <one line>
- none — <explicit reason if this session replaced no live fact>

## Leftovers
<what was not done, and why it is safe to leave>
EOF
brain put closeout-<YYYYMMDD>-<short-kebab> --type reference < "$body_file"
# No cleanup step: the Codex exec guard rejects file deletion. $TMPDIR is the run scratch dir.
```

A `reference` status is `active`, `parked`, `broken` or `archived`. `done`
and `complete` are decision/task words; `brain put` rejects them on a
reference and the report is not written.

Point-get the slug back (`brain get closeout-<YYYYMMDD>-<short-kebab>`) before
calling the report written. Listing it in chat is not a write.

### Then publish the slug, or the next pass cannot find it

A closeout slug carries the AUTHOR'S OWN wall clock, and nothing indexes "the
newest closeout for routine R". So a later pass that wants this report has to
GUESS the time component — and a guess that misses returns a stale closeout
that reads exactly like a current one. `brain list` is refused as a census by a
PreToolUse hook and is not getting a completeness contract; `brain ask` ranks by
relevance, not recency; `linked_from` only helps when the newest closeout
happened to link a record the reader already picked. Measured on two
consecutive passes on 2026-10-03: each one built a plan from a stale open list,
between them they probed about thirty-five slug spellings, and each was sent at
a unit its predecessor had already closed `verified` hours before
(`papercut-no-stable-pointer-to-a-routines-newest-closeout-so-a-pass-guesses-slugs-and-reads-a-stale-open-list-20261003`).

**A recurring routine's close-out therefore ends by recording its slug** in a
fixed, point-readable index — one slug per routine, `closeout-index-<routine>`:

```bash
last-stack-closeout-index record <routine> closeout-<YYYYMMDD>-<short-kebab>
```

Skip it for a one-off session closeout that no later pass will look for; it is
required for anything with a NEXT pass.

**Reading it is the first step of the next pass**, and it is one point get with
no guessing. The RECORD is the durable interface, so this works even where the
helper is not installed:

```bash
brain get closeout-index-<routine> --type reference    # newest first, no helper
```

With the helper, the same answer as one line:

```bash
last-stack-closeout-index latest <routine>     # the newest closeout slug
brain get "$(last-stack-closeout-index latest <routine>)" --type reference
last-stack-closeout-index list <routine>       # the retained history, newest first
```

Exit codes are deliberately distinct, because collapsing them sends the reader
back to guessing: **3** means there is no index yet (bootstrap it by recording
one), **4** means the index may exist but could not be read — retry, never
treat it as absent. For the same reason `record` refuses a body that carries no
`## Closeouts, newest first` marker instead of rewriting it: `brain put`
replaces a whole body, and a record this tool did not write is not its to
replace.

**If a real DECISION was settled** (a call someone made — a chosen approach, an
outcome, a gate cleared), also record it as its own **`decision` record** so it
lands in the queryable decision ledger (`brain get <slug> --type decision`;
discover with `brain search`/`ask` — never `brain list` as a census). The
closeout report is not a substitute for that ledger. Use real
`program`/`gate_slug`/`decided_by`/`decided_on` columns — NOT as a prose note
and NEVER by appending to the archived `decisions-log` monolith:

```bash
body_file="$(mktemp "${TMPDIR:-/tmp}/closeout.XXXXXX")"
cat > "$body_file" <<'EOF'
---
type: decision
slug: decision-<date>-<short-kebab>
title: <one-line summary of the call>
status: <go|hold|done|moot|superseded>   # the OUTCOME
program: <owning program / North Star slug, empty string if none>
gate_slug: <open-decisions gate cleared, empty string if none>
decided_by: <who made the call, e.g. Tom>
decided_on: <RFC 3339 date>
tags: [decisions]
---

<what was chosen, why, what it unblocks — literal `backticks`/$(examples) safe>
EOF
brain put decision-<date>-<short-kebab> --type decision < "$body_file"
# No cleanup step: the Codex exec guard rejects file deletion. $TMPDIR is the run scratch dir.
```

**For a milestone / why-note that is NOT a decision** (a settled fact,
implementation record, or project checkpoint), use the appropriate note type
instead:

```bash
body_file="$(mktemp "${TMPDIR:-/tmp}/closeout.XXXXXX")"
cat > "$body_file" <<'EOF'
---
type: project
title: <title>
tags: [<...>]
---

<body with literal `backticks` and $(examples)>
EOF
brain put <slug> --type project < "$body_file"
# No cleanup step: the Codex exec guard rejects file deletion. $TMPDIR is the run scratch dir.
```

## 6. Update superseded brain records and stale kanban cards

Close-out is the last chance to stop a later agent from following a fact this
session replaced. A new closeout report that sits next to an unpatched
preference still teaches the old fact. Scope the pass to **this session's
facts**. Do not run a full-brain census (`brain list` is not a membership
instrument). Daily `last-stack-consolidate-brain` only flips statuses; it does
not rewrite stale bodies. For a larger truth-drift pass see
`checkpoint-brain-consolidation-truth-drift-20260808`.

### Brain

1. Name the facts this session replaced (old path, old command, old status,
   old venue, old column, old writer path).
2. `brain ask` each fact (limit ~8). Point-get every hit that still reads as
   current instruction.
3. For each record that still teaches the old fact:
   - If the whole record is replaced: `brain status <slug> superseded --type
     preference` (or `archived` for reference / sop / project as appropriate).
   - Always `brain append` a dated `## SUPERSEDED YYYY-MM-DD` block that states
     the new fact and the replacing slug.
   - Never get→edit→put a large record. `brain get` windows at ~40K chars; a
     re-put truncates what you did not see.
4. Point-get every write. Listing it in chat is not a write.
5. Dated incident narratives that name old paths *as history* stay. Only
   correct records that teach the old fact as current instruction.

### Kanban

1. Search the default board for cards that name the old fact, the old blocker,
   or a CR/PR this session merged (`kanban search`, then `kanban show` the
   hits). Also re-read the card you just drove.
2. If a `Kind: pr` card's PR/CR is merged and VERIFY / END STATE holds, close
   it with `last-stack-card-closeout` (not a bare `move done`).
3. If a non-PR card's `DONE-WHEN` already holds, evaluate with
   `last-stack-kanban-done-when-eval`, append `PROOF`, then move `done`.
4. If body text still says `BLOCKED` on a dependency that is now `done`, append
   `RESOLVED YYYY-MM-DD:` and drop the stale block claim.
5. Do not mark a card `done` because it is old or quiet. Do not clear a real
   `needs_human` gate.

Record every slug you updated in the closeout report under **Stale records
updated**.

## 7. File a kanban card for anything that closes later

If the work leaves a follow-up that closes by elapsed time or by someone else
(a verification window, a prod cutover, a human gate), file it so it's not
tracked only in your head.

```bash
cat > /tmp/kanban-follow-up.md <<'EOF'
Repo: <owner>/<repo>
Base: main
Kind: pr

## GOAL
...

## END STATE
...

## VERIFY
...
EOF
last-stack-kanban-file-pr <valid-slug> \
  --title "<title>" --repo <owner>/<repo> \
  --north-star "<live-ns>" --milestone "<live-ms>" \
  --column todo --tags <...> < /tmp/kanban-follow-up.md
```

Kind:pr follow-ups go through `last-stack-kanban-file-pr` so the settled-decision
check runs. Do not pass `--skip-decision-check`. If the helper refuses, rewrite
the brief so it honors the named records, or do not file.

Slugs must be lowercase `[a-z0-9-_]`, start with a letter/digit. The body must
include `Repo:`/`Base:` headers; use `Kind: registry` or `Kind: tracker` plus
the same ownership headers for non-PR follow-ups. `--body` replaces the whole
body (dump + concatenate first if you mean to append).

## 8. Update memory if the fact is durable

If you learned something cross-session (a corrected assumption, a new standing
rule), record it where your agent keeps durable memory. Don't duplicate what the
repo/git already records.

---

**Self-check before you consider the work done:** Is there a routed PR/CR? Is it
on auto-merge and being driven to merged? Did you produce proof at the §3 tier
— and for user-visible/stateful work, did an acceptance check actually run the
app and pass (round trip across a restart, plus a negative case)? Were session
papercuts filed with `brain papercut file` (or is there an explicit none-reason)?
Did `brain get` return the full closeout report? Did you `brain ask` for the
facts this session replaced and update every live record that still taught the
old fact? Did you search kanban for cards this session made stale and close or
annotate them with proof? Is every deferred follow-up a card? If any answer is
"no" and the step applies — do it now.
