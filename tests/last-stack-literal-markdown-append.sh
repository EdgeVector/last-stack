#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fake_bin="$tmp/bin"
mkdir -p "$fake_bin"

cat >"$fake_bin/brain" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$TEST_ARGS_LOG"
cat >"$TEST_BODY_LOG"
SH

cat >"$fake_bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >"$TEST_KANBAN_ARGS_LOG"
[ "$1" = "add" ] || { echo "expected kanban add" >&2; exit 2; }
shift 2
body_file=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --body-file)
      body_file="$2"
      shift 2
      ;;
    --body-file=*)
      body_file="${1#*=}"
      shift
      ;;
    *)
      shift
      ;;
  esac
done
[ -n "$body_file" ] || { echo "missing --body-file" >&2; exit 2; }
cat "$body_file" >"$TEST_KANBAN_BODY_LOG"
SH

cat >"$fake_bin/routine_heredoc_canary" <<'SH'
#!/usr/bin/env bash
printf 'spawned\n' >>"$TEST_SPAWN_LOG"
SH

chmod +x "$fake_bin/brain" "$fake_bin/kanban" "$fake_bin/routine_heredoc_canary"

body="$tmp/body.md"
cat >"$body" <<'BODY'
Markdown keeps `papercut-demo-slug` as text.
Command substitution stays literal: $(routine_heredoc_canary)
Dollar variables stay literal: $HOME and ${ROUTINES_RUN_ID:-unset}
BODY

export TEST_ARGS_LOG="$tmp/brain.args"
export TEST_BODY_LOG="$tmp/brain.body"
export TEST_KANBAN_ARGS_LOG="$tmp/kanban.args"
export TEST_KANBAN_BODY_LOG="$tmp/kanban.body"
export TEST_SPAWN_LOG="$tmp/spawn.log"
export LAST_STACK_BRAIN_CMD="$fake_bin/brain"
export LAST_STACK_KANBAN_CMD="$fake_bin/kanban"
export PATH="$fake_bin:/usr/bin:/bin"

"$ROOT/bin/last-stack-literal-markdown-append" brain \
  --slug papercut-routine-brain-append-unquoted-heredoc-executes-markdown \
  --type reference \
  --body-file "$body"

printf '%s\n' 'append papercut-routine-brain-append-unquoted-heredoc-executes-markdown --type reference' >"$tmp/expected-brain.args"
cmp "$tmp/expected-brain.args" "$TEST_ARGS_LOG"
cmp "$body" "$TEST_BODY_LOG"

"$ROOT/bin/last-stack-literal-markdown-append" kanban \
  --slug routine-shell-quoting-fixture \
  --body-file "$body" \
  -- --title "Routine shell quoting fixture" --column todo

grep -q '^add routine-shell-quoting-fixture --body-file ' "$TEST_KANBAN_ARGS_LOG"
grep -q -- '--title Routine shell quoting fixture --column todo' "$TEST_KANBAN_ARGS_LOG"
cmp "$body" "$TEST_KANBAN_BODY_LOG"

if [ -s "$TEST_SPAWN_LOG" ]; then
  echo "literal Markdown helper executed body command substitutions" >&2
  exit 1
fi

printf 'ok last-stack-literal-markdown-append\n'
