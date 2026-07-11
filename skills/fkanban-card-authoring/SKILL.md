---
name: fkanban-card-authoring
description: Use when Codex needs to create, update, repair, groom, or review F-Kanban cards so pickup agents can route them safely. Trigger for card authoring, board hygiene, repo-resolution errors, malformed Repo/Base/Kind headers, stale needs_human block reasons, pickup-area conflicts, north-star/dependency setup, or converting a durable task into live work.
---

# F-Kanban Card Authoring

Create cards that pickup can route without human cleanup. Prefer MCP tools when
available; use the CLI fallback only when MCP is unavailable.

## Start

Check the board before adding work:

```bash
fkanban list
```

Search before creating a duplicate:

```bash
fkanban search "short problem phrase"
```

For one existing card, use `fkanban show <slug>` before rewriting its body.

## Required Shape

Every new live card needs either `--north-star <slug>` or an `## END STATE`
section in the body.

If the card names a repo, the body must include clean standalone headers:

```text
Repo: EdgeVector/fold
Base: main
Kind: pr
```

Rules:
- `Repo:` must be a bare `owner/name` token on the line. No inline comments,
  parentheticals, secondary repos, or prose.
- Use `EdgeVector/<repo>` for private EdgeVector repos.
- Do not stamp guessed repos. If ownership is genuinely unknown, leave the
  repo header out and make the body say what must be decided.
- Put multi-repo scope in the body, not in `Repo:`.
- Do not create parent/project cards in F-Kanban. Track umbrellas, programs,
  capstones, broad trackers, and other parent context as F-Brain North Stars.
- Use `Kind: pr` for executable code/doc work and `Kind: validation` for
  proof-only runs. `registry`, `meta`, `tracker`, `umbrella`, `program`, and
  `capstone` are legacy read-only/non-executable kinds and new writes reject
  them. If work is not agent-pickup or an explicit human wait, it does not
  belong in F-Kanban.

## Write Bodies

Use a body that lets an agent start without rediscovering context:

```markdown
Repo: EdgeVector/fold
Base: main
Kind: pr
North Star: north-star-example

## PROBLEM
What is broken or missing.

## GOAL
What should be true when the card is done.

## CONTEXT
Important links, prior PRs, fbrain records, commands, or constraints.

## END STATE
- Code/config/docs change landed, or validation proof recorded.
- Validation performed and noted.
- Card moved only when the stated end state is true.
```

For CLI writes, keep the card body off the shell command line. Pipe a
single-quoted heredoc on stdin:

```bash
fkanban add <slug> --title "Short title" --column todo --north-star <north-star> <<'EOF'
Repo: EdgeVector/fold
Base: main
Kind: pr

## PROBLEM
What is broken or missing.

## END STATE
- The desired outcome is proven.
EOF
```

Do not use `--body "$(cat <<EOF ...)"` or any shell-expanded string for
Markdown/card text. Backticks, `$()`, and card headers can be evaluated by the
shell before fkanban sees them, corrupting the card.

Avoid boilerplate that creates false routing signals. In particular, do not use
free-form prose like "fbrain agent" or "fkanban agent" as an ownership hint.
Use explicit tags or structured fields instead.

## Update Existing Cards

`fkanban add --body` replaces the whole body. Always read the existing body
first, merge your edit locally, then write the full new body.

Do not clear user-authored context unless the task explicitly asks for cleanup.
If the card has stale generated damage, remove only that damage:
- inline comments on `Repo:`
- obsolete `BLOCKED: fkanban-pickup cannot resolve Repo...` lines
- stale `needs_human` block reasons after the underlying resolver bug is fixed
- bogus area tags known to be derived from old boilerplate

## Dependencies And Blocking

Use dependencies when sequencing is real:

```bash
fkanban dep add dependent-card prerequisite-card
```

A card with unfinished dependencies cannot enter `doing`, `review`, or `done`
without `--force`; do not force unless the dependency is explicitly obsolete or
the user asked for it.

Use `block_status=needs_human` only for a real human gate. Repo parsing,
tooling bugs, or stale pickup metadata are papercuts to fix, not human gates.

## Done Discipline

A code card is not done when a PR is opened. It is done when the code is merged
or the card's explicit end state is proven. A validation card is done when the
requested proof exists and is recorded.
