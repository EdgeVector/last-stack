---
name: close-out
version: 0.2.0
description: Run the full close-out loop after finishing a substantive change — worktree PR + auto-merge, a brain checkpoint, and an fkanban follow-up card. Use after landing any code/doc change or settled decision, or when the close-out backstop hook fires. These steps are standing-authorized; do them without asking.
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
- **Brain** (`fbrain`) — long-lived notes: the *why*, settled decisions,
  milestones.
- **Kanban** (`fkanban`) — what's in flight: cards moving through columns.

(Adjust the CLI names if your brain/board tools differ.)

## 1. PR it — from a worktree, never the shared main checkout

If your changes are sitting in a shared main checkout, move them to a worktree
first — `git add -A` in a shared checkout can sweep sibling work into your
commit. Always work in an isolated worktree.

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

Match your repo's merge policy (see the **wait-merge** / **fkanban-agent**
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
the result in the Proof block and the brain checkpoint below. A failing or absent
proof is a blocker, not a footnote.

## 4. Checkpoint the decision to the brain

Save the *why* / the settled decision / the milestone. Brain = why + decision;
Kanban = what's in flight. Pipe big Markdown bodies via **stdin** or a body
file, never as shell-expanded command arguments. If the body contains backticks,
`$()`, `$var`, globs, or other shell metacharacters, write it with a quoted
heredoc so the shell cannot evaluate it:

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
fbrain put <slug> --type project < "$body_file"
rm -f "$body_file"
```

## 5. File an fkanban card for anything that closes later

If the work leaves a follow-up that closes by elapsed time or by someone else
(a verification window, a prod cutover, a human gate), file it so it's not
tracked only in your head.

```bash
cat > /tmp/fkanban-follow-up.md <<'EOF'
Repo: <owner>/<repo>
Base: main
Branch: fkanban/<valid-slug>
Kind: pr

## GOAL
...

## VERIFY
...
EOF
fkanban add <valid-slug> --title "<title>" --column todo --tags <...> --repo <owner>/<repo> --base main --branch fkanban/<valid-slug> --kind pr < /tmp/fkanban-follow-up.md
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

**Self-check before you consider the work done:** Is there a PR? Is it on
auto-merge and being driven to merged? Does the PR carry a verified `## Proof`
block at the right tier — and for user-visible/stateful work, did an acceptance
check actually run the app and pass (round trip across a restart, plus a negative
case)? Is the decision in the brain? Is every deferred follow-up a card? If any
answer is "no" and the step applies — do it now.
