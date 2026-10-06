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
grep -q 'last-stack:asd-ste100:start' "$claude_md" || fail "asd-ste100 block missing from CLAUDE.md"
grep -q 'Write to the user in ASD-STE100' "$claude_md" || fail "ASD-STE100 rule missing from CLAUDE.md"
grep -q 'last-stack:user-vocabulary:start' "$claude_md" || fail "user-vocabulary block missing from CLAUDE.md"
grep -q 'last-stack-vocab add' "$claude_md" || fail "user vocabulary add command missing from CLAUDE.md"
grep -q 'Do not invent a word' "$claude_md" || fail "user vocabulary rule missing from CLAUDE.md"
ste_end_line="$(grep -n 'last-stack:asd-ste100:end' "$claude_md" | head -1 | cut -d: -f1)"
tv_start_line="$(grep -n 'last-stack:user-vocabulary:start' "$claude_md" | head -1 | cut -d: -f1)"
[ -n "$ste_end_line" ] && [ -n "$tv_start_line" ] && [ "$tv_start_line" -gt "$ste_end_line" ] \
  || fail "user-vocabulary block does not follow the asd-ste100 block"
grep -q 'Repository venue: GitHub' "$claude_md" \
  || fail "GitHub repo venue section missing from CLAUDE.md"
grep -q 'brain ask' "$claude_md" || fail "CLI guidance missing from managed block"
grep -q 'folddb.sock' "$claude_md" || fail "transport guidance missing from managed block"
grep -q 'kanban ping' "$claude_md" || fail "socket health check guidance missing from managed block"
grep -q 'lastdb status' "$claude_md" || fail "lastdb status health check missing from managed block"
if grep -q 'TCP-only' "$claude_md"; then
  fail "managed block still calls doctor TCP-only; use lastdb status / kanban ping"
fi
grep -q 'claude instructions: brain-kanban + asd-ste100' "$tmp/setup1.out" \
  || fail "setup did not log claude brain-kanban + asd-ste100 install"

# ── Idempotence: re-run changes nothing, block appears exactly once ───────────
cp "$claude_md" "$tmp/claude.before"
"$ROOT/setup" --host claude > /dev/null 2>&1 || fail "second setup run exited non-zero"
[ "$(grep -c 'last-stack:brain-kanban:start' "$claude_md")" -eq 1 ] \
  || fail "managed block duplicated on re-run"
[ "$(grep -c 'last-stack:asd-ste100:start' "$claude_md")" -eq 1 ] \
  || fail "asd-ste100 block duplicated on re-run"
[ "$(grep -c 'last-stack:user-vocabulary:start' "$claude_md")" -eq 1 ] \
  || fail "user-vocabulary block duplicated on re-run"
cmp -s "$claude_md" "$tmp/claude.before" || fail "CLAUDE.md changed on re-run"

# ── Uninstall removes the managed block but keeps user content ────────────────
"$ROOT/setup" --uninstall > /dev/null 2>&1 || fail "uninstall exited non-zero"
grep -q 'keep me' "$claude_md" || fail "uninstall clobbered user CLAUDE.md content"
if grep -q 'last-stack:brain-kanban:start' "$claude_md"; then
  fail "uninstall left the managed block in CLAUDE.md"
fi
if grep -q 'last-stack:asd-ste100:start' "$claude_md"; then
  fail "uninstall left the asd-ste100 block in CLAUDE.md"
fi
if grep -q 'last-stack:user-vocabulary:start' "$claude_md"; then
  fail "uninstall left the user-vocabulary block in CLAUDE.md"
fi
if grep -q 'last-stack:tom-vocabulary:start' "$claude_md"; then
  fail "uninstall left the tom-vocabulary block in CLAUDE.md"
fi

echo "ok: setup wires claude brain/kanban instructions idempotently"
