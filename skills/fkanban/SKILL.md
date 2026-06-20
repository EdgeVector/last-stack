---
name: fkanban
description: |
  Manage the fkanban board — a kanban over LastDB. File, list, show, move,
  groom, and soft-delete cards via the fkanban CLI. Use when the user wants to
  "file an fkanban task/card", "add to the board", "what's on the board",
  "backlog", "list tasks", "move a card", "show card <slug>", or "groom the
  board". This is the board-CRUD counterpart to the fkanban-agent skill (which
  drives one card to a merged PR); use fkanban-agent — not this — to actually
  implement a card.
---

# fkanban — board management

fkanban is a kanban task board stored in **LastDB**: a thin CLI/MCP client of a
LastDB node. Cards move through columns; every change persists in the node.

- **Location / how to run:** clone `fkanban` and run its `src/cli.ts` under
  **bun**. A global shim (`fkanban`) can be symlinked onto your PATH so a bare
  `fkanban <command>` resolves from anywhere; without it, run
  `bun run src/cli.ts <command>` from the repo directory. See the
  **fkanban-setup** skill for install.
- **⚠️ PATH gotcha (sandboxed shells):** some agent harnesses run shell commands
  **sandboxed** with a stripped `$PATH`, so a bare `fkanban …` fails with
  `command not found: fkanban`, and even after you add the shim's directory the
  shim's internal `exec bun` can then fail with `command not found: bun`. Both
  the shim dir and the bun dir must be on PATH. The robust fix is to prepend a
  complete PATH that includes both at the start of every fkanban Bash call (PATH
  does not persist between calls), or invoke the CLI directly:
  `cd <fkanban-repo> && PATH="$HOME/.bun/bin:$PATH" bun run src/cli.ts <command>`.
  `fkanban doctor` reports whether the shim is on PATH.
- **Where the data lives:** the board records live on **your LastDB node**. The
  CLI talks to the node over **HTTP**, so it's fast. The node URL is
  **configurable** — `init` defaults to a node running locally on your machine;
  point it elsewhere with `--node-url` / the config file (`~/.fkanban/config.json`).
- **Columns:** `backlog → todo → doing → review → done`.

Before doing anything non-trivial, sanity-check the setup:

```bash
fkanban doctor      # shim on PATH, config present, node reachable, schemas loaded
```

## Commands

(With the shim on PATH these run from anywhere; otherwise replace `fkanban`
with `bun run src/cli.ts` and run from the fkanban repo directory.)

```bash
fkanban list --json                 # whole default board
fkanban list --board <b> --column todo   # filter
fkanban show <slug> --json          # one card in detail
fkanban add <slug> [flags]          # create OR update a card
fkanban move <slug> <column> [--position N]
fkanban rm <slug>                   # soft-delete
fkanban board create <slug> --title ... --columns a,b,c
fkanban board list
```

`add` flags: `--title --board --column --assignee --tags --body`. Re-running
`add` with the same slug **updates** the card (upsert), so it's safe to edit a
card by re-adding it. Default column for a fresh card is `backlog`; for a task
you want worked soon, pass `--column todo`.

### Filing a card with a real body — feed it via stdin

The card body is usually a multi-paragraph spec. Write it to a temp file and
pipe it in on **stdin** — that sidesteps shell quoting entirely. **Do not**
inline it with a nested heredoc (`--body "$(cat <<'EOF' ... EOF)"`) — that
mangles and can silently produce an empty card.

```bash
# 1. write the spec
cat > /tmp/card-body.md <<'EOF'
...full markdown body...
EOF
# 2. file the card (stdin body)
fkanban add my-slug \
  --title "Short imperative title" \
  --column todo --tags "app,cli,perf" < /tmp/card-body.md
# 3. verify it landed
fkanban show my-slug | head -8
```

Always confirm with `show <slug>` after writing — the `add` is only successful
if the card actually reads back.

`add` is two keyed point reads + one write (~0.2s) and every request carries a
30s deadline (`FKANBAN_HTTP_TIMEOUT_MS` to override), so commands fail fast
instead of hanging on a busy node. A `service_timeout` error is safe to
retry — `add` is an upsert keyed by slug.

## The card brief is the spec — and must trigger the agent

A card that's meant to be implemented should carry, in its `--body`:

1. **A header so the agent picks it up and drives it to merge** (fkanban does
   not auto-spawn agents and finished cards don't reach `done` on their own):

   > **Follow the fkanban-agent skill — drive this through to a MERGED PR.
   > A card is only `done` when its code is actually in the repo.**

2. **A work header telling the agent where to work** (there is no `repo` field
   on the schema, so it goes in the body):

   ```
   Repo: owner/name           # owner/name or absolute local path
   Base: main                 # base branch
   Branch: fkanban/<slug>     # optional; defaults to fkanban/<slug>
   ```

3. **The spec itself:** GOAL / CONTEXT / STEPS / VERIFY (exact commands that
   must pass) / DONE WHEN (PR merged into <base>) / OUT OF SCOPE.

Verify the facts you put in a brief against `origin/main` before filing —
local checkouts lag, so `git fetch` and read `origin/<base>:<file>` rather
than describing stale "current state".

## Grooming / triage

- "What's on the board" → `list --json`, then summarize by column.
- "What's stuck" → look for cards long in `review` (PR open, not merged) or
  `doing` (claimed, no PR). Surface them; don't silently re-drive — that's the
  fkanban-agent reconcile pass's job.
- Superseded / wrong card → `rm <slug>` (soft delete), or re-`add` to fix it.
- A card in `done` means its PR **merged** — that's the normal terminal state,
  not a kill.

## Guardrails

- **Never kill a LastDB node you didn't start** — the board lives on it. If
  `doctor` says the node is unreachable, surface it; don't restart things
  blindly. For destructive/migration testing, spin up an ephemeral node on
  another port rather than touching a shared daily-driver node.
- This skill only **manages** the board. To actually implement a card, hand off
  to the **fkanban-agent** skill (or tell the user it's ready to be worked).
