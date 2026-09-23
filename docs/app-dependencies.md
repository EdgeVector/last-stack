# App dependencies

This file records which EdgeVector app needs which other app. The registry
fields `requires` and `recommends` in `config/host-track/apps.json` and
`config/registry/apps.json` encode it. `docs/host-track.md` explains how
Host Track uses the fields.

Audit date: 2026-09-23. Source: `origin/main` of each app repo on Forgejo.
An audit agent read the call sites. A second reader checked the key claims.

## Classes

- **requires**: the app fails on a core path without the other app.
  Host Track installs it first and `host-track check` fails without it.
- **recommends**: the app runs without the other app. One feature degrades or
  falls back, or one command or graph fails. Host Track only reports it.
- **build**: the other app is needed to build, publish or install, not to run.
  The registry does not encode build edges.

## Map

| App | requires | recommends | Evidence (repo:path) |
|---|---|---|---|
| lastdbd | - | - | fold: the daemon calls no other app. It writes the search inbox that search and lastseek read. |
| lastdb | lastdbd | - | fold: the CLI talks to the daemon socket. |
| brain | lastdbd | lastseek, search, lastdb | brain `src/client.ts:89` socket. `src/search-plane.ts:1-20`: LastSeek first, then search, then the node search. `lastdb` only for `brain init` consent. |
| kanban | lastdbd, situations | brain, lastseek, last-stack | fkanban `src/client.ts:49` socket. `src/situations.ts:141,205-216`: `fsituations preflight` fails closed and blocks a move to doing. brain checkpoint, `--semantic` search and the forge-api fallback degrade. |
| situations | lastdbd | - | situations `src/client.ts:3`. |
| routines | - | situations, kanban, lastsecrets, configurations, lastdbd, brain | routines: each call has a fallback (`src/route-engine.ts:164`, `src/capacity-runtime.ts:42`, `src/claude-auth.ts:138`, `src/project-config.ts:106`). |
| lastsecrets | lastdbd | - | lastsecrets `src/lastdb.ts:16`. |
| configurations | lastdbd | - | configurations `src/lastdb.ts:16`. |
| lastseek | lastdbd | - | lastseek `src/main.rs:51`: `drain` reads the daemon inbox. |
| search | lastdbd | - | search `src/cli.ts:11` inbox drain. |
| remote | lastdbd | lastsecrets, brain, situations, kanban | remote `src/lastdb.ts:71`. Bot tokens come from env, then a file, then lastsecrets (`src/serve.ts:24,42`). |
| state-machine | lastdbd | situations, brain, kanban, last-stack | state-machine-app `src/lastdb.ts:66`. `sm cutover` needs brain (`src/cutover.ts:132`). The step scripts need last-stack and kanban. |
| reconciler | lastdbd, lastsecrets | - | reconciler `src/capability-store.ts:50,60`: the default mode reads its capability from lastsecrets. |
| loom | lastdbd, routines | kanban, last-stack, state-machine, brain, lastseek, lastgit | loom `src/lastdb.rs:31` socket. `src/runner.rs:4583` runs `routines agent-exec` for every agent node and fails closed. Card graphs need kanban. Deploy and canary graphs need host-track and sm. |
| lastgit | lastdbd | - | lastgit `src/client.ts:33`. |
| lastdb-browser | lastdbd | - | lastdb-browser `bin/lastdb-browser:22` socket bridge. |
| last-stack | - | lastgit, kanban, brain, routines, situations, loom | last-stack is a tool pack. Each bin calls the app it serves. `host-track` needs lastgit for artifact installs. |
| dogfood-graph (public) | lastdbd | - | dogfood-graph `src/data/lastdbNodeClient.ts:13`. |
| org (public) | lastdbd, lastsecrets | - | org `src/cli.ts:339,359,481`: create, invite and join store secrets. |

The public bundle omits `lastdbd` from `requires`, because the bundle always
installs the LastDB daemon from Homebrew.

## Build edges (not in the registry)

- Every artifact app needs **lastgit** and **last-stack** to install:
  `host-track` runs `lastgit artifact resolve`. Each repo's Forge CI runs
  `lastgit artifact publish`.
- last-stack and lastgit need each other to build (lastgit installs through
  its own checkout script).

## Claims that the audit did not confirm

- **"kanban requires loom."** fkanban has no Loom call. Its pickup text says
  "No ... Loom". The edge runs the other way: loom's card graphs call kanban.
  One scheduled routine couples them: pickup worker w6 sets its `prompt_path`
  to loom's `loom-land-card-pickup-prompt.md`
  (`~/.routines/registry/last-stack-fkanban-pickup-w6.toml`). That is a
  routine setting on this host, not an app edge.
- **"brain requires lastseek."** brain prefers LastSeek and falls back to
  search and then to the node search. brain's own CI replaces lastseek with a
  stub that exits 127. So the edge is `recommends`, not `requires`.

## Cycles

No cycle exists among `requires` edges. `validate-registry` fails on a cycle.
Feature-level loops exist (last-stack runs loom; loom's deploy graph runs
host-track). They stay in `recommends`.

## Not checked

- The MCP servers (they share the CLI code).
- The skill and routine prompt text in last-stack.
- The desktop app and `exemem_service` in fold.
- Scheduled routine TOMLs other than the pickup workers.
