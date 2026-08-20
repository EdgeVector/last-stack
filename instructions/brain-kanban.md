## LastDB Brain (brain) + Kanban (kanban)

When a task should survive the current chat, use LastDB rather than chat memory.
Use the Brain (`brain`) for long-lived context: decisions, rationale,
preferences, references, and other "why" records. Use the Kanban (`kanban`)
for live work state: one unit of work per card, moved through the board as
reality changes. Start work by checking `kanban list`; track status on the
board, keep rationale in the Brain.

Prefer the MCP tools (`brain_*`, `kanban_*`) when the servers are connected;
the CLI below is the fallback and uses the SAME verbs.

### RUN / DEV / STATE / BOARD (won't-undo — 2026-07-23)

**Product code only in DEV worktrees.** Shared install trees are RUN/STATE, not
git homes. Full map: `instructions/run-dev-state-board.md` and brain
`concepts-edgevector-run-dev-state-board`.

| | |
|--|--|
| **RUN** | host-track current + `~/.local/bin` + daemons — use, don't commit |
| **DEV** | portal `./bin/wt start` → `~/.fkanban/worktrees/…` — **only** edit/commit path |
| **STATE** | `~/.lastdb`, `~/.local/state/last-stack/*`, `~/.routines/*` — data/logs/proofs |
| **BOARD** | brain + fkanban over the socket |

`~/.last-stack` is a **compat root** (mostly symlinks into
`~/.local/state/last-stack`). Never develop there. Sandbox allowlists must
include **realpaths** under `~/.local/state/last-stack`, not only `~/.last-stack`.

### Host-track CLI hygiene

For long-running agent work, prefer installed global CLIs over binaries from a
random WIP checkout. Source `last-stack-shell-prelude` or otherwise ensure
`~/.local/bin` is ahead of ad-hoc repo paths; host-track-managed installs live
there. When `brain`, `kanban`, `situations`, `lastgit`, or another shared CLI
misbehaves, first run `host-track status` when available and `<cmd> which` (for
example `lastgit which`) before blaming LastDB, changing PATH by hand, or
running a checkout-local binary.

### New repository venue default: LastGit

Create new repositories in LastGit first, with `lastdb:///<slug>` as the
canonical remote. Commit `.last-stack/pr-venue` with `lastgit` on its first
line, add a required `.lastgit/ci.sh` gate, and configure the repo's supervised
CI watcher/completer with a concurrency limit of one. Do not create a Forgejo
or GitHub source repository first unless the repository is explicitly public
or a mirror is part of the request.

This is a creation-time default, not an instruction to silently migrate
existing repositories. Existing repos keep their configured GitHub, Forgejo,
or LastGit venue until an explicit migration changes it.

### Transport: the unix socket, NOT TCP — a `:9001` failure is NOT an outage

The LastDB node serves the brain and board over the unix socket
`~/.lastdb/data/folddb.sock`. After the 2026-07-12 Mini cutover,
`~/.folddb` is only a compatibility path and may be a symlink to `~/.lastdb`;
do not hard-code it as the primary. The legacy TCP port
`http://127.0.0.1:9001` is retired — "connection refused" /
`node not reachable at http://127.0.0.1:9001` does NOT mean the node is down.

- Data-plane works over the socket: `brain get/put/list/search/ask` and
  `kanban list/add/move` round-trip fine even when `:9001` is refused.
- Health check (socket-safe): `lastdb status` or `kanban ping`. Either
  succeeding ⇒ the node is up.
- Do not run `brain doctor`, `kanban doctor`, or `kanban init` as a health check.
- Doctor/init may still print a retired-TCP `:9001` refused error (leftover
  control-plane residue, not a live listener). That is not an outage.
- Never start/restart/kill a LastDB node because doctor printed `:9001`.
  The primary node is already running on the socket; restarting it is harmful.

### LastDB Mini binary path hygiene

Prefer the stable user-local Mini path over Homebrew or ad hoc canary dirs:
`~/.lastdb/current/{lastdb,lastdbd}` is the canonical primary binary tree, and
`~/.local/bin/{lastdb,lastdbd,folddb}` should symlink through that `current`
directory. Use `~/.last-stack/bin/last-stack-lastdb-current set` after a
successful safe upgrade or deliberate canary promotion, then
`~/.last-stack/bin/last-stack-lastdb-current check --verbose` to verify the
shell-visible CLI and daemon binary agree. The helper never restarts/kills
`lastdbd`; LaunchAgent reload/kickstart remains a separate supervised action.

### brain CLI — read

- `brain ask "<question>"` — best search (hybrid BM25+vector). Use this first.
- `brain get <slug>` — fetch one record by slug. There is NO `brain show`.
- `brain search "<q>"` — discovery sample (optional `--type`, `--limit`). Prefer
  search/ask over list for finding records.
- Do **not** use `brain list` as a census or membership instrument — list (and
  search) under-report; never rank completeness from a page. Health checks:
  targeted `brain get` or `kanban list` / `kanban ping`, never a typed list
  sweep. Where a listing is unavoidable, treat any envelope as a SAMPLE page
  (`truncated` / incomplete) and point-get seeds instead of trusting membership.
- Types: design task concept preference reference agent project spike sop decision.

### brain CLI — write

- `brain put` reads the record from **stdin** with YAML frontmatter
  (`type:`, `slug:`, `title:`, then body). Update in place by reusing the slug;
  search for an existing record before creating a new one.
- `brain append <slug> --type <t>` — grow a big record's body (also stdin);
  never get→edit→put a large record (get windows at ~40K chars, a re-put
  truncates what you didn't see).
- Write a settled call as its own `type: decision` record (`brain put` with
  `type: decision` and real `program` / `gate_slug` / `decided_by` /
  `decided_on` columns). Do NOT append to the archived `decisions-log`
  monolith. That path retired 2026-07-06
  (`decision-2026-07-06-decisions-log-migrated-to-decision-type`).

### ALWAYS file papercuts — the default is FILE, not judge

A papercut is any friction you hit doing the real work: a tool that misbehaves,
a confusing or truncated error, a check that reports about something it cannot
observe, a stale convention, a manual workaround, a doc or comment that
contradicts what executes. File one whenever you hit one, unprompted.

```bash
brain papercut file <slug> --component <c> --symptom "<one line>" \
  --title "<what is wrong>" --severity p0|p1|p2|p3 --body "<symptom, exact
  output, repro, date, repo, suggested fix>"
brain papercut close <slug> --status fixed|verified --evidence "<what you
  checked>" --fixed-by "<repo> #<PR>" --verified-by "<live check you ran>"
```

- **Do not judge it first.** The gate is "is this a distinct claim someone would
  want to find?", not "is it big enough" or "is it novel". A session that hits
  friction and files nothing needs an explicit reason; "small", "probably
  already known", and "that one was my own mistake" are not reasons.
- **Brain ONLY — never file a papercut kanban card.** The `papercut-reconciler`
  routine is the sole papercut→card path so it can dedupe and cluster.
- **Search first (`brain ask`), and read a hit as a REMEDY, not just as
  precedent** — an existing record may already prescribe the fix or name the
  systems checked for exposure. Appending measured evidence to an open record
  beats filing its near-duplicate.
- **A mention is not a filing.** Prose in a checkpoint, commit message, PR
  description, or run summary reaches no routine and produces no card. No slug,
  not filed.
- **Burying a finding in a record you then CLOSE is worse than not filing it.**
  Unfiled is absent, and absence is honest — someone rediscovers it. An aside
  inside a closed record *reads as recorded* while being invisible to every
  open-backlog reader, every open-work count, and every stale-record sweep.
  **Before closing any record, ask whether its body claims something about
  anything OTHER than what you are closing; if so, that part needs its own slug
  first.**
- Cheap same-session fixes are encouraged: file it, fix it, close it with
  evidence. `--status verified` requires a live check you actually ran — a merge
  reference is a fact about a repo, not about anything running.

### Routines end with close-out (Tom, 2026-08-17)

Every scheduled routine's LAST work step is the **close-out skill**
(`$LAST_STACK_ROOT/skills/close-out/SKILL.md`): write the brain closeout
report of what the run did, and file brain papercuts for friction hit.
Only then emit the heartbeat + `ROUTINE_RESULT` trailer (contract §1).
Skip close-out steps that do not apply (PR/card on a read-only pass); never
skip the two brain writes on a substantive run.

### North Star → milestone → cards (no bulk scaffold)

Operational hierarchy (2026-07-21+):

`North Star → last-stack-north-star-driver → milestone → last-stack-milestone-driver → Kind: pr cards → pickup`

**Won't-undo:** when Tom says "make this a North Star" / "start driving this,"
do **not** bulk-`kanban add` milestones and empty PR shells. Write the Brain
NS + `MILESTONE_REQUEST`, then targeted `routines run last-stack-north-star-driver`
and `last-stack-milestone-driver`. Milestone default driver is
`last-stack-milestone-driver`; never set `program-driver` (superseded).
Kind:pr cards in default/todo need a substantive brief (prefer `## GOAL` +
`## END STATE`); empty shells are rejected by fkanban and must not be parked as
`needs_human`. Before claiming "runnable," run `kanban pickup explain <slug>`.

### kanban CLI

- `kanban list --column todo --json` / `kanban search "<text>"` /
  `kanban show <slug>`.
- Do not use `kanban list --full-body --json` in routines — it hydrates every
  card body on top of the partition read. Use capped or column previews plus
  `kanban show <slug> --json` for the one selected card. The flag is valid and
  exists for the rare case where you genuinely need every body at once.
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

### Who is burning the node? — `lastdb ops` (request telemetry)

When the node is slow, shedding, or timing out, **name the offender** before
guessing. Mini records every completed data-plane op in-process (resets on
daemon restart):

```bash
lastdb status    # host vitals + short request-ops summary
lastdb ops       # full worst-offender tables (client, kind, schema, ms, count)
```

Or read `status.request_ops` on `GET /api/status` over the socket. Rankings:
`top_by_total_ms` (who eats wall time), `top_by_count` (chatty callers),
`top_by_duration` (slowest singles in the ring). Clients self-identify with
header `X-LastDB-Client: <name>` (`brain`, `kanban`, `lastgit`, …) — not a
security boundary; missing → `unknown`. Full playbook:
`brain get sop-lastdb-request-ops-telemetry --type sop`.
