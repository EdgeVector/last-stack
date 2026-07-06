---
name: fbrain-writing
description: Use when Codex needs to create, update, append to, status-patch, search for, or preserve durable F-Brain records. Trigger for LastDB/F-Brain writes, long-lived decisions or rationale, papercut records, SOP/reference updates, large record edits, decisions-log updates, fbrain_put/fbrain_append/fbrain_status usage, or MCP JSON/schema errors while writing brain records.
---

# F-Brain Writing

Use F-Brain for durable "why" context: decisions, rationale, preferences,
references, incidents, SOPs, and process lessons. Use F-Kanban for live work
state.

Prefer MCP tools when available. Use the CLI only as a fallback or when it is
simpler for shell-safe input.

## Search First

Before creating a record, search for an existing one:

```bash
fbrain ask "short specific query"
fbrain search "exact rare phrase"
```

Update an existing record when it clearly owns the topic. Do not create a near
duplicate just because a slug is inconvenient.

## Pick The Write Primitive

- New or full replacement: `fbrain_put`
- Add to an existing long record: `fbrain_append`
- Change only status: `fbrain_status`
- Read one record: `fbrain_get`
- Best recall: `fbrain_ask`

Do not use `fbrain_put` for a status-only change; it is a full replace and can
wipe the body. Do not get a large paginated body and re-put it unless you have
read every page and intend a full rewrite.

## MCP JSON Rules

When calling MCP tools, the input must be valid JSON before F-Brain sees it.

Correct tags:

```json
{"tags":["fold","submodule","git"]}
```

Incorrect tags:

```json
{"tags": fold,submodule,git}
```

If a small `fbrain_put` call fails with a generic "could not be parsed as JSON"
message, first check arrays and quoted strings, especially `tags`. Do not jump
to body-size or backslash theories.

## Large Or Multiline Bodies

For bodies over about 1 KB, multiline content, emoji, or complex Markdown, use
`body_path` or `body_b64` instead of inline `body`. Long inline JSON strings can
be dropped or malformed before reaching the server.

For CLI writes, stage frontmatter + body and pipe it:

```bash
fbrain put <<'EOF'
---
type: reference
slug: example-slug
title: Example title
tags: [example, process]
---
Body text.
EOF
```

## Append Safely

Use append for growing logs, ledgers, SOP notes, or large records:

```json
{"slug":"retro-prevention-ledger","type":"reference","text":"New chunk"}
```

`fbrain_append` accepts `text` or `chunk` for short content, and `chunk_path` or
`chunk_b64` for larger content. It only grows the body, so it avoids windowed
get -> truncated put mistakes.

## Decisions

Do not create new `type: decision` records unless the system explicitly says
that path is fixed and desired. Append decisions to the `decisions-log`
reference record instead.

## Health And Errors

The live LastDB node uses the Unix socket, not retired TCP `:9001`. A
`:9001` failure from old doctor/init paths is not a dead brain.

Treat `service_timeout`, `node did not respond`, and `too many concurrent
reads` as load/backpressure. Retry bounded idempotent reads or slug upserts; do
not restart the node to "fix" load.

## Close Out

After writing, confirm the result if the record will guide future work:

```bash
fbrain get example-slug
```

For papercuts, include what happened, impact, owner or likely repo, and desired
fix. If there is actionable work, create or update the matching F-Kanban card.
