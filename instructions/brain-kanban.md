## LastDB Brain (brain) + Kanban (kanban)

When a task should survive the current chat, use LastDB rather than chat memory.
Use the Brain (`brain`) for long-lived context: decisions, rationale,
preferences, references, and other "why" records. Use the Kanban (`kanban`)
for live work state: one unit of work per card, moved through the board as
reality changes. Start work by checking `kanban list`; track status on the
board, keep rationale in the Brain.

Prefer the MCP tools (`brain_*`, `kanban_*`) when the servers are connected;
the CLI below is the fallback and uses the SAME verbs.

### Transport: the unix socket, NOT TCP — a `:9001` failure is NOT an outage

The LastDB node serves the brain and board over the unix socket
`~/.lastdb/data/folddb.sock`. After the 2026-07-12 Mini cutover,
`~/.folddb` is only a compatibility path and may be a symlink to `~/.lastdb`;
do not hard-code it as the primary. The legacy TCP port
`http://127.0.0.1:9001` is retired — "connection refused" /
`node not reachable at http://127.0.0.1:9001` does NOT mean the node is down.

- Data-plane works over the socket: `brain get/put/list/search/ask` and
  `kanban list/add/move` round-trip fine even when `:9001` is refused.
- A few control-plane verbs are still TCP-only and print the `:9001` error by
  design: `brain doctor`, `kanban doctor`, `kanban init`. Do not run these as
  routine health checks, and do not treat their `:9001` error as a dead node.
- Never start/restart/kill a folddb/lastdb node to "fix" a `:9001` error — the
  primary node is already running on the socket; restarting it is harmful.
- Health check (socket-safe): `kanban list` succeeding ⇒ node is up.

### brain CLI — read

- `brain ask "<question>"` — best search (hybrid BM25+vector). Use this first.
- `brain get <slug>` — fetch one record by slug. There is NO `brain show`.
- `brain list --type <t> --limit 10` — newest-first listing. Avoid bare
  `brain list` for health checks; prefer a targeted `get` or `kanban list`.
- Types: design task concept preference reference agent project spike sop decision.

### brain CLI — write

- `brain put` reads the record from **stdin** with YAML frontmatter
  (`type:`, `slug:`, `title:`, then body). Update in place by reusing the slug;
  search for an existing record before creating a new one.
- `brain append <slug> --type <t>` — grow a big record's body (also stdin);
  never get→edit→put a large record (get windows at ~40K chars, a re-put
  truncates what you didn't see).
- Do NOT create `type: decision` records — that path is broken; append
  decisions to the `decisions-log` reference record instead.

### kanban CLI

- `kanban list --column todo --json` / `kanban search "<text>"` /
  `kanban show <slug>`.
- `kanban list --full-body --json` is valid for complete board/card bodies.
  Do not use broad/full-body list reads in routines; use capped or column
  previews plus `kanban show <slug> --json` for the one selected card.
  `kanban search` has no `--full-body` / `--full_body` CLI flag; use
  `kanban search "<text>" --json` plus `kanban show <slug> --json`, or MCP
  `kanban_search` with `full_body: true`.
- `kanban add <slug> --title "..." --column todo --body "..."` — NOTE:
  `--body` REPLACES the whole body. To edit an existing card,
  `kanban show <slug>` first, concatenate, then re-add with the full new body.
- Only `list`, `search`, and `add` take `--board`; `show`, `move`, `rm`,
  `rank`, `dep`, and `tag` use the default board implicitly and reject it.
- Every new card needs `--north-star <slug>` or an `## END STATE` section in
  the body, and if it names a repo, the `Repo:` line must be a bare
  `owner/name` token alone on its line (no comments or prose after it).
- `kanban move <slug> <column>` — blocked cards (unfinished deps) refuse
  doing/review/done without `--force`.

### Git commits from isolated worktrees

Never run `git add -A` or `git add .` in a shared checkout; sibling agents may
have unrelated edits there. In a dedicated isolated worktree for your card, the
shared-checkout prohibition does not apply: before committing, always stage the
whole worktree with `git add -A` or commit tracked edits with `git commit -a`
so staged deletions and editor/Edit-tool changes both land in the commit.

Before pushing, require the isolated worktree status to be empty, for example
`git -C "$worktree" status --short`, or inspect `git show --stat HEAD`. If the
commit stat is only deletions but you also edited files, you probably dropped
unstaged edits. When local checks passed against the working tree but CI fails
from the committed tree with missing modules, dangling references, or
deleted-file imports, treat that as an unstaged-edit drop: stage the edits and
amend or make a real fix commit. Do not use an empty commit just to retrigger
CI.

### Errors

`service_timeout`, "node did not respond within Nms", and "too many concurrent
reads" mean the node is BUSY, not down — retry the read; only retry writes that
are idempotent slug upserts. Do not restart anything.
