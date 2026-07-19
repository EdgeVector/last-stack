#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

records="$tmp/records.json"
board="$tmp/board.json"
root="$tmp/root"
mkdir -p "$root/skills/example" "$root/routines"

cat > "$records" <<'JSON'
[
  {
    "type": "reference",
    "slug": "keep-source",
    "title": "Keep source",
    "body": "This live record points at [[delete-me]]."
  },
  {
    "type": "reference",
    "slug": "delete-me",
    "title": "Delete me",
    "body": "Self mentions [[delete-me]] and should not count."
  },
  {
    "type": "project",
    "slug": "other",
    "title": "Other",
    "body": "No relevant wiki link."
  }
]
JSON

cat > "$board" <<'JSON'
[
  {
    "slug": "north-star-card",
    "title": "North star ref",
    "north_star": "delete-me",
    "body": ""
  },
  {
    "slug": "body-card",
    "title": "Body ref",
    "north_star": "",
    "body": "VERIFY references delete-me directly."
  }
]
JSON

cat > "$root/CLAUDE.md" <<'EOF_CLAUDE'
Keep delete-me around while this prompt still names it.
EOF_CLAUDE
cat > "$root/AGENTS.md" <<'EOF_AGENTS'
No candidate here.
EOF_AGENTS
cat > "$root/skills/example/SKILL.md" <<'EOF_SKILL'
Skill guidance references [[delete-me]].
EOF_SKILL
cat > "$root/routines/example.md" <<'EOF_ROUTINE'
Routine guidance names delete-me.
EOF_ROUTINE

if "$ROOT/bin/last-stack-brain-reference-guard" \
  --records-json "$records" \
  --board-json "$board" \
  --file-root "$root" \
  delete-me >"$tmp/out" 2>"$tmp/err"; then
  echo "expected referenced candidate to be refused" >&2
  exit 1
fi
grep -q 'refusing deletion' "$tmp/err"
grep -q 'brain-record: reference:keep-source' "$tmp/err"
grep -q 'board-north-star: north-star-card' "$tmp/err"
grep -q 'board-body: body-card' "$tmp/err"
grep -q 'prompt-file: CLAUDE.md' "$tmp/err"
grep -q 'prompt-file: skills/example/SKILL.md' "$tmp/err"
grep -q 'prompt-file: routines/example.md' "$tmp/err"

"$ROOT/bin/last-stack-brain-reference-guard" \
  --records-json "$records" \
  --board-json "$board" \
  --file-root "$root" \
  unreferenced >"$tmp/pass"
grep -q 'ok: no referenced deletion candidates (1 checked)' "$tmp/pass"

"$ROOT/bin/last-stack-brain-reference-guard" \
  --records-json "$records" \
  --board-json "$board" \
  --file-root "$root" \
  --report-only \
  --json \
  delete-me >"$tmp/report"
python3 - "$tmp/report" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["checked"] == 1
assert report["referenced_count"] == 1
assert "delete-me" in report["referenced"]
PY

echo "ok"
