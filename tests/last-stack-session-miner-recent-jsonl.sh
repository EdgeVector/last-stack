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

echo "ok last-stack-session-miner-recent-jsonl"
