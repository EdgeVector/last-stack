# LastDB App Stack

This is the practical download path for the LastDB tools Tom is actively
dogfooding and considers usable for other people to try.

Included:

- **LastDB**: the local daemon installed from the `edgevector/lastdb` Homebrew
  tap.
- **Brain (`fbrain`)**: durable notes, decisions, references, and retrieval over
  LastDB.
- **Kanban (`fkanban`)**: board and work-state tracking over LastDB.
- **Situations (`fsituations`)**: active operational posture and preflight
  checks for agents.
- **Dogfood Graph**: LastDB-native manual dogfood planning and evidence.
- **LastSecrets**: local secret references backed by LastDB, with raw values kept
  out of normal search surfaces.

Not included:

- **LastGit**: intentionally left out until it is stable enough for this bundle.

## One Command

Install Last Stack first, then install the app bundle:

```bash
git clone https://github.com/EdgeVector/last-stack ~/.last-stack
~/.last-stack/setup
~/.last-stack/bin/last-stack-install-apps
```

By default the installer:

- installs the LastDB daemon with Homebrew;
- clones the app repos under `~/lastdb-apps`;
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

Initialize the apps you want to use:

```bash
fbrain init --grant-consent   # setup Brain
fkanban init                  # setup Kanban
fsituations init
lastsecrets init
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
git clone https://github.com/EdgeVector/fbrain.git
git clone https://github.com/EdgeVector/fkanban.git
git clone https://github.com/EdgeVector/fsituations.git
git clone https://github.com/EdgeVector/dogfood-graph.git
git clone https://github.com/EdgeVector/lastsecrets.git
```

Install dependencies:

```bash
for app in fbrain fkanban fsituations dogfood-graph lastsecrets; do
  bun install --cwd "$HOME/lastdb-apps/$app"
done
```

Link commands:

```bash
cd ~/lastdb-apps/fbrain && bun link
cd ~/lastdb-apps/fkanban && bun run install-cli
ln -snf ~/lastdb-apps/fsituations/bin/fsituations ~/.local/bin/fsituations
cd ~/lastdb-apps/lastsecrets && bun link
```

Dogfood Graph is a web app rather than a global CLI; run it from its checkout.
