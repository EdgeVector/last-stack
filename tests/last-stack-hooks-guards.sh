#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

# read-before-edit.sh is retired (2026-07-28): its deny ended the whole turn
# and froze unattended runs. Setup must not ship it, and must actively strip
# any registration a previous install left behind — a setup run on 2026-07-29
# silently re-armed it once already.
if [ -e "$ROOT/hooks/read-before-edit.sh" ]; then
  echo "hooks/read-before-edit.sh is retired and must not return to the repo" >&2
  exit 1
fi
if grep -q "upsert_pretool_hook.*read-before-edit" "$ROOT/setup"; then
  echo "setup must not register read-before-edit.sh" >&2
  exit 1
fi

# The de-registration must remove read-before-edit entries from an armed
# settings.json while leaving every other hook untouched.
eval "$(sed -n '/^remove_pretool_hook_by_script()/,/^}/p' "$ROOT/setup")"
settings_fixture="$tmp/settings.json"
jq -n '{hooks: {PreToolUse: [
  {matcher: "Bash", hooks: [
    {type: "command", command: "/x/hooks/unsafe-inline-json.sh  # keep me", timeout: 5}
  ]},
  {matcher: "Edit", hooks: [
    {type: "command", command: "/x/hooks/read-before-edit.sh  # retired", timeout: 10}
  ]},
  {matcher: "Write", hooks: [
    {type: "command", command: "/x/hooks/read-before-edit.sh  # retired", timeout: 10},
    {type: "command", command: "/x/hooks/other-guard.sh  # keep me too", timeout: 10}
  ]}
]}}' > "$settings_fixture"
remove_pretool_hook_by_script "$settings_fixture" "read-before-edit.sh"
jq -e '[.. | strings | select(test("read-before-edit"))] | length == 0' "$settings_fixture" >/dev/null
jq -e '.hooks.PreToolUse | length == 2' "$settings_fixture" >/dev/null
jq -e '.hooks.PreToolUse[0].matcher == "Bash" and (.hooks.PreToolUse[0].hooks | length == 1)' "$settings_fixture" >/dev/null
jq -e '.hooks.PreToolUse[1].matcher == "Write" and .hooks.PreToolUse[1].hooks[0].command == "/x/hooks/other-guard.sh  # keep me too"' "$settings_fixture" >/dev/null

# Settings with no PreToolUse hooks must pass through unchanged.
jq -n '{model: "fable"}' > "$settings_fixture"
remove_pretool_hook_by_script "$settings_fixture" "read-before-edit.sh"
jq -e '. == {model: "fable"}' "$settings_fixture" >/dev/null

hook_out() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' \
    | "$ROOT/hooks/unsafe-inline-json.sh"
}

assert_deny() {
  local out
  out="$(hook_out "$1")"
  if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf 'expected DENY (%s), got: %s\n' "$2" "$out" >&2
    exit 1
  fi
}

assert_allow() {
  local out
  out="$(hook_out "$1")"
  if [ -n "$out" ]; then
    printf 'expected ALLOW (%s), got: %s\n' "$2" "$out" >&2
    exit 1
  fi
}

# Guard hooks deny via permissionDecision JSON with exit 0 — a deny must
# reject the tool call WITHOUT ending the turn (no continue:false, no exit 1);
# blocking denies froze unattended runs mid-task (2026-07-18 and 2026-07-29).
deny_out="$(jq -n '{
  tool_name: "Bash",
  tool_input: {command: "node -e \"const d=JSON.parse(process.argv[1]); console.log(d.x)\" \"$json\""}
}' | "$ROOT/hooks/unsafe-inline-json.sh")"
printf '%s' "$deny_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
printf '%s' "$deny_out" | jq -e '(.continue // true) == true' >/dev/null
printf '%s' "$deny_out" | grep -q 'use jq'
printf '%s' "$deny_out" | grep -q 'scratchpad'
printf '%s' "$deny_out" | grep -q 'last-stack-json-get'

allow_out="$(jq -n '{
  tool_name: "Bash",
  tool_input: {command: "jq -r .x data.json"}
}' | "$ROOT/hooks/unsafe-inline-json.sh")"
[ -z "$allow_out" ]

allow_out="$(jq -n '{
  tool_name: "Bash",
  tool_input: {command: "curl --unix-socket ~/.folddb/data/folddb.sock http://localhost/api/system/auto-identity | last-stack-json-get .app_id"}
}' | "$ROOT/hooks/unsafe-inline-json.sh")"
[ -z "$allow_out" ]

# Machine-readable stdout must not absorb stderr before a JSON parser. A
# warning at byte 1 otherwise makes jq fail with "Invalid numeric literal".
deny_out="$(jq -n '{
  tool_name: "Bash",
  tool_input: {command: "kanban show example --json 2>&1 | jq ."}
}' | "$ROOT/hooks/unsafe-inline-json.sh")"
printf '%s' "$deny_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
printf '%s' "$deny_out" | grep -q 'Keep the streams separate'

deny_out="$(jq -n '{
  tool_name: "Bash",
  tool_input: {command: "kanban list --json >cards.json 2>&1; jq . cards.json"}
}' | "$ROOT/hooks/unsafe-inline-json.sh")"
printf '%s' "$deny_out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null

allow_out="$(jq -n '{
  tool_name: "Bash",
  tool_input: {command: "kanban show example --json >card.json 2>card.err; jq . card.json"}
}' | "$ROOT/hooks/unsafe-inline-json.sh")"
[ -z "$allow_out" ]

# ── merged-stream guard is statement-scoped ─────────────────────────────────
# It used to AND three greps over the whole tool input, so an unrelated redirect
# anywhere denied a safe script: 97 distinct denials in one 24h fleet window.
# Card hook-unsafe-inline-json-merged-stderr-false-positive-whole-command-scan.

# The deny must cite what it matched. A guard that only names the hazard leaves
# its own false positives undiagnosable.
deny_out="$(hook_out "kanban show example --json 2>&1 | jq .")"
printf '%s' "$deny_out" | grep -q 'Matched statement: kanban show example --json'
printf '%s' "$deny_out" | grep -q 'json-guard-ok'

# papercut-agent-tooling-json-stderr-guard-matches-a-redirect-on-a-different-command,
# false positive 1: the redirect belongs to a different command, and the file
# the parser reads was written by an earlier one. >/dev/null 2>&1 has no
# consumer at all — it is the one unconditionally safe merge form.
assert_allow \
  "brain papercut list lastdb --json > /dev/null 2>&1; cd \"\$scratch\"; jq -r '.x' pc-lastdb.json" \
  "merged redirect on a different command than the parsed file"

# Same papercut, false positive 2 / papercut-claude-unsafe-inline-json-hook-
# matches-prose-not-shell-syntax: writing ABOUT the guard tripped the guard, so
# its own defects could not be filed. Heredoc bodies are documents, not syntax.
prose_cmd="$(cat <<'CMD'
brain papercut file papercut-example --component agent-tooling --body "$(cat <<'PC'
The guard ANDs three greps: it looks for --json, then for a 2>&1 or &> merge,
then for jq downstream. Prose that names all three denies the filing.
PC
)"
CMD
)"
assert_allow "$prose_cmd" "heredoc body describing the guard"

# The same tokens inside a quoted argument are data, not shell syntax.
assert_allow \
  "kanban add demo-slug --title t --body \"run cmd --json 2>&1 | jq . and it fails\"" \
  "trigger tokens inside a quoted --body argument"

# The multi-line health-check block CLAUDE.md tells every agent to run first:
# one command silenced with a merged redirect, one JSON write with stderr
# correctly separated, and a later parse of that file.
health_cmd="$(cat <<'CMD'
last_stack="${LAST_STACK_ROOT:-$HOME/.last-stack}"
. "$last_stack/bin/last-stack-shell-prelude" 2>&1 | tail -3
situations list --json >/tmp/sit.json 2>/tmp/sit.err
kanban ping --json >/tmp/ping.json 2>/tmp/ping.err
jq -r '.[].slug' /tmp/sit.json
CMD
)"
assert_allow "$health_cmd" "health-check block with an unrelated merged redirect"

# A merged stream with no parser downstream is not this hazard.
assert_allow "situations list --json 2>&1 | head -40" "merged JSON piped to head"

# Order still matters: stdout to /dev/null leaves the merged stderr on the pipe.
assert_deny "cmd --json 2>&1 >/dev/null | jq ." "merged stderr reaches the parser"

# &> is the same merge, and a file consumer is still a consumer.
assert_deny "kanban list --json &> cards.json; jq . cards.json" "&> into a parsed file"

# Poisoning one file must not implicate a different file.
assert_allow \
  "kanban list --json >a.json 2>&1; kanban show x --json >b.json 2>b.err; jq . b.json" \
  "parser reads the cleanly written file"

# Audited escape hatch, same shape as the census guard: a reason is required.
assert_allow \
  "kanban show example --json 2>&1 | jq .  # json-guard-ok: fixture asserting the deny text" \
  "escape hatch with a reason"
assert_deny \
  "kanban show example --json 2>&1 | jq .  # json-guard-ok:" \
  "escape hatch with no reason"

# Heredoc stripping must not blind the inline-parse checks to real commands.
assert_deny \
  "python3 -c \"import json; d = json.loads(open('x').read()); print(d)\"" \
  "real python -c json.loads"
node_prose="$(cat <<'CMD'
brain put <<'REC'
Agents keep writing node -e with JSON.parse against socket output.
REC
CMD
)"
assert_allow "$node_prose" "node -e / JSON.parse named inside a heredoc body"

echo "ok"
