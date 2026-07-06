## LastDB Brain (fbrain) + Kanban (fkanban)

When a task should survive the current chat, use LastDB rather than chat memory.
Use the Brain (`fbrain`) for long-lived context: decisions, rationale,
preferences, references, and other "why" records. Use the Kanban (`fkanban`)
for live work state: one unit of work per card, moved through the board as
reality changes. Start work by checking `fkanban list`; track status on the
board, keep rationale in the Brain.

Prefer the MCP tools (`fbrain_*`, `fkanban_*`) when the servers are connected;
the CLI below is the fallback and uses the SAME verbs.

### Transport: the unix socket, NOT TCP — a `:9001` failure is NOT an outage

The LastDB node serves the brain and board over the unix socket
`~/.folddb/data/folddb.sock`. The legacy TCP port `http://127.0.0.1:9001` is
retired — "connection refused" / `node not reachable at http://127.0.0.1:9001`
does NOT mean the node is down.

- Data-plane works over the socket: `fbrain get/put/list/search/ask` and
  `fkanban list/add/move` round-trip fine even when `:9001` is refused.
- A few control-plane verbs are still TCP-only and print the `:9001` error by
  design: `fbrain doctor`, `fkanban doctor`, `fkanban init`. Do not run these as
  routine health checks, and do not treat their `:9001` error as a dead node.
- Never start/restart/kill a folddb/lastdb node to "fix" a `:9001` error — the
  primary node is already running on the socket; restarting it is harmful.
- Health check (socket-safe): `fkanban list` succeeding ⇒ node is up.

### fbrain CLI — read

- `fbrain ask "<question>"` — best search (hybrid BM25+vector). Use this first.
- `fbrain get <slug>` — fetch one record by slug. There is NO `fbrain show`.
- `fbrain list --type <t> --limit 10` — newest-first listing. Avoid bare
  `fbrain list` for health checks; prefer a targeted `get` or `fkanban list`.
- Types: design task concept preference reference agent project spike sop decision.

### fbrain CLI — write

- `fbrain put` reads the record from **stdin** with YAML frontmatter
  (`type:`, `slug:`, `title:`, then body). Update in place by reusing the slug;
  search for an existing record before creating a new one.
- `fbrain append <slug> --type <t>` — grow a big record's body (also stdin);
  never get→edit→put a large record (get windows at ~40K chars, a re-put
  truncates what you didn't see).
- Do NOT create `type: decision` records — that path is broken; append
  decisions to the `decisions-log` reference record instead.

### fkanban CLI

- `fkanban list` / `fkanban list --wide` / `fkanban search "<text>"` /
  `fkanban show <slug>`.
- `fkanban list --full-body --json` is valid for complete board/card bodies.
  `fkanban search` has no `--full-body` / `--full_body` CLI flag; use
  `fkanban search "<text>" --json` plus `fkanban show <slug> --json`, or MCP
  `fkanban_search` with `full_body: true`.
- `fkanban add <slug> --title "..." --column todo --body "..."` — NOTE:
  `--body` REPLACES the whole body. To edit an existing card,
  `fkanban show <slug>` first, concatenate, then re-add with the full new body.
- Only `list`, `search`, and `add` take `--board`; `show`, `move`, `rm`,
  `rank`, `dep`, and `tag` use the default board implicitly and reject it.
- Every new card needs `--north-star <slug>` or an `## END STATE` section in
  the body, and if it names a repo, the `Repo:` line must be a bare
  `owner/name` token alone on its line (no comments or prose after it).
- `fkanban move <slug> <column>` — blocked cards (unfinished deps) refuse
  doing/review/done without `--force`.

### Errors

`service_timeout`, "node did not respond within Nms", and "too many concurrent
reads" mean the node is BUSY, not down — retry the read; only retry writes that
are idempotent slug upserts. Do not restart anything.
