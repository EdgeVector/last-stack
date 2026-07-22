# Portal — not a product checkout

This directory is an **EdgeVector portal**, not a clone of the product repo.

- **No product source lives here.** It cannot go “stale” as a working tree.
- **All work happens in a git worktree** created via `bin/wt`.
- The gate-of-record remote is declared under `.portal/` (usually LastGit).

## Start work (agents)

```bash
cd "$(dirname "$0")"   # this portal
./bin/wt start kanban/<card-slug>
# → prints a path under ~/.fkanban/worktrees/
# → ONLY edit files under that path
```

Refresh cache only:

```bash
./bin/wt fetch
./bin/wt list
```

## Do not

- Run `git commit` / `git push` from this directory (there is no product tree).
- Treat this path as `Repo:` work root for kanban-agent — resolve via `wt start`.
- Copy product sources back into the portal.

## Layout

| Path | Role |
|------|------|
| `.portal/slug` | Short name (e.g. `fkanban`) |
| `.portal/venue` | `lastgit` \| `forgejo` \| `github` |
| `.portal/remote` | Gate URL (`lastdb:///fkanban`, …) |
| `.portal/cache` | Bare object store path |
| `bin/wt` | Wrapper → `last-stack-portal-wt` |

See brain: `preference-worktrees-only-shared-checkouts`,
`sop-edgevector-portals-lastgit`.
