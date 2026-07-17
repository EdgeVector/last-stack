---
name: close-out
version: 0.2.0
description: Run the full close-out loop after finishing a substantive change — worktree PR + auto-merge, a brain checkpoint, and a kanban follow-up card. Use after landing any code/doc change or settled decision, or when the close-out backstop hook fires. These steps are standing-authorized; do them without asking.
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
PR, nothing saved to the brain, no follow-up card. Run these steps automatically;
don't ask permission for the mechanical parts. Only stop for a genuine fork
(branch base? dev vs prod? a design choice).

Run the steps that apply to what you just did. Skip ones that don't.

This loop assumes two LastDB surfaces:
- **Brain** (`brain`) — long-lived notes: the *why*, settled decisions,
  milestones.
- **Kanban** (`kanban`) — what's in flight: cards moving through columns.

(Adjust the CLI names if your brain/board tools differ.)

## 1. PR it — from a worktree, never the shared main checkout

If your changes are sitting in a shared main checkout, move them to a worktree
first — `git add -A` in a shared checkout can sweep sibling work into your
commit. Always work in an isolated worktree.

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
WT="$HOME/code-worktrees/<short-name>"
BR="<branch>"
# preserve your edit, restore the shared checkout to clean, branch off origin/main
cp "$REPO/<changed-file>" /tmp/closeout.$$ 2>/dev/null || true
git -C "$REPO" fetch origin --quiet
git -C "$REPO" checkout -- <changed-file>        # only if you edited in the main checkout
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
  throwaway data dir** (`mktemp -d`, `FOLDDB_DISABLE_KEYCHAIN=1`; never `~/.folddb`
  or the primary brain/keyring). It must cross a **process boundary** (restart /
  re-open) between the write and the read, and include a **negative case**. No
  script yet? Write one from the SOP `sop-autonomous-acceptance-gate` template.

Anchor the proof to the **user story, not the diff** — that is what catches
half-built features ("set" shipped without "unlock", incident 2026-06-30). Record
the result in the brain checkpoint below and on the kanban card (VERIFY /
END STATE). **PR-body `## Proof` blocks and the fold `proof-block` CI check were
REMOVED 2026-07-03 (Tom: merge-stall churn)** — do not write them, and do not
block on their absence. A failing validation is still a blocker, not a footnote.

## 4. Checkpoint the decision to the brain

Save the *why* / the settled decision / the milestone. Brain = why + decision;
Kanban = what's in flight. Pipe big Markdown bodies via **stdin** or a body
file, never as shell-expanded command arguments. If the body contains backticks,
`$()`, `$var`, globs, or other shell metacharacters, write it with a quoted
heredoc so the shell cannot evaluate it.

**If a real DECISION was settled** (a call someone made — a chosen approach, an
outcome, a gate cleared), record it as its own **`decision` record** so it lands
in the queryable decision ledger (`brain list --type decision`) with real
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

## 5. File a kanban card for anything that closes later

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

## 6. Update memory if the fact is durable

If you learned something cross-session (a corrected assumption, a new standing
rule), record it where your agent keeps durable memory. Don't duplicate what the
repo/git already records.

---

**Self-check before you consider the work done:** Is there a routed PR/CR? Is it
on auto-merge and being driven to merged? Does the PR carry a verified `## Proof`
block at the right tier — and for user-visible/stateful work, did an acceptance
check actually run the app and pass (round trip across a restart, plus a negative
case)? Is the decision in the brain? Is every deferred follow-up a card? If any
answer is "no" and the step applies — do it now.
