---
name: close-out
version: 0.3.0
description: Run the full close-out loop after finishing a substantive change — worktree PR + auto-merge, file session papercuts, write a full brain report of what was done, and file a kanban follow-up card. Use after landing any code/doc change or settled decision, or when the close-out backstop hook fires. These steps are standing-authorized; do them without asking.
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
skip papercut filing or the full brain report on a substantive session — those
are the two LastDB writes this loop exists to force. See
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

Use GitHub `gh` only when `venue=github`; use the local Forgejo SOP/API helper
when `venue=forgejo`; use `lastgit cr` when `venue=lastgit`. LastGit routing is
explicit opt-in only. For LastGit-native repos, read
`brain get sop-lastgit-native-forge-workflow`, push the branch to the `lastgit`
remote, create `lastgit cr create <slug> --head <branch> --base main
--auto-merge --require-status <context> --json`, and drive it with
`lastgit cr view`, `lastgit ci status`, and `lastgit cr complete --once`. Do not
run LastGit CI watchers against the primary brain socket.

Close-out/backstop hooks that check for local commits ahead of the canonical
remote should resolve the comparison ref through the same helper:

```bash
compare_ref="$("$last_stack/bin/last-stack-pr-venue" --compare-ref <owner>/<repo> "$WT")"
git -C "$WT" rev-list --count "$compare_ref"..HEAD
```

For LastGit-native repos this uses `lastgit/<current-branch>` when present, so a
local `main` that already matches `lastgit/main` is not reported as unpushed just
because `origin/main` is a lagging mirror. Non-LastGit repos keep the existing
upstream/origin comparison behavior.

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

**Every PR body carries a `## Proof` block** — nothing lands unproven (SOP
`sop-autonomous-acceptance-gate`). Keep it proportional to blast radius:

```
## Proof
- Claim:    <the user-visible capability this makes work, one sentence>
- Tier:     <no-behavior-change | unit+negative | user-visible-roundtrip>
- How:      <exact command(s) / test name(s), or the acceptance script path>
- Verified: <what — other than me — confirmed it: CI job, a fresh agent that ran the app>
```

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

For LastGit-native repos, `lastgit cr create ... --auto-merge --require-status
<context>` is the arm step. A foreground `lastgit cr complete <slug> --once
--json` is the cheap merge driver once `lastgit ci status <head-oid> --repo
<slug> --json` is green. Red/missing status blocks; do not use `--admin` unless
a human explicitly clears that bypass.

## 3. Produce the proof — at the tier the change demands

Nothing lands unproven, and "proven" is checked by something other than you (an
agent ran it / CI, not a human eyeballing). Match the proof to blast radius:

- **No behavior change** (refactor/rename/docs) → existing tests green; state why
  it's behavior-preserving. Done.
- **Logic with a testable unit** → a unit/integration test of the new behavior
  **plus a negative case**.
- **User-visible or stateful** (passwords, auth, settings, data writes, sync, UI)
  → run the feature's `test/acceptance/<feature>.sh` against the **real app on a
  throwaway data dir** (`mktemp -d`, `FOLDDB_DISABLE_KEYCHAIN=1`; never `~/.lastdb` or `~/.folddb`
  or the primary brain/keyring). It must cross a **process boundary** (restart /
  re-open) between the write and the read, and include a **negative case**. No
  script yet? Write one from the SOP `sop-autonomous-acceptance-gate` template.

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
brain papercut file <slug> --component <c> --symptom "<one line>" \
  --title "<what is wrong>" --severity p0|p1|p2|p3 --body "<symptom, exact
  output, repro, date, repo, suggested fix>"
```

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
`brain append` the design/reference already in play, *and* `brain put` a short
`type: reference` closeout slug if no existing record owns this session.

Skip only for pure Q&A, one-liner answers, and failed dead-ends with no
reusable finding. Pipe the body via **stdin** or a body file, never as
shell-expanded command arguments. If the body contains backticks, `$()`,
`$var`, globs, or other shell metacharacters, write it with a quoted heredoc
so the shell cannot evaluate it.

```bash
body_file="$(mktemp)"
cat > "$body_file" <<'EOF'
---
type: reference
slug: closeout-<YYYYMMDD>-<short-kebab>
title: Closeout — <one-line what shipped>
tags: [closeout]
---

## What was done
<user-visible outcome, not the diff>

## Why
<the call, the constraint, the thing a future agent would re-derive wrong>

## Proof
<command / CI job / acceptance check, and what it showed>

## Artifacts
- PR/CR: <url or lastgit://slug/cr/id>
- Card: <kanban slug or none>
- Worktree: <path or already reclaimed>

## Papercuts filed
- <papercut-slug> — <one line>
- none — <explicit reason if the session hit no fileable friction>

## Follow-ups
<kanban slugs filed in the next step, or none>

## Leftovers
<what was not done, and why it is safe to leave>
EOF
brain put closeout-<YYYYMMDD>-<short-kebab> --type reference < "$body_file"
rm -f "$body_file"
```

Point-get the slug back (`brain get closeout-<YYYYMMDD>-<short-kebab>`) before
calling the report written. Listing it in chat is not a write.

**If a real DECISION was settled** (a call someone made — a chosen approach, an
outcome, a gate cleared), also record it as its own **`decision` record** so it
lands in the queryable decision ledger (`brain get <slug> --type decision`;
discover with `brain search`/`ask` — never `brain list` as a census). The
closeout report is not a substitute for that ledger. Use real
`program`/`gate_slug`/`decided_by`/`decided_on` columns — NOT as a prose note
and NEVER by appending to the archived `decisions-log` monolith:

```bash
body_file="$(mktemp)"
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
rm -f "$body_file"
```

**For a milestone / why-note that is NOT a decision** (a settled fact,
implementation record, or project checkpoint), use the appropriate note type
instead:

```bash
body_file="$(mktemp)"
cat > "$body_file" <<'EOF'
---
type: project
title: <title>
tags: [<...>]
---

<body with literal `backticks` and $(examples)>
EOF
brain put <slug> --type project < "$body_file"
rm -f "$body_file"
```

## 6. File a kanban card for anything that closes later

If the work leaves a follow-up that closes by elapsed time or by someone else
(a verification window, a prod cutover, a human gate), file it so it's not
tracked only in your head.

```bash
cat > /tmp/kanban-follow-up.md <<'EOF'
Repo: <owner>/<repo>
Base: main
Branch: kanban/<valid-slug>
Kind: pr

## GOAL
...

## VERIFY
...
EOF
kanban add <valid-slug> --title "<title>" --column todo --tags <...> --repo <owner>/<repo> --base main --branch kanban/<valid-slug> --kind pr < /tmp/kanban-follow-up.md
```

Slugs must be lowercase `[a-z0-9-_]`, start with a letter/digit. The body must
include `Repo:`/`Base:` headers; use `Kind: registry` or `Kind: tracker` plus
the same ownership headers for non-PR follow-ups. `--body` replaces the whole
body (dump + concatenate first if you mean to append).

## 7. Update memory if the fact is durable

If you learned something cross-session (a corrected assumption, a new standing
rule), record it where your agent keeps durable memory. Don't duplicate what the
repo/git already records.

---

**Self-check before you consider the work done:** Is there a routed PR/CR? Is it
on auto-merge and being driven to merged? Does the PR carry a verified `## Proof`
block at the right tier — and for user-visible/stateful work, did an acceptance
check actually run the app and pass (round trip across a restart, plus a negative
case)? Were session papercuts filed with `brain papercut file` (or is there an
explicit none-reason)? Did `brain get` return the full closeout report? Is every
deferred follow-up a card? If any answer is "no" and the step applies — do it
now.
