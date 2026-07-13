---
name: eli5
description: |
  Explain the current technical or design state of something in plain English —
  the recurring "ELI5 this for me" request. Translates a design, a PR, an error,
  a piece of architecture, or "the current state" of an in-flight feature into a
  clear analogy + concrete mechanics + the one decision that actually matters to
  the user. Grounds the explanation in real state (brain notes, the code, gh,
  the actual error) — never explains "current state" from memory. Offers a
  diagram when one would help.
  Use when the user says "ELI5", "Eli-fy it", "explain like I'm 5", "eli5 the
  current state", "what is X / what does this mean, simply", "explain X to me
  simply", "I don't understand X", or asks for a plain-English status of an
  in-flight design.
allowed-tools:
  - Bash
  - Read
  - Grep
  - Glob
triggers:
  - eli5
  - eli-fy
  - explain like i'm 5
  - explain simply
  - eli5 the current state
  - what does this mean simply
---

# ELI5 — explain the real state in plain English

You ask for this constantly ("Eli five the current state", "What is flipping?
Can you Eli-fy it", "ELI5 the issue", "ELI5 what app registration is"). This
skill makes the answer consistent and, crucially, **true** — grounded in what
the code/design actually is right now, not what you half-remember it to be.

## The one rule that matters: ground before you explain

The failure mode for an ELI5 is a confident, fluent explanation of a state that
isn't real. Before writing a word, figure out *what the user is pointing at* and
**check the source of truth for it**:

| They're pointing at… | Ground it by… |
|---|---|
| "the current state" of an in-flight design/feature | `mcp__brain__brain_search` / `brain_get` for the project note; recent PRs (`gh pr list`, `gh pr view`); the design doc in exemem-workspace |
| a PR / a change | `gh pr view <n> -R <owner>/<repo> --json title,body,files` + read the actual diff |
| an error / failure | read the real error text and the code path that emits it |
| an architecture/concept ("what is an app in folddb", "TCP off") | read the relevant code + the CLAUDE.md / repo docs; check the memory index for a settled answer |
| "is X done / built yet?" | check origin/main and the relevant PR state — local checkouts and your memory both lag |

If you genuinely can't tell which thing they mean, ask one short clarifying
question. Otherwise pick the most likely target, **state which target you
assumed in one line**, and explain that.

Never assert "this is built" / "TCP is off" / "X works today" without having
just confirmed it from code or PR state in this turn. The EdgeVector design
threads move fast; a memory note reflects what was true when written.

## The shape of a good ELI5

Keep it tight. Three beats, in this order:

1. **The analogy / one-sentence gist** — the plain-English "it's basically like
   ___" that makes the rest click. Lead with this.
2. **The concrete mechanics** — what actually happens, in 2–5 short bullets, in
   the user's domain terms (apps, schemas, nodes, the primary folddb_server brain, exemem,
   the bulletin board). Name the real pieces so it connects to the codebase.
3. **What it means for you** — the payoff: the decision the user actually has to
   make, what's blocked on what, or "nothing to do, it just works." End here,
   not on a wall of detail.

Then stop. An ELI5 that runs long has failed at being an ELI5.

## Offer a diagram when the thing is structural

If the explanation is about how pieces connect, a flow, or a before/after
(app↔node↔exemem, schema namespacing, the isolation boundary), a small diagram
beats three paragraphs. Use the `visualize` widget (`mcp__visualize__show_widget`,
read its `read_me` first). One clean diagram, not decoration.

## Calibration

- Match the user's actual level: they're the founder/architect of this system,
  not a literal five-year-old. "ELI5" means *strip jargon and cut to the gist*,
  not *condescend*. Skip the parts they obviously know; spend the words on the
  part that's actually confusing.
- If the honest answer is "this is more tangled than it should be," say that —
  a clear "here's why it's confusing" is more useful than false simplicity.
- If grounding reveals the design has drifted from a memory/brain note, flag
  the drift explicitly ("the note says X, but main now does Y").
