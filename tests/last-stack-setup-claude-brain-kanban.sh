#!/usr/bin/env bash
# setup --host claude must upsert the managed brain-kanban instructions block
# into ~/.claude/CLAUDE.md without clobbering user content, be idempotent
# across re-runs, and uninstall must remove the block while keeping user text.
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
mkdir -p "$HOME/.claude"
claude_md="$HOME/.claude/CLAUDE.md"
printf '## My own notes\nkeep me\n' > "$claude_md"

"$ROOT/setup" --host claude > "$tmp/setup1.out" 2>&1 || {
  cat "$tmp/setup1.out" >&2
  fail "setup --host claude exited non-zero"
}

# ── CLAUDE.md: managed block present, user content preserved ──────────────────
grep -q 'keep me' "$claude_md" || fail "user CLAUDE.md content was clobbered"
grep -q 'last-stack:brain-kanban:start' "$claude_md" || fail "managed block missing from CLAUDE.md"
grep -q 'New repository venue default: LastGit' "$claude_md" \
  || fail "LastGit new-repo default missing from CLAUDE.md"
grep -q 'brain ask' "$claude_md" || fail "CLI guidance missing from managed block"
grep -q 'folddb.sock' "$claude_md" || fail "transport guidance missing from managed block"
grep -q 'claude instructions: brain-kanban block' "$tmp/setup1.out" \
  || fail "setup did not log claude brain-kanban install"

# ── Idempotence: re-run changes nothing, block appears exactly once ───────────
cp "$claude_md" "$tmp/claude.before"
"$ROOT/setup" --host claude > /dev/null 2>&1 || fail "second setup run exited non-zero"
[ "$(grep -c 'last-stack:brain-kanban:start' "$claude_md")" -eq 1 ] \
  || fail "managed block duplicated on re-run"
cmp -s "$claude_md" "$tmp/claude.before" || fail "CLAUDE.md changed on re-run"

# ── Uninstall removes the managed block but keeps user content ────────────────
"$ROOT/setup" --uninstall > /dev/null 2>&1 || fail "uninstall exited non-zero"
grep -q 'keep me' "$claude_md" || fail "uninstall clobbered user CLAUDE.md content"
if grep -q 'last-stack:brain-kanban:start' "$claude_md"; then
  fail "uninstall left the managed block in CLAUDE.md"
fi

echo "ok: setup wires claude brain/kanban instructions idempotently"
