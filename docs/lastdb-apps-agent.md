# LastDB Apps Agent Setup

This page is for AI coding agents that need to install or verify the LastDB app
stack for a user. It is intentionally separate from the human getting-started
guide so an agent can land here directly and follow a short, machine-oriented
path.

Agent-readable static HTML copy: [`lastdb-apps-agent.html`](lastdb-apps-agent.html).
Use that version when your browser/tooling reports a blank page or only sees a
JavaScript shell.

## Goal

Install LastDB plus the app tools that make the local brain/board workflow work:

- LastDB daemon
- Brain (`fbrain`)
- Kanban (`fkanban`)
- Situations (`fsituations`)
- Dogfood Graph
- LastSecrets

LastGit is intentionally not part of this public app bundle yet.

## Preconditions

1. You are allowed to install developer tools for the user.
2. Homebrew is available on macOS if you want the daemon installed
   automatically.
3. Bun is available or can be installed before app dependency installation.
4. You are not handling raw secrets. If secrets are needed, store and retrieve
   them through LastSecrets, never through chat or shell history.

## Install

Run:

```bash
git clone https://github.com/EdgeVector/last-stack ~/.last-stack
~/.last-stack/setup
~/.last-stack/bin/last-stack-install-apps
```

The installer downloads app repos under `~/lastdb-apps` by default, installs the
LastDB daemon with Homebrew, runs app dependency installs, and links supported
CLI commands.

Use a custom app directory:

```bash
~/.last-stack/bin/last-stack-install-apps --dir ~/src/lastdb-apps
```

Skip Homebrew when LastDB is already installed:

```bash
~/.last-stack/bin/last-stack-install-apps --no-brew
```

Skip command linking when you only need checkouts:

```bash
~/.last-stack/bin/last-stack-install-apps --no-link
```

## Start LastDB

```bash
brew services start lastdb
```

If Homebrew services are unavailable, start the daemon using the local LastDB
daemon command available in that installation. Do not assume the retired
`http://127.0.0.1:9001` TCP endpoint is the health check for the modern
brain/kanban tools.

## Initialize Apps

```bash
fbrain init --grant-consent  # setup Brain
fkanban init                 # setup Kanban
fsituations init
lastsecrets init
```

Then verify the app layer with socket-backed reads:

```bash
fkanban list
fbrain get routine-heartbeats --type reference
```

`fkanban list` succeeding means the LastDB-backed board path is reachable. Do
not run `fbrain doctor`, `fkanban doctor`, or `fkanban init` as routine health
checks just because `:9001` is refused; those control-plane paths may still
exercise stale TCP assumptions.

## Run Dogfood Graph

```bash
cd ~/lastdb-apps/dogfood-graph
npm run dev
```

## Path Fix

If linked commands are not found, make sure Bun and local user binaries are on
the shell path:

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

## If The Web Page Looks Blank

Report the actual observation: "The browser-visible page is blank" or "the
initial HTML only contains a JavaScript shell." Do not claim the underlying
setup data is unreadable until you have tried one of these source paths:

```bash
curl -fsSL https://raw.githubusercontent.com/EdgeVector/last-stack/main/docs/lastdb-apps-agent.md
curl -fsSL https://raw.githubusercontent.com/EdgeVector/last-stack/main/docs/lastdb-apps-agent.html
```

The HTML version is intentionally self-contained so agents and crawlers can read
the setup steps without executing JavaScript or waiting for JSON-loaded content.
