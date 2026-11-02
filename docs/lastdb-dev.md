# lastdb-dev — a dev node on a fresh empty home

`lastdb-dev` is the inner loop for LastDB development. It builds `lastdbd`
from a worktree, boots it on a persistent EMPTY home, and points the `brain`,
`kanban`, and `lastdb` CLIs at that node. The primary node keeps its data and
its socket. Nothing in this tool reads or writes the primary home.

Script: `bin/last-stack-lastdb-dev`. PATH name: `lastdb-dev`.

## Never a copy of the primary

Tom, 2026-10-12: "I don't want anything to run copies of my database, it will
kill my disk space and run super slow, always use synthetic data."

This tool does not copy `~/.lastdb`. It does not boot a node on a copy of it.
The dev home starts empty and the node makes its own identity. Load synthetic
data into the node yourself (`kanban init`, `brain init`, `brain put`, and so
on). Brain: `decision-2026-10-12-never-run-copies-of-primary-database-use-synthetic-data`.

An older version of this tool made a copy-on-write clone of the primary home.
That mode is gone. A copy fills the disk because the primary keeps rewriting
blocks that the copy still holds.

## Why

A developer who edits one file wants to see the result in seconds.
`lastdb-dev` keeps the empty home between restarts. One edit costs one
incremental build plus one boot. `refresh` (or `up --fresh`) starts over with a
new empty home.

## The loop

```bash
cd ~/code/edgevector/fold && ./bin/wt start kanban/<card-slug>   # a fold worktree
cd ~/.fkanban/worktrees/fold-kanban-<card-slug>

lastdb-dev up                 # build lastdbd (debug), create an empty home once, boot, wait for identity
eval "$(lastdb-dev env)"      # this shell's brain / kanban / lastdb now hit the dev node
kanban ping
kanban init --node-socket-path "$FOLDDB_SOCKET_PATH" --name dev   # load synthetic data into the dev node

# edit code ...
lastdb-dev restart            # rebuild from the same worktree, boot again on the same home
lastdb-dev logs -f
lastdb-dev status
lastdb-dev stop
```

`lastdb-dev up` finds the worktree from `$PWD`, from `LASTDB_DEV_WORKTREE`,
or from the last build. Without a worktree it uses the staged binary from the
last build, then the canary build of current main.

## Commands

| Command | Effect |
|---|---|
| `up [--worktree DIR \| --bin PATH \| --canary \| --staged] [--release] [--fresh] [--no-wait] [--env K=V]` | Select a binary, create an empty home if there is none (`--fresh` always starts over), boot, wait for identity. |
| `build [--worktree DIR] [--release]` | Build `lastdbd` and stage it out of `target/`. |
| `restart [...]` | `stop` then `up`. |
| `refresh` | Stop, start over with a new empty home, restart if the node was up. |
| `status [--json]` | Pid, memory, identity, schema count, binary, creation time. |
| `logs [-f] [-n N]` | The node's boot log. |
| `stop` | Signal the node this tool started. |
| `env` | Print `export` lines. Use `eval "$(lastdb-dev env)"`. |
| `run -- <cmd...>` | Run one command with that env. |
| `shell` | Open a subshell with that env. |
| `reset` | Stop and delete the dev home and staged binaries. |

## What the node inherits

The node boots with the primary's `LASTDB_*` environment, read from the
primary's LaunchAgent plist through the same helper `lastdb-safe-upgrade`
uses (`skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh`), so the dev node
runs with the same limits and tuning as the primary.

The node does not inherit `LASTDB_HOME` or any Sentry DSN.
The empty home has no `cloud_sync.json` and no primary credentials, so the dev
node never publishes a backup as the primary.

Debug builds get `RUST_MIN_STACK=67108864` (64 MiB) unless the caller sets
`RUST_MIN_STACK` or `LASTDB_DEV_DEBUG_STACK_BYTES`. An unoptimized `lastdbd`
can overflow its UDS worker stack. Release builds get no such default.

Pass extra flags to the node with `--env K=V`. Example:

```bash
lastdb-dev restart --env LASTDB_RESIDENT_MODE=off
```

The env the node booted with is in `~/.local/state/lastdb-dev/boot.env`.

## Client env

`lastdb-dev env` exports these variables:

- `LASTDB_HOME` → the dev home (the `lastdb` CLI and the SDK)
- `FBRAIN_FOLDDB_SOCKET`, `FOLDDB_SOCKET_PATH`, `LASTDB_SOCKET_PATH`,
  `LAST_STACK_LASTDB_SOCKET` → the dev socket
- `BRAIN_CONFIG`, `KANBAN_CONFIG` → copies of `~/.brain/config.json` and
  `~/.fkanban/config.json` with `nodeSocketPath` set to the dev socket
- `FBRAIN_CAPABILITY_DIR`, `FBRAIN_CACHE_DIR` → dev-only copies, so a grant
  from the dev node never overwrites the primary's cached grant
- `LASTDB_DEV_ACTIVE=1`

## Safety

- The dev home is compared by realpath with the primary home before every
  create, boot, and delete. A dev home that is the primary, sits inside the
  primary, or is a symlink is refused.
- The node always starts with `--data-dir <dev home>`.
- `stop` and `reset` signal only the pid in the tool's pidfile, and only when
  that process's argv carries `--data-dir <dev home>`.
- A previous dev home is removed in the background after `refresh`. The delete
  does not block the new boot.

## Paths

| Path | Meaning |
|---|---|
| `~/.lastdb-dev` | The dev home. Override with `LASTDB_DEV_HOME`. Keep it short: the socket path must fit 103 bytes. |
| `~/.local/state/lastdb-dev/` | Pidfile, boot log, boot env, staged binaries, client configs. Override with `LASTDB_DEV_STATE`. |
| `~/.lastdb` | The primary. The tool reads only its path, to refuse a dev home that aliases it. Override with `LASTDB_DEV_PRIMARY_HOME`. |

## Costs to expect

| Step | Time |
|---|---|
| create the empty home | under 1 s |
| cold debug build of `lastdbd` (sccache warm) | 57 s (measured 2026-09-02) |
| incremental build after a `lastdb_node` edit | ~10 s (brain `lastdb-build-time-baseline-2026-08-06`) |
| incremental build after a `fold_db` edit | ~45 s (same record) |
| boot to identity on an empty home | under 1 s (measured 2026-10-12) |

A second node next to the primary needs memory. An empty node uses about 25 MiB.
The tool warns when less than 4 GiB is available (`LASTDB_DEV_MIN_MIB`). It does
not refuse.
