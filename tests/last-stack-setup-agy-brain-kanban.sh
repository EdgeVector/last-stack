#!/usr/bin/env bash
# setup --host agy must (1) register skills into ~/.gemini/config/skills,
# (2) upsert the managed brain-kanban block into both GEMINI.md files without
# clobbering user content, (3) register brain/kanban in mcp_config.json with a
# PATH env, (4) be idempotent, and (5) uninstall the skills + instruction
# blocks. --host auto must detect agy via PATH / ~/.local/bin/agy /
# ~/.gemini/antigravity-cli, and must NOT treat ~/.gemini/config alone as agy.
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

export LAST_STACK_SKIP_ROUTINES_INSTALL=1

# ── Explicit --host agy: skills, GEMINI.md, MCP, uninstall ────────────────────
export HOME="$tmp/home-agy"
mkdir -p "$HOME/.gemini/config" "$HOME/.local/bin" "$HOME/.bun/bin"
printf '{}\n' > "$HOME/.gemini/GEMINI.md"
printf 'keep me\n' > "$HOME/.gemini/config/GEMINI.md"
# Empty mcp_config.json is invalid JSON; setup must heal it.
: > "$HOME/.gemini/config/mcp_config.json"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/brain-mcp"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/kanban"
chmod +x "$HOME/.local/bin/brain-mcp" "$HOME/.local/bin/kanban"

"$ROOT/setup" --host agy > "$tmp/setup1.out" 2>&1 || {
  cat "$tmp/setup1.out" >&2
  fail "setup --host agy exited non-zero"
}

test -f "$HOME/.gemini/config/skills/kanban/SKILL.md" \
  || fail "agy skills were not registered under ~/.gemini/config/skills"
test -f "$HOME/.gemini/config/skills/lastdb-safe-upgrade/SKILL.md" \
  || fail "lastdb-safe-upgrade skill missing from agy skills dir"
test -e "$HOME/.gemini/config/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh" \
  || fail "agy skill sidecars were not mirrored"

grep -q 'keep me' "$HOME/.gemini/config/GEMINI.md" \
  || fail "user GEMINI.md content was clobbered"
grep -q 'last-stack:brain-kanban:start' "$HOME/.gemini/GEMINI.md" \
  || fail "managed block missing from ~/.gemini/GEMINI.md"
grep -q 'last-stack:brain-kanban:start' "$HOME/.gemini/config/GEMINI.md" \
  || fail "managed block missing from ~/.gemini/config/GEMINI.md"
grep -q 'agy instructions: brain-kanban block' "$tmp/setup1.out" \
  || fail "setup did not log agy brain-kanban install"

jq -e '.mcpServers.brain.command | test("brain-mcp$")' "$HOME/.gemini/config/mcp_config.json" >/dev/null \
  || fail "brain MCP was not registered as brain-mcp"
jq -e '.mcpServers.kanban.args == ["mcp"]' "$HOME/.gemini/config/mcp_config.json" >/dev/null \
  || fail "kanban MCP args missing"
jq -e --arg bun "$HOME/.bun/bin" '.mcpServers.brain.env.PATH | contains($bun)' \
  "$HOME/.gemini/config/mcp_config.json" >/dev/null \
  || fail "agy MCP PATH does not include ~/.bun/bin"

cp "$HOME/.gemini/config/mcp_config.json" "$tmp/mcp.before"
cp "$HOME/.gemini/GEMINI.md" "$tmp/gemini.before"
"$ROOT/setup" --host agy > /dev/null 2>&1 || fail "second setup --host agy exited non-zero"
[ "$(grep -c 'last-stack:brain-kanban:start' "$HOME/.gemini/GEMINI.md")" -eq 1 ] \
  || fail "managed block duplicated on re-run"
cmp -s "$HOME/.gemini/config/mcp_config.json" "$tmp/mcp.before" \
  || fail "mcp_config.json changed on re-run"
cmp -s "$HOME/.gemini/GEMINI.md" "$tmp/gemini.before" \
  || fail "GEMINI.md changed on re-run"

"$ROOT/setup" --uninstall > /dev/null 2>&1 || fail "uninstall exited non-zero"
if [ -e "$HOME/.gemini/config/skills/kanban/SKILL.md" ]; then
  fail "uninstall left agy skill links"
fi
if grep -q 'last-stack:brain-kanban:start' "$HOME/.gemini/GEMINI.md"; then
  fail "uninstall left the managed block in ~/.gemini/GEMINI.md"
fi
grep -q 'keep me' "$HOME/.gemini/config/GEMINI.md" \
  || fail "uninstall clobbered user GEMINI.md content"
jq -e '.mcpServers.brain.command' "$HOME/.gemini/config/mcp_config.json" >/dev/null \
  || fail "uninstall removed agy MCP entries (should keep them)"

# ── --host auto: agy on PATH, no other harness → agy only ─────────────────────
export HOME="$tmp/home-auto-agy"
mkdir -p "$HOME/bin" "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/bin/agy"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/brain-mcp"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/kanban"
chmod +x "$HOME/bin/agy" "$HOME/.local/bin/brain-mcp" "$HOME/.local/bin/kanban"
PATH="$HOME/bin:/usr/bin:/bin"
export PATH

"$ROOT/setup" --host auto > "$tmp/setup-auto.out" 2>&1 || {
  cat "$tmp/setup-auto.out" >&2
  fail "setup --host auto with agy on PATH exited non-zero"
}
test -f "$HOME/.gemini/config/skills/kanban/SKILL.md" \
  || fail "auto-detect did not register agy skills"
if [ -d "$HOME/.claude/skills" ]; then
  fail "auto-detect with agy present still defaulted to claude"
fi

# ── --host auto: ~/.gemini/config alone is NOT agy ────────────────────────────
export HOME="$tmp/home-gemini-config-only"
mkdir -p "$HOME/.gemini/config"
PATH="/usr/bin:/bin"
export PATH

"$ROOT/setup" --host auto > "$tmp/setup-gemini-only.out" 2>&1 || {
  cat "$tmp/setup-gemini-only.out" >&2
  fail "setup --host auto with only ~/.gemini/config exited non-zero"
}
if [ -d "$HOME/.gemini/config/skills" ]; then
  fail "~/.gemini/config alone was treated as agy"
fi
test -d "$HOME/.claude/skills" \
  || fail "no-harness auto did not fall back to claude"

# ── --host auto: ~/.gemini/antigravity-cli without agy on PATH ────────────────
export HOME="$tmp/home-antigravity-cli"
mkdir -p "$HOME/.gemini/antigravity-cli" "$HOME/.local/bin"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/brain-mcp"
printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/kanban"
chmod +x "$HOME/.local/bin/brain-mcp" "$HOME/.local/bin/kanban"
PATH="/usr/bin:/bin"
export PATH

"$ROOT/setup" --host auto > "$tmp/setup-cli-dir.out" 2>&1 || {
  cat "$tmp/setup-cli-dir.out" >&2
  fail "setup --host auto with antigravity-cli dir exited non-zero"
}
test -f "$HOME/.gemini/config/skills/kanban/SKILL.md" \
  || fail "antigravity-cli dir did not count as agy"

echo "ok: setup wires agy skills, GEMINI.md, and MCP; auto-detects only a real agy"
