---
name: fkanban-setup
version: 0.2.0
description: |
  Bootstrap fkanban on a fresh machine or checkout — install deps, run `init`
  (resolve published schemas + seed the default board), verify with `doctor`,
  and optionally register the MCP server. Use when the user says "set up
  fkanban", "fkanban isn't working / can't find config", "install fkanban",
  "fkanban doctor fails", "bootstrap the kanban board", or after a fresh clone
  of fkanban. For day-to-day card management use the `fkanban` skill; to work a
  card to a merged PR use `fkanban-agent`.
---

# fkanban — setup & repair

fkanban is a Bun/TypeScript client of a **LastDB node** — the board lives on the
node, the CLI just talks to it over the configured transport. Local daily-driver
nodes may be **Unix-socket only** with HTTP intentionally shut down. Setup = make
the CLI able to reach a node that already has the `fkanban/*` schemas published.
**The `fkanban/*`
schemas are already published**, so `fkanban init` only *loads and resolves*
them — it never publishes anything and needs no developer credentials.

Config it reads/writes: `~/.fkanban/config.json` (override with `$FKANBAN_CONFIG`).

## Prerequisites

Three things, in order:

1. **Bun** — fkanban is a Bun/TypeScript app:
   ```bash
   curl -fsSL https://bun.sh/install | bash
   ```
2. **The fkanban repo** — clone it and install dependencies:
   ```bash
   git clone <fkanban-repo-url> fkanban
   cd fkanban
   bun install
   ```
3. **A running LastDB node** — fkanban is a thin client; it needs a node to talk
   to. `init` defaults to a node running locally on your machine, so a locally
   started node works out of the box; point elsewhere with `--node-url`. Start a
   node (e.g. from your LastDB install / daemon) before running `init`. On a
   fresh, unprovisioned node, `fkanban init` auto-provisions the node identity on
   first run, so you can skip any interactive identity wizard — handy for
   headless/SSH/CI.

## Put `fkanban` on PATH (one-time, reversible)

```bash
cd fkanban
bun run install-cli   # symlinks the fkanban + fkanban-mcp shims onto PATH
fkanban doctor        # confirms the shim is on PATH
```

`install-cli` auto-picks a writable PATH directory (`/usr/local/bin`,
`~/.local/bin`, or `~/bin`); pass an explicit one if you prefer
(`bun run install-cli ~/bin`). It just symlinks the bundled `bin/fkanban`
wrapper (a tiny `bun run src/cli.ts "$@"` script) — fully local and reversible,
nothing is published to a registry. Without the shim, run `bun run src/cli.ts
<cmd>` from the repo directory; the two are equivalent.

## Happy path (node already running with fkanban schemas)

This is the normal case — a node that already has `fkanban/*` published.

```bash
cd fkanban
bun install
bun run install-cli                # put fkanban on PATH (see above)
fkanban init        # bootstrap + LOAD/RESOLVE published schemas + seed default board
fkanban doctor      # verify: shim on PATH, config, node reachable, schemas loaded, round-trip
```

`init` is **idempotent** — safe to re-run. Defaults: a node running locally on
your machine, plus a schema-service URL it uses to load the published schemas
(override either with `--node-url` / `--schema-service-url`).

A green `doctor` ends with `✓ query round-trip — N cards, M boards`. After
that, the `fkanban` skill's commands all work.

## Point at a different / ephemeral node instead

For a throwaway node (so you don't touch a shared daily-driver node when
iterating), override both URLs:

```bash
fkanban init \
  --node-url unix:///tmp/throwaway-node/folddb.sock \
  --schema-service-url <your-schema-service-url>
```

## If `init` reports `schemas_not_published`

This means the `fkanban/*` schemas haven't been published to *that* schema
service yet. For the standard hosted/published schema service this should not
happen — point `init` at the published schema service (the default). Publishing
the `fkanban/*` schemas to a *brand-new* schema service is a one-time maintainer
task (see the fkanban repo README → "Republishing the schemas"); a regular user
does **not** publish anything. If you hit this against the default service,
re-check your `--schema-service-url` / `--node-url`.

## If `doctor` fails

- **node unreachable** → the node/daemon isn't reachable over the configured
  transport. First trust the `doctor` transport line: a green socket-backed
  `doctor` means the node is healthy even if `curl <node-url>/api/health` fails
  because HTTP is disabled. If `doctor` fails, surface it. **Never** kill/restart
  a node you don't own to "fix" this — restart only a node you own.
- **schema hash mismatch / not loaded** → re-run `init`.
- **config missing** → run `init`.

## Register the MCP server (optional)

To drive the board from an agent over MCP:

```bash
cd fkanban
claude mcp add fkanban bun "$PWD/src/mcp/main.ts"
```

It reads the same `~/.fkanban/config.json`.

## Guardrails

- The board is shared state on the node — don't reset/wipe the node to "start
  clean"; `init` is additive and idempotent.
- When iterating on fkanban itself, prefer an **ephemeral node** over a shared
  daily-driver node.
