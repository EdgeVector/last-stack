---
name: kanban-grooming
description: Use when auditing or grooming Kanban board health: dependency-stub reconciliation, stale generated blockers, malformed Repo/Base/Kind headers, stale review/doing placement, superseded trackers, pickup-ready counts, or unblock accounting. Triage-only; never ships feature code.
---

# Kanban Grooming

This skill is for board hygiene, not feature implementation. Use it with the
`kanban-card-authoring` rules for exact card shape.

## Start

1. Check Situations before mutating board state.
2. Use socket-backed board reads; do not run doctor/init or restart LastDB for
   `:9001` or busy-node errors.
3. Use capped or column-scoped reads for routine automation. Read full card
   bodies only for selected cards with `kanban show <slug>`.

## Audit Checklist

Run these checks and repair only when the evidence is clear:

- **Dependency stubs:** For active cards tagged `dependency-stub`, determine
  whether the prerequisite is already done under another slug. Use kanban,
  Brain, repo history, PRs, and current source. If done, append a `PROOF
  <date>:` note and move the stub to `done`. If not done, rewrite it into a real
  tracker/PR/validation card with clean headers and dependencies.
- **Dependent unblock accounting:** After closing dependency cards, list direct
  dependents and separate cards now `blocked:false` from cards still blocked by
  another dependency or intentional gate.
- **Generated repo-block damage:** Clear `needs_human` blockers whose reason is
  only `Repo target not resolvable` / `kanban-pickup cannot resolve Repo` when
  the correct repo is evident from the body, title, tags, or known checkout.
  Normalize standalone `Repo: owner/name`, `Base: main`, and `Kind:` headers.
  Leave a real human gate only when ownership is genuinely unclear.
- **Review lane hygiene:** `review` is for human gates, failed/awaiting
  validation, or real PR review state. If a card has no PR/branch and no real
  gate, move it back to `todo`. If it is already proven done, append proof and
  move it to `done`.
- **Doing lane hygiene:** A stale historical tracker in `doing` should be moved
  out. Close it only with proof that it is complete or clearly superseded; else
  move it back to `todo` with a note.
- **Stale block text:** Remove body text that says `BLOCKED` when the referenced
  blocker is already `done`; add a short `RESOLVED <date>:` note instead.
- **Pickup count:** Report the count of unblocked `todo` cards, then the subset
  that is pickup-routable: `kind` in `pr|validation` and non-empty `repo` and
  `base`.

## Do Not

- Do not mark a card `done` merely because it is old, quiet, or probably fixed.
- Do not remove human gates that require Tom, production credentials, biometric
  prompts, destructive force-pushes, or installed-app upgrades.
- Do not guess across multiple plausible repos. Split the card or leave a crisp
  human question.
- Do not rewrite large bodies wholesale unless needed; preserve useful context
  and append concise proof/resolution notes.

## Useful Queries

```text
kanban list --column todo --limit 200 --json > /tmp/kanban-todo.json
kanban list --column doing --limit 100 --json > /tmp/kanban-doing.json
kanban list --column review --limit 100 --json > /tmp/kanban-review.json
jq -s 'add' /tmp/kanban-todo.json /tmp/kanban-doing.json /tmp/kanban-review.json \
  > /tmp/kanban-active.json

# Active missing dependency slugs
jq -r '.[] | select(.column!="done" and ((.missingDeps//[])|length>0))
  | [.slug,.column,((.missingDeps//[])|join(","))] | @tsv' /tmp/kanban-active.json

# Stale generated repo blockers
jq -r '.[] | select(.column!="done" and .block_status=="needs_human"
  and ((.block_reason//"")|test("Repo target not resolvable|kanban-pickup cannot resolve Repo")))
  | [.slug,.column,.repo,.base,.kind,.block_reason] | @tsv' /tmp/kanban-active.json

# Pickup-ready count
jq '[.[] | select(.column=="todo" and (.blocked|not)
  and (.kind=="pr" or .kind=="validation")
  and ((.repo//"")!="") and ((.base//"")!=""))] | length' /tmp/kanban-active.json
```
