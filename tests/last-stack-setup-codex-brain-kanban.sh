#!/usr/bin/env bash
# setup --host codex must (1) upsert the managed brain-kanban instructions
# block into ~/.codex/AGENTS.md without clobbering user content, (2) register
# the brain/kanban MCP servers in ~/.codex/config.toml with a PATH env that
# includes ~/.bun/bin (GUI-spawned servers otherwise exit 127), and (3) be
# idempotent across re-runs. Uninstall must remove the instructions block.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

export HOME="$tmp/home"
mkdir -p "$HOME/.codex" "$HOME/.bun/bin" "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.bun/bin/brain"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/kanban"
chmod +x "$HOME/.bun/bin/brain" "$HOME/.local/bin/kanban"

agents="$HOME/.codex/AGENTS.md"
cfg="$HOME/.codex/config.toml"
printf '## My own notes\nkeep me\n' > "$agents"

"$ROOT/setup" --host codex > "$tmp/setup1.out" 2>&1 || {
  cat "$tmp/setup1.out" >&2
  fail "setup --host codex exited non-zero"
}

# ── AGENTS.md: managed block present, user content preserved ──────────────────
grep -q 'keep me' "$agents" || fail "user AGENTS.md content was clobbered"
grep -q 'last-stack:brain-kanban:start' "$agents" || fail "managed block missing from AGENTS.md"
grep -q 'New repository venue default: LastGit' "$agents" || fail "LastGit new-repo default missing from AGENTS.md"
grep -q 'brain ask' "$agents" || fail "CLI guidance missing from managed block"
grep -q 'folddb.sock' "$agents" || fail "transport guidance missing from managed block"
grep -q 'Git commits from isolated worktrees' "$agents" \
  || fail "isolated worktree commit guidance missing from managed block"
grep -q 'Never run `git add -A` or `git add .` in a shared checkout' "$agents" \
  || fail "shared-checkout git add prohibition missing from managed block"
grep -q 'whole worktree with `git add -A`' "$agents" \
  || fail "isolated worktree git add guidance missing from managed block"

# ── config.toml: both servers registered, env PATH includes ~/.bun/bin ────────
grep -q '^\[mcp_servers\.brain\]' "$cfg" || fail "brain MCP server not registered"
grep -q '^\[mcp_servers\.brain\.env\]' "$cfg" || fail "brain env table missing"
grep -q '^\[mcp_servers\.kanban\]' "$cfg" || fail "kanban MCP server not registered"
grep -q '^\[mcp_servers\.kanban\.env\]' "$cfg" || fail "kanban env table missing"
grep -q "$HOME/.bun/bin" "$cfg" || fail "PATH env does not include ~/.bun/bin"

# ── Idempotence: re-run changes nothing, block appears exactly once ───────────
cp "$cfg" "$tmp/cfg.before"
cp "$agents" "$tmp/agents.before"
"$ROOT/setup" --host codex > /dev/null 2>&1 || fail "second setup run exited non-zero"
[ "$(grep -c 'last-stack:brain-kanban:start' "$agents")" -eq 1 ] \
  || fail "managed block duplicated on re-run"
cmp -s "$cfg" "$tmp/cfg.before" || fail "config.toml changed on re-run"
cmp -s "$agents" "$tmp/agents.before" || fail "AGENTS.md changed on re-run"

# ── Pre-existing server entry without env: only the env table is appended ─────
{
  echo '[mcp_servers.brain]'
  echo 'args = ["mcp"]'
  echo "command = \"$HOME/.bun/bin/brain\""
  echo 'startup_timeout_sec = 120'
  echo ''
  echo '[mcp_servers.brain.tools.brain_put]'
  echo 'approval_mode = "approve"'
} > "$cfg"
"$ROOT/setup" --host codex > /dev/null 2>&1 || fail "setup over pre-existing config exited non-zero"
[ "$(grep -c '^\[mcp_servers\.brain\]' "$cfg")" -eq 1 ] \
  || fail "brain server block duplicated over pre-existing entry"
grep -q '^\[mcp_servers\.brain\.env\]' "$cfg" || fail "env table not added to pre-existing entry"
grep -q 'approval_mode = "approve"' "$cfg" || fail "pre-existing tool config was lost"

# ── Missing CLIs: setup still succeeds and skips MCP registration ─────────────
rm -f "$HOME/.bun/bin/brain" "$HOME/.local/bin/kanban" "$cfg"
# Bare PATH so a real brain/kanban on the developer's machine isn't found.
env PATH="/usr/bin:/bin" "$ROOT/setup" --host codex > "$tmp/setup4.out" 2>&1 || {
  cat "$tmp/setup4.out" >&2
  fail "setup without brain/kanban CLIs exited non-zero"
}
if grep -q '^\[mcp_servers\.brain\]' "$cfg" 2>/dev/null; then
  fail "registered brain MCP server despite missing CLI"
fi

# ── Uninstall removes the managed block but keeps user content ────────────────
"$ROOT/setup" --uninstall > /dev/null 2>&1 || fail "uninstall exited non-zero"
grep -q 'keep me' "$agents" || fail "uninstall clobbered user AGENTS.md content"
if grep -q 'last-stack:brain-kanban:start' "$agents"; then
  fail "uninstall left the managed block in AGENTS.md"
fi

echo "ok: setup wires codex brain/kanban instructions + MCP idempotently"
