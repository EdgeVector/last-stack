# RUN / DEV / STATE / BOARD — where things live

**Won't-undo agent rule (Tom 2026-07-23):** stop writing product code into
shared install trees. Those paths are for *running* the fleet; they go stale
or are symlink mazes. **Code changes only in an isolated worktree** from a
portal (`./bin/wt start …`) or `git worktree` on the venue main.

Full durable copy: brain `concepts-edgevector-run-dev-state-board`.

## Four buckets

| Bucket | What it is | Paths (examples) | Agents may |
|--------|------------|------------------|------------|
| **RUN** | Installed CLIs + daemons | `~/.host-track/apps/*/current`, `~/.local/bin`, `lastdbd`, `routinesd` | **Use** binaries; never commit here |
| **DEV** | Source you ship | Portal → worktree under `~/.fkanban/worktrees/…` (or explicit card worktree) | **Only place to edit/commit/push** |
| **STATE** | Logs, proofs, DB, runtime data | `~/.lastdb`, `~/.local/state/last-stack/{runtime,artifacts}`, `~/.routines/{memory,runs}` | Append logs/proofs as tools allow; never "fix" by resetting primary DB |
| **BOARD** | Work tracking + knowledge | brain + fkanban over `~/.lastdb/data/folddb.sock` | `brain` / `kanban` / Situations as normal |

## Alias collapse (same thing, two names)

| Prefer | Also exists | Notes |
|--------|-------------|--------|
| `~/.lastdb` | `~/.folddb` → symlink | Socket + Mini home |
| `~/.fkanban` | `~/.kanban` → symlink | Board worktrees + CLI state |
| `~/.local/state/last-stack/…` | many `~/.last-stack/*` symlinks | **Managed install**: `logs`, `bin`, `skills`, `routines`, `proofs`, … point into state |

`~/.last-stack` is a **compat root**, not a product checkout. Do not
`git commit` there. Do not treat it as a feature branch.

## Codex / routine sandbox (realpath rule)

Harness allowlists must include **real paths**, not only pretty symlinks.

- Allowing `~/.last-stack` alone is **not** enough for writes that resolve to
  `~/.local/state/last-stack/…` (heartbeats, proofs, dogfood dirs).
- `routines` `codexWritableDirs()` must include `~/.local/state/last-stack`
  (and other real state homes). Heartbeat helper may fall back to
  `~/.routines/routine-heartbeats.log` if the primary log is unwritable.

**EPERM / Operation not permitted** after green work often means sandbox path
gap — not a dead LastDB node. Check Situations notices; do not restart primary.

## Hard don'ts

1. **No product commits** under `~/.last-stack`, `~/.host-track/…/current`, or a portal directory.
2. **No "heal install with reset-hard"** from a routine without Tom clearance.
3. **No third install tree** when something is sticky — use a worktree + CR.
4. **No equating sandbox EPERM with outage** — fix allowlist/realpath or use STATE paths already allowed.

## How to start work

```bash
cd ~/code/edgevector/<portal>   # e.g. routines, last-stack portal if any
./bin/wt start kanban/<card-slug>
# → print path under ~/.fkanban/worktrees/…
# ONLY edit that path; ship via lastgit cr / forge as venue says
```

CLI hygiene: prefer host-track / `~/.local/bin` tools (`brain`, `kanban`,
`lastgit`, `situations`) over random WIP checkouts. If a CLI misbehaves:
`host-track status` / `<cmd> which` first.
