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

echo "ok"
