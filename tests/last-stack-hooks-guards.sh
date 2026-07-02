#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

target="$tmp/example.txt"
printf 'old\n' > "$target"
transcript="$tmp/session.jsonl"
: > "$transcript"

edit_payload() {
  jq -n \
    --arg path "$target" \
    --arg transcript "$transcript" \
    --arg cwd "$tmp" \
    '{
      tool_name: "Edit",
      cwd: $cwd,
      transcript_path: $transcript,
      tool_input: {file_path: $path, old_string: "old", new_string: "new"}
    }'
}

if edit_payload | "$ROOT/hooks/read-before-edit.sh" >/tmp/read-before-edit.out 2>/tmp/read-before-edit.err; then
  echo "expected Edit on an un-Read file to be denied" >&2
  exit 1
fi
grep -q 'Read the file first' /tmp/read-before-edit.out

# Transcripts are JSONL: one compact JSON object per line.
jq -nc --arg path "$target" '{
  type: "assistant",
  message: {
    content: [
      {type: "tool_use", name: "Read", input: {file_path: $path}}
    ]
  }
}' > "$transcript"
edit_payload | "$ROOT/hooks/read-before-edit.sh"

# A Read recorded only in a subagent transcript must unblock an Edit whose
# hook input carries the parent session's transcript_path (subagent tool
# calls receive the parent path).
sub_target="$tmp/sub.txt"
printf 'old\n' > "$sub_target"
mkdir -p "$tmp/session/subagents"
jq -nc --arg path "$sub_target" '{
  type: "assistant",
  message: {
    content: [
      {type: "tool_use", name: "Read", input: {file_path: $path}}
    ]
  }
}' > "$tmp/session/subagents/agent-test.jsonl"
jq -n \
  --arg path "$sub_target" \
  --arg transcript "$transcript" \
  --arg cwd "$tmp" \
  '{
    tool_name: "Edit",
    cwd: $cwd,
    transcript_path: $transcript,
    tool_input: {file_path: $path, old_string: "old", new_string: "new"}
  }' | "$ROOT/hooks/read-before-edit.sh"

# A malformed transcript line must not hide Reads recorded after it.
malformed_target="$tmp/malformed.txt"
printf 'old\n' > "$malformed_target"
printf 'not json\n' >> "$transcript"
jq -nc --arg path "$malformed_target" '{
  type: "assistant",
  message: {
    content: [
      {type: "tool_use", name: "Read", input: {file_path: $path}}
    ]
  }
}' >> "$transcript"
jq -n \
  --arg path "$malformed_target" \
  --arg transcript "$transcript" \
  --arg cwd "$tmp" \
  '{
    tool_name: "Edit",
    cwd: $cwd,
    transcript_path: $transcript,
    tool_input: {file_path: $path, old_string: "old", new_string: "new"}
  }' | "$ROOT/hooks/read-before-edit.sh"

new_file="$tmp/new.txt"
jq -n \
  --arg path "$new_file" \
  --arg transcript "$transcript" \
  --arg cwd "$tmp" \
  '{
    tool_name: "Write",
    cwd: $cwd,
    transcript_path: $transcript,
    tool_input: {file_path: $path, content: "new"}
  }' | "$ROOT/hooks/read-before-edit.sh"

if jq -n '{
    tool_name: "Bash",
    tool_input: {command: "node -e \"const d=JSON.parse(process.argv[1]); console.log(d.x)\" \"$json\""}
  }' | "$ROOT/hooks/unsafe-inline-json.sh" >/tmp/unsafe-inline-json.out 2>/tmp/unsafe-inline-json.err; then
  echo "expected node -e JSON.parse to be denied" >&2
  exit 1
fi
grep -q 'use jq' /tmp/unsafe-inline-json.out
grep -q 'scratchpad' /tmp/unsafe-inline-json.out

jq -n '{
  tool_name: "Bash",
  tool_input: {command: "jq -r .x data.json"}
}' | "$ROOT/hooks/unsafe-inline-json.sh"

echo "ok"
