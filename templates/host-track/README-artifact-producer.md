# Host Track artifact producer (agent CLIs)

LastGit CI auto-publishes after a green `.lastgit/ci.sh` when the repo carries
`.lastgit/artifacts.json`. Host Track then installs via `install_mode: artifact`
and (when `track_gate_main: true`) promotes `stable` to the newest green +
published main oid on `host-track refresh <app>`.

## Proven patterns

| App | Packs | Host Track links | Notes |
|-----|-------|------------------|-------|
| last-stack | skill-pack tree (`bin`, `skills`, …) | `bin/host-track`, … | `track_gate_main` |
| remote | source + `bin/*` | `bin/ra`, `bin/rad`, … | artifact CLI |
| brain | source + `bin/*` (no `node_modules`) | `bin/brain`, `bin/brain-mcp` | `post_install` = bun install |
| situations | `dist/*` compiled bins | `dist/situations`, `dist/fsituations` | CI must build `dist` before gate ends |
| kanban (artifact `fkanban`) | `dist/*` | `dist/kanban` | shared install_root; `fkanban` is retired from PATH |
| routines | `dist/routines` compiled bin | `dist/routines` | `track_gate_main` |
| lastsecrets | `dist/lastsecrets` compiled bin | `dist/lastsecrets` | `track_gate_main` |
| configurations | `dist/configurations` compiled bin | `dist/configurations` | `track_gate_main` |
| search | source + `bin/*` | `bin/search` | `post_install` npm/bun + neural smoke |

## Enable a remaining local-safe CLI

1. Add `.lastgit/artifacts.json` (see `artifacts.json.example`). Prefer packing
   **built** `dist/` for Bun CLIs that already emit binaries in CI, or pack
   `bin` + `src` + lockfile and run a `post_install` bun install (brain pattern).
2. Ensure `.lastgit/ci.sh` builds any paths you pack (e.g. `bun build` → `dist/`)
   **before** exit 0 — publish runs after the gate script succeeds.
3. Land a green merge so CI publishes `~/.lastgit/artifacts/builds/<app>/<oid>/`.
4. Flip `config/host-track/apps.json` in last-stack:
   - `install_mode: "artifact"`
   - `kind: "artifact cli"`
   - `track_gate_main: true`
   - remove `refresh: last-stack-refresh-local-safe`
   - fix `links[].source` to match packed paths
   - optional `post_install`
   - required `safe_upgrade.probes` (argv relative to the version tree; `host-track refresh` smokes these before flipping `current`)
5. Update post-merge map: `map_repo_to_app` → `artifact:<app>`.
6. Dogfood: `host-track refresh <app>` then `host-track status <app>` shows
   `install_mode=artifact`, `stale=false`.

## Remaining local-safe (none of the agent CLIs above)

Producer + registry flip landed for routines, lastsecrets, configurations, and
search. search keeps `post_install` for npm/sharp + neural smoke.

## Exemptions (do not convert)

- lastgit — `bootstrap-recovery`
- lastdb / lastdbd — `deployment-only` (`lastdb-safe-upgrade`)
