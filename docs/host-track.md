# Host Track

`host-track` is the shared agent-facing command for checking and refreshing
durable host installs. It keeps agents pointed at known host tracks instead of
ad hoc worktrees under `~/code/edgevector`.

## Commands

```bash
host-track status --json
host-track status lastgit
host-track which lastgit
host-track which last-stack --json
host-track check lastgit
host-track refresh lastgit
host-track refresh --all
host-track refresh --force last-stack
host-track install --channel candidate my-app
host-track rollback my-app
host-track validate-registry --json
host-track requires --json kanban
```

The default registry lives at `config/host-track/apps.json`. Tests and local
experiments can point at another registry with `HOST_TRACK_REGISTRY`.

## Artifact installs

New entries in the default registry inherit `install_mode: artifact`. Existing
checkout-backed apps carry an explicit `install_mode: checkout` until their
producer and compatibility proof are migrated. Checkout-backed apps must carry
an `artifact_exemption` with `kind` set to `deployment-only` or
`bootstrap-recovery`, plus an `owner` and `rationale`, so continuous dogfood can
separate intentional exceptions from drift. An artifact entry can set:

```json
{
  "app": "my-app",
  "command": "my-app",
  "artifact_app": "my-app",
  "artifact_channel": "stable",
  "install_root": "$HOME/.host-track/apps/my-app",
  "post_install": "$HOME/.host-track/apps/my-app/current/bin/post-install",
  "links": [
    {"source": "bin/my-app", "target": "$HOME/.local/bin/my-app"}
  ]
}
```

`host-track install` asks LastGit to resolve and verify the promoted channel,
verifies every blob again while copying it, installs under the immutable
`versions/<manifest-digest>` directory, **probes that tree while `current`
still points at last-known-good**. If the app sets `safe_upgrade.soak_hours`
and a live current exists, refresh parks a `canary` pointer and leaves PATH
alone; `host-track soak-watch` re-probes and promotes after the window.
`--activate` (or `soak_hours: 0`, last-stack) flips `current` on GREEN probe.
The displaced version remains at `previous` for `host-track rollback`.
`host-track check` verifies the active payload hashes as well as freshness.
It refuses to replace a non-symlink command target.
When configured, `post_install` runs on the version tree **before the probe**
(so bun/npm hooks exist for the smoke) unless the app sets
`safe_upgrade.post_install_phase` to `after-cutover` (last-stack `setup`,
which rewrites live links). A failed hook or a RED probe leaves the app
stale (no new stamp) and does not flip PATH.

The hook gets these variables: `HOST_TRACK_APP`, `HOST_TRACK_INSTALL_ROOT`,
`HOST_TRACK_MANIFEST_DIGEST`, `HOST_TRACK_VERSION_DIR` (the candidate tree;
not set for a rollback or an after-cutover call), `LAST_STACK_ROOT` (the same
tree) and `HOST_TRACK_APPROVED_SCHEMAS` (a JSON array; see "Apps that need a
post-install step"). With a soak, host-track runs the hook again when it
activates the canary, so a hook must be safe to run twice. An entry can set
`post_install_timeout_s`: host-track then stops the hook after that many
seconds and fails the install (exit 124). Without it the hook has no limit.
A hook that the registry puts outside the app's own install root is resolved
from exactly that path; the candidate tree cannot supply it.

Every artifact app must declare `safe_upgrade.probes` — argv relative to the
version tree. `host-track validate-registry` fails closed when an artifact
app has none. Brain / kanban / situations also set `"latency": true` so a
correct-but-much-slower candidate is RED against the current tree. Tom-only
escape: `HOST_TRACK_PROBE_SKIP=1`. LastDB Mini stays on `lastdb-safe-upgrade`.

### Last Stack one rule (artifact is the only runtime)

**Runtime install = Host Track CI artifact that tracks green main. Never a place you develop.**

Mental model: the live stack tracks the **published** channel. `host-track
refresh last-stack` promotes `stable` to the newest **green + published** main
oid and installs it. Status `gate_head` is that published channel oid.
`stale=true` means the live digest is not the channel, or the tree is
unusable. `main_unpublished=true` means the gate's `main` is ahead of the
channel (CI pending or the package is not published yet). Pickup, `check`,
and `last-stack-update-check` use only the on-channel question. The
LaunchAgent (not pickup) promotes when a deployable oid exists. Do **not**
treat unpublished `main` as a stale install.

`main_unpublished=true` is an inequality, so it is also true when the channel
moved **backward**, and that case needs the opposite action: waiting never
fixes it. `channel_order` answers which one you are looking at. The puller
records it on the channel file at promote time, because commit order is known
only there — host-track holds no git object store. Read it before acting on
`main_unpublished`:

| `channel_order` | means |
|---|---|
| `forward` | the last promote advanced the channel (the ordinary case) |
| `backward` | the channel was moved to an ancestor of, or a line divergent from, its own previous head — only `--allow-rollback` permits this, and `channel_previous_oid` names the head it displaced |
| `unordered` | GitHub could not order the two (the previous head was force-pushed away); nobody established the direction |
| `resign` | the same oid was re-promoted to pick up new signatures; not a move |
| `initial` | the first promote onto this channel |
| `unknown` | the channel file records no order: written before the field existed, or by the retired LastGit promote arm. Not the same as `forward`. |

| Role | Path | Mutable? |
|------|------|----------|
| **Run** | `~/.local/state/last-stack/artifacts/versions/<digest>` via `current` | No — replace whole version |
| **Compat paths** | `~/.last-stack/{bin,skills,routines,...}` -> `~/.local/state/last-stack/artifacts/current/...` | Symlinks only |
| **Dev** | Isolated worktree of `EdgeVector/last-stack` | Yes — normal CR flow |
| **State** | logs, proofs, dogfood, stamps under `~/.local/state` / install state dirs | Yes |

Last Stack artifacts install below `~/.local/state/last-stack/artifacts` so
verified versions, stages, and rollback state do not dirty the `~/.last-stack`
owner mirror. The artifact `post_install` runs `setup`, and artifact-mode setup
runs `last-stack-activate-artifact-layout`, which:

1. Moves any leftover real code trees aside (recovery under
   `~/.local/state/last-stack/layout-backups`)
2. Symlinks stable paths (`bin`, `skills`, `routines`, `config`, ...) at
   `~/.local/state/last-stack/artifacts/current/...`
3. Freezes the active version tree (`chmod a-w`) so agents cannot hand-edit
   through the compatibility links
4. Re-runs `./setup` from the artifact (skill links, host-track refresh agent)

Manual / dry-run:

```bash
~/.local/state/last-stack/artifacts/current/bin/last-stack-activate-artifact-layout --dry-run
~/.local/state/last-stack/artifacts/current/bin/last-stack-activate-artifact-layout
```

The migration moves displaced code into a timestamped directory under
`~/.local/state/last-stack/layout-backups`; it leaves `.git`, `launchd`, logs,
proofs, and other local state untouched. By default the activator skips a git
worktree compatibility root instead of replacing tracked source paths with
artifact links; use a non-git compatibility root for that layout. Artifact
installs use the Host Track refresh agent, so setup removes the retired Git
self-upgrade LaunchAgent.

**Upgrade:** `host-track refresh last-stack` (or the host-track refresh
LaunchAgent). Git `self-upgrade` / dirty-tree repair is a no-op on artifact
runtime and must not be used to “heal” agent edits.

**Develop:** worktrees only. Never `Write` product files under `~/.last-stack`.
Runtime artifact state is intentionally outside the owner mirror so it cannot
dirty that checkout.

## Apps that need a post-install step

Three apps changed how they store data. Each one needs one explicit step when
a new build installs. Do not skip the step: the build fails or reads old data
without it.

### Approved schema registration

A LastDB node registers a new schema in the Schema Service of its own
environment. A node with no `EXEMEM_ENV=dev` registers in PROD.
Tom approved on 2026-10-14 that the schemas below may register in PROD when the
new builds install. Nothing else in the PROD catalog is approved. No
exemem-infra or schema-infra deploy is approved.

| App | Approved schemas (`approved_schema_registration`) | What enforces it |
|-----|---------------------------------------------------|------------------|
| `situations` | `IndexEntry_hashrange_v1` with fields `ie_h`, `ie_marker`, `ie_payload`, `ie_r`; `NoticeHistory_hashrange_v1` with fields `nh_h`, `nh_marker`, `nh_payload`, `nh_r` | The `post_install` hook (below) |
| `brain` | `TagMembership_hashrange_v1` (name only) | Nothing. The operator runs `brain init` by hand |
| `state-machine` (`sm`) | `SmIndexEntry_hashrange_v1` (name only) | Nothing. `sm` declares the schema itself |

The list sits on the app entry in `config/host-track/apps.json`. To change it,
open a PR to EdgeVector/last-stack. A reviewer checks the list against this
table.

- An entry is a schema name, or `{"name": ..., "fields": [...]}`. A name with
  `fields` pins the shape: the exact field names, sorted. The `situations` hook
  accepts only `{name, fields}` entries and refuses on any difference, because
  a later build with the same name and another body would register a new
  identity.
- `brain` and `state-machine` keep names only. A hook for them would need the
  field names too. Add the field pins when their PRs merge (for `sm`, when
  EdgeVector/state-machine PR 4 merges; the name comes from that PR and may
  change, so edit the list then).
- `host-track validate-registry` fails when an entry is not a name or a
  `{name, fields}` with sorted field names.

host-track passes the list to the hook in `HOST_TRACK_APPROVED_SCHEMAS`, as a
JSON array. The list comes from the registry of the running host-track, never
from the candidate tree, so a build cannot approve itself. host-track sets the
variable on every hook call, and a value from the caller never reaches the
hook. For a custom registry (`HOST_TRACK_REGISTRY`: every dev and fixture run)
the variable is `[]`, so the hook registers nothing.

### situations

The current state: a build with the `IndexEntry` and `NoticeHistory` schemas
fails `situations put` and `situations notice` before any write
(`index_layout_missing`) until `situations init` has run on the node.
`situations preflight` and `situations list` stay correct. Without a hook the
build would go live after the soak and every notice would fail.

The change: the `situations` entry has a `post_install`,
`bin/last-stack-situations-host-track-post-install`, with
`post_install_timeout_s: 480`, and the probes `--help`, `list`, `doctor`,
`list`.

Before step 1, the hook does two things:

- It puts back a copy of the config that an unfinished run left (see below).
- It refuses when the config has a `nodeUrl` that is not loopback (`127.0.0.1`,
  `localhost` or `[::1]`, with an optional port). The candidate uses the node
  socket only for a loopback URL, so `init` would declare on that other node,
  and the hook read this node. The hook never passes such a URL on.

What the hook does, in order:

1. It runs the candidate's `situations doctor --json` (read only). When
   `IndexEntry` and `NoticeHistory` are loaded on the node and pinned in the
   config, it exits 0. Nothing else happens.
2. Otherwise init is needed. It refuses, and fails the install, when the
   install root is not under `$HOME/.host-track/apps`, or when `EXEMEM_ENV=dev`
   is set. These two checks come before anything that can write, so even an
   `init` that registers nothing runs only on the real install. The
   `EXEMEM_ENV` check reads the environment of host-track. It cannot see how
   the node was started. If the host exports `EXEMEM_ENV=dev`, run the command
   with `env -u EXEMEM_ENV host-track refresh situations`.
3. It works out which schemas `situations init` would register. `init` has no
   check mode. It registers every schema the node has not loaded, rewrites the
   config and writes the long-lived notices. So the hook takes the candidate's
   `situations schema --type all` and removes the schemas that
   `GET /api/schemas` on the node already lists. It refuses when any schema on
   that list is not in `HOST_TRACK_APPROVED_SCHEMAS` with the same sorted field
   names. A target with no owner, no name or an empty field list, an empty
   reply from the node, and an empty list all refuse. An approved entry with an
   empty name, or with no field names, refuses at the start. When `init` would register nothing (it
   only writes the config), it runs.
4. It copies the config, then runs `situations init`. The copy is a file named
   `config.json.pre-init.XXXXXX` next to the config (`mktemp`). `init` rebuilds
   the config from the node listing and can repin the Situation, Notice and
   Index schemas or drop `nodeSocketPath`, and the old build is still `current`
   and reads that file. So the hook passes `init` the values the file already
   holds (`--schema-hash`, `--notice-schema-hash`, `--user-hash`, `--node-url`,
   `--node-socket-path`, `--schema-service-url`), then compares the three legacy
   pins (situation, notice, index) and `nodeSocketPath` with the copy. `init`
   takes the user hash only as `--user-hash`, so it shows in `ps` while `init`
   runs. The install log never prints it.
5. It runs `doctor` again. Both schema checks must read `ok`.

If any step after the copy fails (the `init` exit code, a pin that changed,
`doctor`, a timeout, a TERM or INT signal), the hook first stops the `init`
that still runs and waits for it, so that it cannot rewrite the config after the
copy is back. It then puts the copy back and checks that the file equals the
copy, and removes the copy. If it cannot put the copy back, it keeps the copy and
prints the command to run. When there was no config before, it removes the config
that `init` wrote. On success it removes the copy. The messages go to the hook's
own stderr, which is the install log. The `init` result goes to the install log
without the user hash.

A KILL runs no trap. host-track stops a hook that runs past its limit with
SIGKILL, so the limit is 480 s, above the sum of the limits of the hook: `doctor`
60 s, `schema` 60 s, node read 30 s, `init` 180 s and `doctor` again 60 s, which
is 390 s. The limits of the hook fire first. If a KILL still happens, the copy
stays next to the config. On its next start the hook finds the oldest copy
(`config.json.pre-init.XXXXXX`), waits up to 60 s for an `init` of the
unfinished run that still runs, puts the copy back, and only then goes on. A
partial copy (`config.json.pre-init-partial.XXXXXX`, a run stopped inside the
copy) is deleted, never used. A copy that is not a JSON object stops the hook:
check both files by hand. A hang would stall the serial refresh of every app
behind it, so each limit exists.

`declare-schema` can take longer than the 30 s limit of the node client. The
first run may fail with a timeout. The hook then leaves the config as it was,
and a second `host-track refresh situations` retries. The node may already have
registered the schemas; the retry finds them loaded.

The node is the one under `$HOME` (`~/.lastdb`) and the
config is the one under `$HOME` (`~/.situations`, else `~/.fsituations`). The
hook sets `FOLDDB_SOCKET_PATH` and `SITUATIONS_CONFIG` for the candidate and
unsets `FSITUATIONS_CONFIG`, so an override in the caller cannot point it at
another node or file. With no socket the hook fails.

On any failure the hook exits 1 (124 on a timeout). host-track then fails the
install: `current` stays on the last-known-good build, no stamp is written, and
the next refresh tries again. The staged tree stays under `versions/<digest>`.

Who supplies the hook: host-track resolves a hook that the registry puts
outside the app's own install root (the last-stack tree, `~/.local/bin`) from
exactly that path. A candidate tree cannot supply it or shadow it with a file of
the same name. A hook inside the app's own `current` tree (brain, search,
reconciler) still comes from the candidate tree: it ships in the artifact.

What runs when, for `host-track refresh situations`: host-track stages the
candidate tree and the old build stays `current`. The hook runs. The probes
run. host-track parks the candidate as `canary` for the soak (1 hour, 3 green
checks; the refresh agent, when it is loaded, runs `soak-watch` every 20
minutes, and otherwise you run `host-track soak-watch situations`). When the
window ends, host-track runs the hook again (it finds the layout ready and does
nothing), runs the probes, and flips `current`.

The probes. `situations doctor` is read only and exits 1 when a check fails.
`list` is the last probe on purpose: host-track times the last probe for the
latency check, so `list` stays the latency probe, and the first install is
measurable because the old build has `list`. The first `list` runs before
`doctor`, so it can repair drift in the partitions it reads first. Know this:

- The first time, the old build has no `doctor`. A candidate failure is then
  INCONCLUSIVE (host-track holds the install and tries again), not RED. A
  failure that comes from node state (drift, an unreadable entry) is
  INCONCLUSIVE with any incumbent, because both builds see the same state.
  RED needs a candidate that fails while the incumbent passes.
- During the soak the old build is `current`. A `put` of an existing situation
  by the old build after the copy is drift that a `list` cannot repair. The
  canary then stays parked, and soak-watch reports the probe as inconclusive,
  until the entry is put again with the candidate build
  (`~/.host-track/apps/situations/canary/dist/situations put <file>`). The
  Tom-only escape is `HOST_TRACK_PROBE_SKIP=1`. Run one build
  (`command -v situations`). To avoid the drift, pause `situations put` (the
  writers of situations) during the soak. A `notice` by the old build does not
  matter: the new build has not copied the notice partitions yet.

### brain

The current state: `brain init` registers `TagMembership_hashrange_v1`. Until
then, tag reads use the legacy layout and print one warning per command, and
tag and backlink writes are skipped.

Decision: do not add `brain init` to `post_install`. The evidence is in
`src/commands/init.ts` and `docs/tag-membership.md` of EdgeVector/brain:

- `init` declares every schema in `UNIQUE_SCHEMAS`, not only the new one. It
  has no check mode and no option to pick one schema. The approved list cannot
  limit it from outside.
- `init` also rewrites `~/.brain/config.json` (it writes the file twice), can
  bootstrap an unprovisioned node, stamps the record-list partitions of every
  type it registers for the first time, and can run the consent grant.
- The brain entry already has a `post_install`
  (`bin/brain-host-track-post-install`, `bun install`). It lives in the brain
  artifact. One entry has one hook.
- `reindex` must stay out of `post_install`. It is an admin step for a quiet
  moment, one device at a time. It deletes rows that no record backs.
- `brain doctor` is not a probe. It has no way to run one check, so it runs
  every check, and any unrelated failure (the Schema Service, the embedding
  runtime, a write capability) would hold every brain install.

What the operator runs, in this order (from `docs/tag-membership.md`):

1. `host-track refresh brain`. Wait until `host-track status brain` shows the
   new digest as current.
2. Replace every other brain binary on every device: restart each running
   `brain-mcp` and each routine host. An old binary writes only the legacy
   layout, and the new code never reads that layout again.
3. Check the new build for other new schemas (`UNIQUE_SCHEMAS` in
   `src/schemas.ts`). Only `TagMembership_hashrange_v1` is approved. If
   another schema is new, stop and ask Tom.
4. Run `brain init` once. Between steps 1 and 4 the new build skips tag and
   backlink writes. Step 5 rebuilds them from the records, so nothing is lost.
5. In a quiet moment, on one device: `brain reindex --tags`, then
   `brain reindex --backlinks`.
6. Run `brain doctor`. The `tag-index` check must pass.

A change in the brain repo would let a hook do step 4 safely: an option such
as `brain init --only <schema>`, or a check mode. Until then, the step stays by
hand.

### state-machine (`sm`)

No post-install step, no new probe. In EdgeVector/state-machine PR 4 the
first `sm` command that touches an index declares the index-entry schema and
writes its hash to the config (`prepareClient` in `src/cli.ts`). The first
run also copies the legacy lists. That takes seconds to minutes on a loaded
node. After the copy, the new code never reads the legacy lists again.

The existing probes, `sm --help` and `sm schema-json --type all`, never touch
an index, so they register nothing. Do not add a probe that reaches the
node. It would declare the schema and copy the lists while the old build is
still `current` and still writes the legacy lists. Never run a flow definition
as a probe.

So the registration of `SmIndexEntry_hashrange_v1` happens when the first `sm`
command runs after the flip. No host-track gate sees it. The approved name is
on the `state-machine` entry for the reviewer. To run it at a time you choose,
run `sm list --limit 1` once after the flip, before the routines that call
`sm` start.

### Safe order for the first install of these builds

The registry that host-track reads comes from the last-stack tree it runs from
(`ROOT` is resolved with `pwd -P`). Until last-stack's own flip (1 hour, 3
checks), every run uses the OLD registry, which has no hook and no `doctor`
probe. A `situations` build staged before then can flip with no `init`, and
every `put` and `notice` would fail. The situations PR 14 is already merged, so
a `situations` build can reach the `stable` channel at any time.

Installs are deliberate. Nothing runs `host-track refresh --all` for you unless
the refresh LaunchAgent is loaded (check with
`launchctl print gui/$(id -u)/com.edgevector.host-track-refresh`). If it is not
loaded, nothing ticks `soak-watch` either: every step below is a command that
you run. Name one app in each command. Do not run `host-track refresh --all`
before step 3.

`last-stack-post-merge-safe-upgrade` maps `situations` and runs
`host-track refresh situations` after each merged situations PR. Keep it stopped
until step 2 is done. It has no per-repo switch, and last-stack ships no
supervisor for it (`launchd/` has no plist for it), so it runs only if you
started it. Check that it is not running: `pgrep -fl last-stack-post-merge-safe-upgrade`
prints nothing, and `grep -l post-merge-safe-upgrade ~/Library/LaunchAgents/*.plist`
prints nothing.

1. Merge this PR. Then run `host-track refresh last-stack` alone. This is the
   only way to pick up the new registry. It stages the new last-stack tree and
   parks it as a canary for the soak.
2. Tick the soak of last-stack: `host-track soak-watch last-stack`. Each tick
   is one probe check. The flip needs 3 green checks and a window of 1 hour, so
   run it at least twice, and the last time at least 1 hour after step 1. The
   tick that meets both prints `soak GREEN ... activating`. To see that the
   soak ended: `host-track status last-stack` shows `stale=false` and `soak=-`,
   and `readlink ~/.local/state/last-stack/artifacts/current` names the new
   digest. While it still reads `soak=soaking:...`, the old registry is in use.
3. Check the new registry. The hook file
   `~/.local/state/last-stack/artifacts/current/bin/last-stack-situations-host-track-post-install`
   must exist, and the registry in the same `current` tree
   (`config/host-track/apps.json`) must have the `post_install` and the
   `approved_schema_registration` lists of `situations`.
4. Back up the situations config (`~/.situations/config.json`). Read
   `GET /api/schemas` and confirm that `Situation`, `Notice` and `Index` are
   loaded. The hook refuses if one is missing: it would have to register it.
5. Run without `EXEMEM_ENV` in the environment (`env -u EXEMEM_ENV`), then run
   `host-track refresh situations` alone. Pause `situations put` during the
   soak. Tick `host-track soak-watch situations` the same way as in step 2.
6. After the soak, run `situations doctor` and confirm that one binary is in
   use (`command -v situations`).

A canary that was staged while the old registry was running was probed with no
hook and no `doctor`. After step 3, run `host-track refresh --force situations`:
`--force` always re-stages, so the new registry runs the hook and the new
probes. Without it, a canary whose window ends under the old registry flips
with no `init`.

There is no guard in `bin/host-track` that closes this window, and none can be
added here. A guard that refuses to flip a `situations` candidate whose registry
has no `post_install` would ship in the same last-stack artifact as the
registry. The old tree runs both until last-stack flips, so it has neither. The
safe order above closes the window.

For `brain`: refresh, replace every binary, `brain init`, `reindex`, `doctor`
(see above). For `sm`: refresh, the flip, then the first `sm` command.

Dev and fixture runs cannot register anything: a custom registry gives an
empty approved list, and a refusal fails the install.

## Status Shape

Each status record reports:

- `app`
- `command`
- `gate`
- `gate_main`
- `host_track`
- `host_head`
- `host_head_short`
- `version`
- `gate_head`
- `exec_path`
- `kind`
- `install_mode`
- `stale` (artifact: live digest ≠ published channel, or unusable tree)
- `main_unpublished` (artifact: gate main tip ≠ published channel oid — true for
  publish lag AND for a backward channel; read `channel_order` to tell them apart)
- `channel_order` (`forward` | `backward` | `unordered` | `resign` | `initial` |
  `unknown`) and `channel_previous_oid`, the head the last promote displaced
- `freshness` (`fresh` | `soft_stale` | `hard_broken`)
- `behind_by` (commit distance when the installed and gate OIDs are available)
- `binary_pair_match`, `paired_version`, `paired_head`, and
  `deployment_problem` for safe-upgrade-managed binary pairs
- `stamp`
- `refresh`
- `notes`

Use `host-track status --stale` (optionally with `--json`) to show only apps
whose measured `stale` value is true. Unknown measurements are not silently
included as fresh.

Artifact-backed records also report `artifact_app`, `artifact_channel`,
`artifact_root`, `install_root`, `manifest_digest`, and
`channel_manifest_digest`.


## App dependencies (`requires` / `recommends`)

An app entry names the other registry apps it needs:

```json
{ "app": "kanban", "requires": ["loom"], "recommends": ["search"] }
```

- `requires` lists apps that the app cannot run without on a core path.
  `host-track install <app>` and a single-app `host-track refresh <app>`
  install every missing app in the transitive closure first, dependencies
  first, each in its own install process. A missing dependency that Host Track
  cannot install (`checkout` or `deployment-only`, for example `lastdbd`)
  fails the install with the reason. Dependencies install on their own
  registry channel; `--channel` applies to the named app only.
- `host-track check <app>` fails while any app in the closure is absent from
  the host (its `command` does not resolve on PATH). It reads the host, not the
  list.
- `recommends` lists apps that only add a feature or a faster path. Host Track
  reports them in `requires --json` and never installs or gates on them.
- `host-track requires [--json] <app>` prints the install order and what is
  present or missing. It exits 1 while a required app is missing.
- `validate-registry` fails on a `requires`/`recommends` entry that names an
  unknown app, on a self-requirement, and on a cycle.

The public bundle registry (`config/registry/apps.json`) carries the same
fields. `last-stack-install-apps` prints a WARNING for each declared
requirement the bundle does not install and PATH does not provide.

The dependency map and its evidence: `docs/app-dependencies.md`.

## Public Homebrew release (`brew_release`)

Tom decided on 2026-09-23 that loom and lastseek reach public users as Homebrew binaries in the public tap `EdgeVector/homebrew-lastdb`. The source stays private. See brain `decision-2026-09-23-loom-lastseek-public-via-homebrew-binaries`.

An app entry with a `brew_release` object is released by `last-stack-brew-app-publish`:

- **Gate.** `current` must equal the stamped digest, the post-flip watch must be clear, and every shipped file must match the artifact manifest. Nothing is rebuilt: the tarball is what this Mac runs.
- **Contents.** `files`, every file under `dirs`, and the definitions that each `subsets[].list` names. For loom, the list is `release/public-definitions.txt`, the generic graphs only.
- **Tag.** `<formula>-v<version>` from `version_argv`, released with `--latest=false`, so that the lastdb `v*` tags and `releases/latest` stay unchanged.
- **Formula.** `templates/homebrew/<formula>.rb.tmpl` is rendered and opened as a tap PR with auto-merge. Edit the template, not the tap file.
- **Trigger.** `host-track refresh --all` runs the publisher with `--if-needed` after the soak tick. A digest that was already handled is a local noop. The same version with a new digest logs "bump the app version" and does not upload.
- **First release.** The first release of a formula needs `--approve-first-release`, run by hand after Tom says yes. Until then the hook exits 3 quietly.
- **Off switch.** `LAST_STACK_BREW_AUTO_PUBLISH=0`.

```bash
last-stack-brew-app-publish --app loom --dry-run      # gate + package, prints the run dir
last-stack-brew-app-publish --app loom --publish --approve-first-release   # PUBLIC
```

## Registry compliance (artifact | exempt | non_compliant)

North Star end-state #6: every registered agent-facing app is either on verified
`install_mode: artifact` or declares an explicit machine-readable
`artifact_exemption`. Status and `validate-registry` surface this without a
separate forever routine.

| `registry_compliance` | Meaning |
|-----------------------|---------|
| `artifact` | `install_mode=artifact` |
| `exempt` | non-artifact with valid `artifact_exemption` (`kind` + `owner` + `rationale`) |
| `non_compliant` | neither — including any remaining non-exempt non-artifact entries |

Allowed exemption `kind` codes (short, machine-readable):

- `bootstrap-recovery` — substrate that must stay checkout-backed so the forge
  can still be repaired when artifact/CR paths are unhealthy (seed: `lastgit`).
- `deployment-only` — install/activation is intentionally outside generic Host
  Track refresh (seed: `lastdb` / `lastdbd` via `lastdb-safe-upgrade`). These
  apps may still declare report-only `deployment_binary`,
  `deployment_peer_binary`, and `deployment_repo_cache` fields. Status reads
  their embedded Git version stamps and the protected gate ref; refresh remains
  explicitly disabled even when status reports `stale=true`.

### Adding a new exemption (no forever routine)

1. Edit `config/host-track/apps.json` for the app. Keep or set a non-artifact
   `install_mode` only when artifact mode is genuinely wrong.
2. Add:

```json
"artifact_exemption": {
  "kind": "deployment-only",
  "owner": "platform",
  "rationale": "One sentence why Host Track artifact refresh must not own this app."
}
```

3. Run the fail-closed policy scan (pure registry; no live installs):

```bash
host-track validate-registry --json
# or against a fixture:
HOST_TRACK_REGISTRY=/path/to/apps.json host-track validate-registry
```

4. Land via the normal last-stack CR path. Continuous health remains the
   **fleet channel freshness gate** (below) — wire it as a dogfood-registry
   maintain recipe, not a new forever routine. `validate-registry` keeps fleet
   migration pressure visible as `non_compliant`; the live invariant still
   accepts healthy `local-safe` installs when present.

Do **not** invent a new scheduled routine for exemption drift. Wire checks into
`host-track status` / `validate-registry` / the fleet gate dogfood entry.

## Fleet channel freshness gate (NS end-state #7)

`bin/last-stack-fleet-channel-freshness-gate` is the **single** machine-checkable
fleet-rollout acceptance gate for `north-star-artifact-driven-host-track`. It
composes prior PRs without a hollow Kind:validation shell:

1. `host-track validate-registry` — every registered app is **artifact or exempt**, and every artifact app declares `safe_upgrade.probes`
2. `last-stack-host-track-artifact-invariant` — every artifact channel is
   **fresh** (`stale=false`), provenance/hashes hold, and **rollback targets**
   resolve when `previous` exists

```bash
# Full live gate (dogfood-registry maintain recipe / non-sandboxed runner)
bin/last-stack-fleet-channel-freshness-gate
bin/last-stack-fleet-channel-freshness-gate --json

# Pure registry policy only (CI / fixtures; no live installs)
bin/last-stack-fleet-channel-freshness-gate --registry-only
HOST_TRACK_REGISTRY=/path/to/apps.json bin/last-stack-fleet-channel-freshness-gate --registry-only
```

**PASS evidence** (first line starts with `PASS`):

`~/.last-stack/feature-proofs/artifact-driven-host-track-fleet-gate.md`

Override with `--proof <path>` or `LAST_STACK_FLEET_CHANNEL_FRESHNESS_PROOF`.
Failure lines name **app + invariant code** (e.g. `situations: stale — …`).

**dogfood-registry maintain recipe (recommended):**

```text
recipe: last-stack-fleet-channel-freshness-gate
pass = exit 0 and proof file begins with PASS
isolation: host-local Host Track installs; never mutates primary brain
```

## Continuous Artifact Invariant

`bin/last-stack-host-track-artifact-invariant` is the live half of the fleet gate
(and remains callable alone). It inventories every registered app, rejects
non-artifact installs without a machine-readable exemption, checks the selected
channel and `stale:false`, verifies exact manifest source provenance, rehashes
active payload files, confirms command paths resolve inside immutable
`versions/<manifest>` directories, compares paired `lastdb` and `lastdbd` bundle
identity when both are registered, and proves rollback state by inspecting the
`previous` symlink without switching it.

```bash
bin/last-stack-host-track-artifact-invariant
bin/last-stack-host-track-artifact-invariant --json
HOST_TRACK_REGISTRY=/path/to/apps.json bin/last-stack-host-track-artifact-invariant
```

`bin/last-stack-artifact-host-track-proof` is the terminal proof wrapper for
the artifact-driven registry cutover. It runs Host Track status, the artifact
invariant, and `host-track check` for every registered app. On success it writes
`PASS` to
`~/.last-stack/feature-proofs/artifact-driven-host-track-registry-cutover.md`.
Prefer the **fleet channel freshness gate** for the composed fleet acceptance
check (registry policy + freshness + rollback). Run after refreshing promoted
artifacts when you need per-app `host-track check` as well:

```bash
host-track refresh --all
bin/last-stack-fleet-channel-freshness-gate
bin/last-stack-artifact-host-track-proof
```

Refresh stamps are written under `~/.host-track/stamps/<app>.json`, or under
`HOST_TRACK_STAMP_DIR` when set.

## Post-merge auto safe-upgrade

After a PR **merges to main** on GitHub, `last-stack-post-merge-safe-upgrade`
runs `host-track refresh <app>` so PATH tracks main without stuffing that into
CI. The GitHub `ci-required` and publish workflow builds the artifact;
`host-track refresh` pulls it with `last-stack-github-artifact-pull`.

### Re-sign on pull (routines, TCC identity)

A GitHub runner has no Developer ID identity, so the runner build of `routines`
is ad-hoc signed. macOS TCC would see a new code identity at each install and
block the routine command with a privacy prompt. `last-stack-github-artifact-pull`
therefore signs `dist/routines` on the Mac, before the file enters the CAS:

- Identifier `com.edgevector.routines`, identity `Developer ID Application`
  (override: `--sign-identity` or `LAST_STACK_SIGN_IDENTITY`; exactly one match).
- The designated requirement is `identifier` + Apple anchor + team OU. It does
  not change between builds, so TCC grants stay.
- The manifest holds the signed bytes. The result records the pre-sign sha256.
- No identity, a locked keychain, or a failed verify is a failure. The tool
  never promotes an ad-hoc `routines` binary.
- A channel entry at the same oid counts as current only when its signed files
  pass `codesign --verify` and show the identifier. An older unsigned entry is
  pulled again, signed, and promoted with a new manifest digest.
- Other apps: `--sign PATH=IDENTIFIER`. Test: `tests/last-stack-github-artifact-pull.sh`.

- **Script:** `last-stack-post-merge-safe-upgrade --all`
- **Supervisor:** none by default. LastGit's forge supervisor (retired
  2026-09-30) used to start it. Run it by hand or from a LaunchAgent you own.
- **Detects merges:** `gh pr list -R EdgeVector/<repo> --state merged --base main`
  for each mapped repo. The first pass only seeds the handled set.
- **Mapped apps:** last-stack / brain / situations / fkanban|kanban (app `kanban`) /
  routines / lastsecrets / configurations / remote / search / loom
- **Convergence:** a refresh right after a merge can hold while the publish job
  runs. Every 5 minutes the worker refreshes any mapped app that host-track
  reports stale or main-unpublished.
- **Failure:** log + retry (max 3); **does not unmerge**; operator can run
  `host-track refresh <app>` (artifact) or `last-stack-safe-upgrade-cli <app>`
  (local-safe) manually
- **State:** `~/.local/state/last-stack/post-merge-safe-upgrade/`

```bash
# map
last-stack-post-merge-safe-upgrade --map
# one poll pass (seed or catch-up)
last-stack-post-merge-safe-upgrade --once --all
```

## Local safe-upgrade (no cloud) — agent CLIs

For machine-local CI (Forgejo/LastGit on this Mac), you do **not** need to push
artifacts to Exemem/R2. Build a new immutable version, smoke it, then flip
`current` while keeping `previous` for rollback.

Layout (same shape as artifact installs):

```text
~/.host-track/apps/<app>/
  versions/<git-sha>/    # immutable built tree
  current  -> versions/<sha>
  previous -> versions/<old-sha>
~/.local/bin/<cmd> -> …/current/bin/<cmd>
```

### Tools

```bash
# Build from lastgit/bare cache tip, smoke, activate (PATH flip only after smoke)
last-stack-safe-upgrade-cli brain

# CI last step on a green main checkout (all local):
last-stack-safe-upgrade-cli brain --source-dir "$PWD"

# Status / rollback
last-stack-safe-activate-cli status --app brain
last-stack-safe-activate-cli rollback --app brain \
  --link "bin/brain:$HOME/.local/bin/brain"
```

Safe properties:

1. Smoke runs with `PATH=<new-version>/bin:…` **before** `current` moves.
2. `previous` always retains the last good version after a successful flip.
3. Install trees are not work surfaces — develop via portals + `wt start`.

`host-track refresh <app>` for agent CLIs with `install_mode=artifact` promotes stable via track_gate_main and installs the published build.
For **artifact** apps it promotes (when `track_gate_main`) and installs the
channel tip. LaunchAgent `com.edgevector.host-track-refresh` runs
`host-track refresh --all`, which also ticks `soak-watch --all` so a parked
canary promotes after its window without a second job.

**Artifact CLIs (producers live):** last-stack, remote, brain, situations,
kanban (shared `fkanban` install_root; public CLI is `kanban` only). See
`templates/host-track/README-artifact-producer.md`.

**Still local-safe (await producers):** routines, lastsecrets, configurations,
search.

```bash
# Upgrade artifact CLIs (examples)
host-track refresh routines
host-track refresh lastsecrets
# Legacy local-safe helper (only if an app is still local-safe):
last-stack-safe-upgrade-all-local

# One remaining local-safe app
last-stack-safe-upgrade-cli routines
last-stack-safe-upgrade-cli lastsecrets
```

**Special exemptions (not Host Track artifact refresh):** lastgit
(`bootstrap-recovery`), lastdb/lastdbd Mini (`deployment-only` — use
`lastdb-safe-upgrade` for the primary node).

## Refresh Agent

`./setup` installs a user LaunchAgent named
`com.edgevector.host-track-refresh`. The plist lives at
`~/.last-stack/launchd/com.edgevector.host-track-refresh.plist` and runs:

```bash
~/.local/bin/host-track refresh --all   # also runs soak-watch --all
```

The safety poll runs every 20 minutes. After a GREEN probe it parks `canary`
when `soak_hours > 0`. The same job re-probes those canaries; after the
window it flips `current`. When the registry has Forgejo-gated apps
with local host checkouts, setup also adds existing `<git-dir>/FETCH_HEAD` paths
as optional `WatchPaths`, so fetch activity can trigger the same refresh command
without one plist per app. The plist sets a tool-friendly PATH including
`~/.local/bin`, `~/.bun/bin`, Homebrew, and system directories.

The same poll resumes active `ship-soak` Loom executions for each app. The
registration lives under `~/.local/state/last-stack/soak-loom/ship-soak`.
It stores the app, key, execution ID, and status. It does not store graph
input. Each app tick resumes at most 32 active executions. A terminal
execution stays in the registry as inactive evidence.

Start a live run with an approved input file:

```bash
last-stack-ship-soak-loom \
  --app loom \
  --key host-track-soak-20260827 \
  --input-file /path/to/approved-ship-soak-input.json
```

The `heal-soak` graph uses the same Host Track poll. Its wait node records a
20-minute Loom timer. A repeated red tick resumes the same incident key and
keeps the three-attempt limit.

Uninstall removes the plist and boots out the loaded service:

```bash
~/.last-stack/setup --uninstall
```

## Registry Kinds

- `artifact-bundle`: install a verified immutable LastGit artifact and expose
  PATH links from its active `current` version.
- `A compile`: legacy checkout-era build and install flow.
- `B checkout-shim`: legacy checkout-era fast-forward and PATH shim flow.
- `C skill-pack`: refresh a skill-pack checkout and rerun its setup.
- `D daemon/cloud`: intentionally out of scope for this driver until a concrete
  app opts in.

The default registry is artifact-backed for `lastgit`, `last-stack`, `brain`,
`situations`, `kanban`, `lastdb`, and `lastdbd`. The public board CLI is
`kanban`; it installs from the `fkanban` artifact bundle. The `lastdb` and
`lastdbd` commands share the `lastdb-bundle` artifact so the invariant can
detect CLI/daemon source or manifest skew; live primary activation still goes
through `lastdb-safe-upgrade`.
