---
name: kanban
version: 0.2.0
description: |
  Manage the kanban board — a kanban over LastDB. File, list, show, move,
  groom, and soft-delete cards via the kanban CLI. Use when the user wants to
  "file a kanban task/card", "add to the board", "what's on the board",
  "backlog", "list tasks", "move a card", "show card <slug>", or "groom the
  board". This is the board-CRUD counterpart to the kanban-agent skill (which
  drives one card to a merged PR); use kanban-agent — not this — to actually
  implement a card.
---

## NO REVIEW COLUMN (Tom 2026-07-16 — won't-undo)

There is **no `review` column**. Board columns are only:
`backlog → todo → doing → done`.

- Incomplete work: stay in `todo` or `doing`
- Complete work: `done` only with merge/END-STATE proof
- Intentional holds: `block_status=needs_human|deferred|design_first` + reason
  while the card stays in `todo` (or `backlog` if dep-blocked)

Never `kanban move <slug> review`. The live board rejects it. Do not invent
a review lane on custom boards either.


# kanban — board management

kanban is a kanban task board stored in **LastDB**: a thin CLI/MCP client of a
LastDB node. Cards move through columns; every change persists in the node.

- **Location / how to run:** clone `kanban` and run its `src/cli.ts` under
  **bun**. A global shim (`kanban`) can be symlinked onto your PATH so a bare
  `kanban <command>` resolves from anywhere; without it, run
  `bun run src/cli.ts <command>` from the repo directory. See the
  **kanban-setup** skill for install.
- **⚠️ PATH gotcha (sandboxed shells):** some agent harnesses run shell commands
  **sandboxed** with a stripped `$PATH`, so a bare `kanban …` fails with
  `command not found: kanban`, and even after you add the shim's directory the
  shim's internal `exec bun` can then fail with `command not found: bun`. Both
  the shim dir and the bun dir must be on PATH. The robust fix is to prepend a
  complete PATH that includes both at the start of every kanban Bash call (PATH
  does not persist between calls), or invoke the CLI directly:
  `cd <kanban-repo> && PATH="$HOME/.bun/bin:$PATH" bun run src/cli.ts <command>`.
  Confirm the shim with `command -v kanban` and a narrow read.
- **Where the data lives:** the board records live on **your LastDB node**. The
  CLI talks to the node over its configured transport. Local daily-driver nodes
  may be **Unix-socket only** with HTTP intentionally shut down; use a
  socket-backed narrow read as the routine health check. The node URL is
  **configurable** — `init` defaults to a node running locally on your machine;
  point it elsewhere with `--node-url` / the config file (`~/.kanban/config.json`).
- **Columns:** `backlog → todo → doing → done`.

Before doing anything non-trivial, sanity-check the setup with a socket-backed
narrow read:

```bash
kanban list --column todo --json
```

## Commands

(With the shim on PATH these run from anywhere; otherwise replace `kanban`
with `bun run src/cli.ts` and run from the kanban repo directory.)

```bash
kanban list --column todo --json   # narrow column preview
kanban list --board <b> --column todo --json  # board-scoped column preview
# Avoid kanban list --full-body in routines; use show for selected cards.
kanban search "<text>" --json      # text search; no --full-body flag
kanban show <slug> --json          # one card in detail
kanban add <slug> [flags]          # create OR update a card
kanban move <slug> <column> [--position N]
kanban rm <slug>                   # soft-delete
kanban board create <slug> --title ... --columns a,b,c
kanban board list
```

`list` flags: `--board --column --tag --assignee --wide --field --limit N
--all --json --full-body --full_body`.

`search` flags: `--board --column --field --limit N --all --json`.
**`kanban search` has no full-body option** — there is no `--full-body`
(or `--full_body`); passing it fails with `Unknown option '--full-body'`.
If you need full bodies from search results, use `kanban search <query> --json`
and then `kanban show <slug> --json` for a selected card, or pass
`full_body: true` to the MCP `kanban_search` tool (the underscore form is the
*MCP tool argument*, never a CLI flag).

Search is useful, but it may be temporarily unavailable while a board backend is
blocking full-schema scans. In routines, prefer scoped reads first:
`kanban list --column todo --json`, `kanban list --column doing --json`, and
`kanban show <known-slug> --json`. If `kanban search` returns
`full_schema_scan_not_allowed`, do not treat that as board outage and do not run
doctor/restart paths; fall back to column previews plus slug-pattern checks, then
file/update the best deduped card you can prove from those bounded reads.

`show`, `move`, `rm`, `rank`, `dep`, and `tag` operate on the default board
implicitly and reject `--board`. Only add `--board` to commands whose help lists
one, such as `list`, `search`, and `add`.

`add` flags: `--title --board --column --assignee --tags --body`. Re-running
`add` with the same slug **updates** the card (upsert), so it's safe to edit a
card by re-adding it. Default column for a fresh card is `backlog`; for a task
you want worked soon, pass `--column todo`.

Every live card must carry body ownership headers. Even tracker, validation, or
meta cards that are not normal pickup work need explicit `Repo:` and `Base:`
lines so watch/groom/pickup routines can classify them consistently. For non-PR
cards, set `Kind: tracker|validation|meta`, include an explicit `DONE-WHEN:`
predicate, and pass the matching `--kind` value when the CLI supports it.
Legacy registry cards are only for registry-record maintenance.

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
kanban add my-slug \
  --title "Short imperative title" \
  --column todo --tags "app,cli,perf" < /tmp/card-body.md
# 3. verify it landed
kanban show my-slug | head -8
```

Always confirm with `show <slug>` after writing — the `add` is only successful
if the card actually reads back.

`add` is two keyed point reads + one write (~0.2s) and every request carries a
30s deadline (`FKANBAN_HTTP_TIMEOUT_MS` to override), so commands fail fast
instead of hanging on a busy node. `service_timeout`, "node did not respond
within 30000ms", or "too many concurrent reads" means load/backpressure, not a
dead node. Do not run doctor/restart loops for that class of error; retry the
idempotent slug upsert after a short backoff or raise `FKANBAN_HTTP_TIMEOUT_MS`
for one bounded command, then verify with `show`.

## The card brief is the spec — and must trigger the agent

A card that's meant to be implemented should carry, in its `--body`:

1. **A header so the agent picks it up and drives it to merge** (kanban does
   not auto-spawn agents and finished cards don't reach `done` on their own):

   > **Follow the kanban-agent skill — drive this through to a MERGED PR.
   > A card is only `done` when its code is actually in the repo.**

2. **A work/ownership header telling the agent where to work or which repo owns
   the tracker/registry context**. The CLI stores structured fields too, but
   routines still parse body headers directly, so the body header is mandatory:

   ```
   Repo: owner/name
   Base: main
   Branch: kanban/<slug>
   Kind: pr
   ```

   Field meanings — `Repo`: `owner/name` (e.g. `EdgeVector/fold`) or an
   absolute local Git checkout path; `Base`: base branch; `Branch`: optional,
   defaults to `kanban/<slug>`; `Kind`: `pr | tracker | validation | meta`
   for new cards (`registry` only for legacy registry-record cards).

   > **⚠️ Keep each header value a single clean token on its own line.**
   > `kanban-pickup` resolves `Repo:` **literally** — it does NOT strip
   > trailing `# comments`, parentheticals, or prose. A dirty value
   > (`Repo: EdgeVector/fold  # defaulted`, `Repo: fold (also touches exemem-infra)`,
   > `Repo: last-stack`, `Repo: none`, or `Base:`/`Branch:` mashed onto the
   > `Repo:` line) is treated as **unresolvable** and the card is force-blocked
   > into `review`/`needs_human` — the #1 cause of stranded cards. So:
   > - Use the full `owner/name` (`EdgeVector/last-stack`, not bare `last-stack`).
   > - No trailing `#` comment and no `(parenthetical)` on the value line.
   > - Put `Base:`, `Branch:`, `Kind:` each on their **own** line.
   > - Multi-repo notes ("also touches X", "sibling repos …") go in the spec
   >   body prose, never on the `Repo:` line. Pick the ONE primary repo.

3. **The spec itself:** GOAL / CONTEXT / STEPS / VERIFY (exact commands that
   must pass) / DONE WHEN (PR merged into <base>) / OUT OF SCOPE.

   For non-PR cards, replace the PR merge terminal condition with one
   single-line machine-checkable predicate:

   ```
   Kind: tracker|validation|meta
   DONE-WHEN: brain <slug> exists
   DONE-WHEN: brain <slug> updated-after <YYYY-MM-DD>
   DONE-WHEN: routine <name> heartbeat matches /<regex>/ after <YYYY-MM-DD>
   DONE-WHEN: date >= <YYYY-MM-DD>
   DONE-WHEN: file <path> matches /<regex>/
   ```

   `DONE-WHEN` predicates are read-only and deterministic. The reconciler and
   groomer may move a non-PR card to `done` only when the predicate is
   satisfied. Pending predicates stay quiet. Malformed or missing predicates on
   non-PR cards become a visible card-authoring issue. `Kind: pr` cards ignore
   `DONE-WHEN` for closure and still require a merged PR.

Verify the facts you put in a brief against `origin/main` before filing —
local checkouts lag, so `git fetch` and read `origin/<base>:<file>` rather
than describing stale "current state".

## Grooming / triage

- "What's on the board" → `list --json`, then summarize by column.
- "What's stuck" → look for cards long in `review` (PR open, not merged) or
  `doing` (claimed, no PR). Surface them; don't silently re-drive — that's the
  kanban-agent reconcile pass's job.
- Superseded / wrong card → `rm <slug>` (soft delete), or re-`add` to fix it.
- A PR card in `done` means its PR **merged** — that's the normal terminal
  state, not a kill. A non-PR card in `done` means its `DONE-WHEN` predicate was
  satisfied and cited by watch/groom.

## Guardrails

- **Never kill a LastDB node you didn't start** — the board lives on it. If
  `doctor` says the node is unreachable, surface it; don't restart things
  blindly. Do not treat a disabled HTTP health endpoint as failure when
  `doctor` succeeds over the Unix socket. For destructive/migration testing,
  spin up an ephemeral node on another port rather than touching a shared
  daily-driver node.
- If a board/brain command returns `HTTP 423`, `keyring_undecryptable`, or "the
  node is up but cannot decrypt your data", the node is alive but locked. Stop
  and surface that exact state; do not run restart/doctor loops or attempt
  keychain/passphrase repair unattended.
- If a board/brain command returns `service_timeout`, "node did not respond
  within 30000ms", or "too many concurrent reads", the shared node is busy.
  Prefer targeted reads (`show`, typed `brain get`) over broad lists, retry
  only idempotent upserts by slug, and never restart the node to clear load.
- This skill only **manages** the board. To actually implement a card, hand off
  to the **kanban-agent** skill (or tell the user it's ready to be worked).
