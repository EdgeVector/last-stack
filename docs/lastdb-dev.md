# lastdb-dev — a dev node on a copy of the real home

`lastdb-dev` is the inner loop for LastDB development. It builds `lastdbd`
from a fold worktree, boots it on a persistent copy-on-write clone of the
primary home, and points the `brain`, `kanban`, and `lastdb` CLIs at that
node. The primary node keeps its data and its socket. Nothing in this tool
writes to the primary home.

Script: `bin/last-stack-lastdb-dev`. PATH name: `lastdb-dev`.

## Why

Before this tool, the only path to run a candidate binary on real data was
the smoke gate. That gate gives a verdict and tears everything down. It pays
a full clone and a full delete on every run. Measured on the primary on
2026-08-27, that was 283 s for the clone and 445 s for the delete. A developer
who edits one file and wants to see the result cannot pay 12 minutes per try.

`lastdb-dev` keeps the clone between restarts. One edit costs one incremental
build plus one boot. `refresh` re-clones when you want newer primary data.

## The loop

```bash
cd ~/code/edgevector/fold && ./bin/wt start kanban/<card-slug>   # a fold worktree
cd ~/.fkanban/worktrees/fold-kanban-<card-slug>

lastdb-dev up                 # build lastdbd (debug), clone ~/.lastdb once, boot, wait for identity
eval "$(lastdb-dev env)"      # this shell's brain / kanban / lastdb now hit the dev node
kanban ping
brain get concepts-lastdb-canonical-model

# edit code ...
lastdb-dev restart            # rebuild from the same worktree, boot again on the same clone
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
| `up [--worktree DIR \| --bin PATH \| --canary \| --staged] [--release] [--fresh] [--no-wait] [--env K=V]` | Select a binary, clone if there is no clone, boot, wait for identity and schemas. |
| `build [--worktree DIR] [--release]` | Build `lastdbd` and stage it out of `target/`. |
| `restart [...]` | `stop` then `up`. |
| `refresh` | Stop, re-clone from the primary, restart if the node was up. |
| `status [--json]` | Pid, memory, identity, schema count, binary, clone time. |
| `logs [-f] [-n N]` | The node's boot log. |
| `stop` | Signal the node this tool started. |
| `env` | Print `export` lines. Use `eval "$(lastdb-dev env)"`. |
| `run -- <cmd...>` | Run one command with that env. |
| `shell` | Open a subshell with that env. |
| `reset` | Stop and delete the dev home and staged binaries. |

## What the node inherits

The node boots with the primary's `LASTDB_*` environment, read from the
primary's LaunchAgent plist through the same helper `lastdb-safe-upgrade`
uses (`skills/lastdb-safe-upgrade/scripts/live-lastdb-env.sh`). This matters.
`LASTDB_ATOM_KEY_ENCODING=partition_prefix` decides whether the node can
address the primary's atom bodies. A node without it reports data as missing.
See brain `sop-lastdb-local-smoke-test`, rule HR-N1.

The node does not inherit `LASTDB_HOME`, `FOLDDB_HOME`, or any Sentry DSN.
The clone has no `cloud_sync.json`, so the dev node never publishes a backup
with the primary's credentials.

Debug builds get `RUST_MIN_STACK=67108864` (64 MiB) unless the caller sets
`RUST_MIN_STACK` or `LASTDB_DEV_DEBUG_STACK_BYTES`. An unoptimized `lastdbd`
overflows its UDS worker stack on the real home even with the pool's 8 MiB
floor. It aborts on the first request with `has overflowed its stack`. The
pool takes the larger of its floor and `RUST_MIN_STACK`, so this default makes
a debug build serve the real home. Release builds get no such default. See
brain `papercut-lastdbd-debug-build-overflows-uds-worker-stack-on-real-home-despite-8mib-floor`.

Pass extra flags to the node with `--env K=V`. Example:

```bash
lastdb-dev restart --env LASTDB_RESIDENT_MODE=off
```

The env the node booted with is in `~/.local/state/lastdb-dev/boot.env`.

## Client env

`lastdb-dev env` exports these variables:

- `LASTDB_HOME`, `FOLDDB_HOME` → the dev home (the `lastdb` CLI and the SDK)
- `FBRAIN_FOLDDB_SOCKET`, `FOLDDB_SOCKET_PATH`, `LASTDB_SOCKET_PATH`,
  `LAST_STACK_LASTDB_SOCKET` → the dev socket
- `BRAIN_CONFIG`, `KANBAN_CONFIG` → copies of `~/.brain/config.json` and
  `~/.fkanban/config.json` with `nodeSocketPath` set to the dev socket
- `FBRAIN_CAPABILITY_DIR`, `FBRAIN_CACHE_DIR` → dev-only copies, so a grant
  from the dev node never overwrites the primary's cached grant
- `LASTDB_DEV_ACTIVE=1`

## Safety

- The dev home is compared by realpath with the primary home before every
  clone, boot, and delete. A dev home that is the primary, sits inside the
  primary, or is a symlink is refused.
- The node always starts with `--data-dir <dev home>`.
- `stop` and `reset` signal only the pid in the tool's pidfile, and only when
  that process's argv carries `--data-dir <dev home>`.
- A previous clone is removed in the background after `refresh`. The delete
  is the slow half of a 13 GB clone cycle. It does not block the new boot.

## Paths

| Path | Meaning |
|---|---|
| `~/.lastdb-dev` | The dev home. Override with `LASTDB_DEV_HOME`. Keep it short: the socket path must fit 103 bytes. |
| `~/.local/state/lastdb-dev/` | Pidfile, boot log, boot env, staged binaries, client configs. Override with `LASTDB_DEV_STATE`. |
| `~/.lastdb` | The primary. Override the clone source with `LASTDB_DEV_PRIMARY_HOME`. |

## Costs to expect

Measured 2026-09-02 on the primary home (13 GB, ~42k files, M4 Max, load
average 30 from other agents):

| Step | Time |
|---|---|
| clone (`cp -cR`, APFS) | 75 s |
| cold debug build of `lastdbd` (sccache warm) | 57 s |
| incremental build after a `lastdb_node` edit | ~10 s (brain `lastdb-build-time-baseline-2026-08-06`) |
| incremental build after a `fold_db` edit | ~45 s (same record) |
| boot to identity, 1248 schemas | 18 s |

A second full node next to the primary needs memory. The tool warns when
less than 4 GiB is available (`LASTDB_DEV_MIN_MIB`). It does not refuse.

## Tests

`tests/last-stack-lastdb-dev.sh` drives the script against a fake primary
home and a fake `lastdbd`. It never touches `~/.lastdb`.
