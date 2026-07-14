# LastDB App Stack

This is the practical download path for the LastDB tools Tom is actively
dogfooding and considers usable for other people to try — including **invite
recipients** who need Org + LastSecrets to join an organization.

Included (all **public** on GitHub):

- **LastDB**: the local daemon installed from the `edgevector/lastdb` Homebrew
  tap.
- **Brain (`brain`)**: durable notes, decisions, references, and retrieval over
  LastDB.
- **Kanban (`kanban`)**: board and work-state tracking over LastDB (repo
  `EdgeVector/fkanban`).
- **Situations (`situations`)**: active operational posture and preflight
  checks for agents.
- **Dogfood Graph**: LastDB-native manual dogfood planning and evidence.
- **Org (`org`)**: org membership, shared org databases, invite/join. Public
  install source: `https://github.com/EdgeVector/org`.
- **LastSecrets (`lastsecrets`)**: local secret references backed by LastDB
  (raw values never in search indexes). Required by Org for E2E keys. Public
  install source: `https://github.com/EdgeVector/lastsecrets`.

Not included in this bundle:

- **LastGit**: review/CI venue for EdgeVector contributors (not required for a
  cold invitee install of the app CLIs).

## One Command

Install Last Stack first, then install the app bundle:

```bash
git clone https://github.com/EdgeVector/last-stack ~/.last-stack
~/.last-stack/setup
~/.last-stack/bin/last-stack-install-apps
```

By default the installer:

- installs the LastDB daemon with Homebrew;
- clones the public app repos under `~/lastdb-apps`;
- runs `bun install` in each app repo;
- links the CLI apps where they expose a command.

Use a different app directory:

```bash
~/.last-stack/bin/last-stack-install-apps --dir ~/src/lastdb-apps
```

Skip Homebrew if LastDB is already installed:

```bash
~/.last-stack/bin/last-stack-install-apps --no-brew
```

Skip linking CLIs if you only want the checkouts:

```bash
~/.last-stack/bin/last-stack-install-apps --no-link
```

## After Downloading

Start LastDB:

```bash
brew services start lastdb
```

Initialize the apps:

```bash
# first-run setup (not a health check — run once after brew services start lastdb)
brain init --grant-consent   # bootstrap Brain
kanban init                  # bootstrap Kanban
situations init              # bootstrap Situations
lastsecrets init             # bootstrap LastSecrets (needed for org keys)
org init                     # bootstrap Org (invite/join)
```

Join someone's org (after they send an invite file):

```bash
org join --from ~/Downloads/something.invite.json
```

Run Dogfood Graph locally:

```bash
cd ~/lastdb-apps/dogfood-graph
npm run dev
```

If a linked command is not found, make sure Bun and local user binaries are on
your shell path:

```bash
export PATH="$HOME/.bun/bin:$HOME/.local/bin:$PATH"
```

## Manual Install

Install the daemon:

```bash
brew install edgevector/lastdb/lastdb
brew services start lastdb
```

Download the app repos:

```bash
mkdir -p ~/lastdb-apps
cd ~/lastdb-apps
git clone https://github.com/EdgeVector/brain.git
git clone https://github.com/EdgeVector/fkanban.git kanban
git clone https://github.com/EdgeVector/situations.git
git clone https://github.com/EdgeVector/dogfood-graph.git
git clone https://github.com/EdgeVector/org.git
git clone https://github.com/EdgeVector/lastsecrets.git
```

Install dependencies:

```bash
for app in brain kanban situations dogfood-graph org lastsecrets; do
  bun install --cwd "$HOME/lastdb-apps/$app"
done
```

Link commands:

```bash
cd ~/lastdb-apps/brain && bun link
cd ~/lastdb-apps/kanban && bun run install-cli
ln -snf ~/lastdb-apps/situations/bin/situations ~/.local/bin/situations
cd ~/lastdb-apps/org && bun link
cd ~/lastdb-apps/lastsecrets && bun link
```

Dogfood Graph is a web app rather than a global CLI; run it from its checkout.
