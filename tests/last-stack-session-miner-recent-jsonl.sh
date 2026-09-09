#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HELPER="$ROOT/skills/session-miner/scripts/recent-jsonl.py"
scratch="$(mktemp -d "${TMPDIR:-/tmp}/session-miner-recent.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

mkdir -p "$scratch/transcripts"
cat >"$scratch/transcripts/mixed.jsonl" <<'EOF'
{"timestamp":"2026-08-26T00:00:00Z","session_id":"old-session","message":"old-marker"}
{"timestamp":"2026-08-28T00:00:00Z","session_id":"new-session","message":"new-marker-one"}
{"timestamp":"2026-08-28T00:01:00Z","session_id":"new-session","message":"new-marker-two"}
EOF
cat >"$scratch/transcripts/old.jsonl" <<'EOF'
{"timestamp":"2026-08-20T00:00:00Z","session_id":"touched-old","message":"mtime-must-not-qualify"}
EOF
cat >"$scratch/transcripts/no-timestamp.jsonl" <<'EOF'
{"session_id":"unknown-window","message":"no timestamp"}
EOF
touch -t 203001010000 "$scratch/transcripts/old.jsonl"

python3 "$HELPER" \
  --since 2026-08-27T00:00:00Z \
  --root "codex=$scratch/transcripts" \
  --records-output "$scratch/recent.jsonl" \
  >"$scratch/summary.json"

[ "$(jq -r .files_scanned "$scratch/summary.json")" = "3" ]
[ "$(jq -r .files_in_window "$scratch/summary.json")" = "1" ]
[ "$(jq -r .records_in_window "$scratch/summary.json")" = "2" ]
[ "$(jq -r .sessions_in_window "$scratch/summary.json")" = "1" ]
[ "$(jq -r .unwindowed_file_count "$scratch/summary.json")" = "1" ]
[ "$(jq -r '.unwindowed_files | length' "$scratch/summary.json")" = "1" ]
[ "$(jq -r .unwindowed_files_truncated "$scratch/summary.json")" = "false" ]
[ "$(wc -l <"$scratch/recent.jsonl" | tr -d ' ')" = "2" ]
rg -q 'new-marker-one' "$scratch/recent.jsonl"
rg -q 'new-marker-two' "$scratch/recent.jsonl"
if rg -q 'old-marker|mtime-must-not-qualify' "$scratch/recent.jsonl"; then
  echo "old content entered the recent corpus" >&2
  exit 1
fi

# Grok events.jsonl stamps the record with `ts`. chat_history.jsonl does not.
mkdir -p "$scratch/grok/session-a"
cat >"$scratch/grok/session-a/events.jsonl" <<'EOF'
{"ts":"2026-08-20T00:00:00Z","type":"tool_completed","session_id":"grok-old","message":"grok-old-marker"}
{"ts":"2026-08-28T00:02:00Z","type":"tool_completed","session_id":"grok-new","message":"grok-ts-marker"}
EOF
cat >"$scratch/grok/session-a/chat_history.jsonl" <<'EOF'
{"type":"assistant","content":"chat-history-has-no-ts","session_id":"grok-chat"}
EOF
touch -t 203001010000 "$scratch/grok/session-a/chat_history.jsonl"

python3 "$HELPER" \
  --since 2026-08-27T00:00:00Z \
  --root "grok=$scratch/grok" \
  --include "grok=events.jsonl" \
  --records-output "$scratch/grok-recent.jsonl" \
  >"$scratch/grok-summary.json"

[ "$(jq -r .files_scanned "$scratch/grok-summary.json")" = "1" ]
[ "$(jq -r .files_in_window "$scratch/grok-summary.json")" = "1" ]
[ "$(jq -r .records_in_window "$scratch/grok-summary.json")" = "1" ]
[ "$(jq -r .sessions_in_window "$scratch/grok-summary.json")" = "1" ]
[ "$(jq -r .unwindowed_file_count "$scratch/grok-summary.json")" = "0" ]
rg -q 'grok-ts-marker' "$scratch/grok-recent.jsonl"
if rg -q 'grok-old-marker|chat-history-has-no-ts' "$scratch/grok-recent.jsonl"; then
  echo "out-of-window grok content entered the recent corpus" >&2
  exit 1
fi

echo "ok last-stack-session-miner-recent-jsonl"
