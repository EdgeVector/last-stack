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

## 3. Checkpoint the decision to the brain

Save the *why* / the settled decision / the milestone. Brain = why + decision;
Kanban = what's in flight. Pipe big bodies via **stdin**, not as command args
(args may not shell-expand and can clobber the record):

```bash
printf '%s\n' '---' 'type: project' 'title: <title>' 'tags: [<...>]' '---' '' '<body>' \
  | fbrain put <slug> --type project
```

## 4. File an fkanban card for anything that closes later

If the work leaves a follow-up that closes by elapsed time or by someone else
(a verification window, a prod cutover, a human gate), file it so it's not
tracked only in your head.

```bash
fkanban add <valid-slug> --title "<title>" --column todo --tags <...> --body "<...>"
```

Slugs must be lowercase `[a-z0-9-_]`, start with a letter/digit. `--body`
replaces the whole body (dump + concatenate first if you mean to append).

## 5. Update memory if the fact is durable

If you learned something cross-session (a corrected assumption, a new standing
rule), record it where your agent keeps durable memory. Don't duplicate what the
repo/git already records.

---

**Self-check before you consider the work done:** Is there a PR? Is it on
auto-merge and being driven to merged? Is the decision in the brain? Is every
deferred follow-up a card? If any answer is "no" and the step applies — do it now.
