---
name: onecontext
description: Search past Codex sessions and, when available, Aline history for prior discussions, code changes, decisions, and debugging context. Use this when the user asks about existing objects, historical rationale, previous implementations, or related context from past chats.
---

# OneContext Skill

Use this skill to recover relevant history before making assumptions. Prefer a
broad-to-deep path: find likely sessions first, then inspect the specific turns
or raw dialogue that contain the detail you need.

## First Check: Is Aline Available?

Do not run Aline directly until the current shell proves it exists. Some Codex
environments have this skill installed but do not have an `aline` binary on
`PATH`.

```bash
if command -v aline >/dev/null 2>&1; then
  aline search "<pattern>"
else
  echo "aline unavailable; use the Codex JSONL fallback below" >&2
fi
```

If `command -v aline` fails, go straight to the JSONL fallback. Do not try an
Aline command first.

## JSONL Fallback for Codex Sessions

Codex stores session transcripts as JSONL under
`${CODEX_HOME:-$HOME/.codex}/sessions`. Use `SINCE` to bound the scan by
timestamp and `PATTERN` as a jq-compatible regular expression.

```bash
PATTERN="sqlite.*migration"
SINCE="2026-06-01T00:00:00Z"
sessions_root="${CODEX_HOME:-$HOME/.codex}/sessions"

if [ ! -d "$sessions_root" ]; then
  echo "missing Codex sessions directory: $sessions_root" >&2
  exit 1
fi

find "$sessions_root" -type f -name '*.jsonl' -print0 |
  while IFS= read -r -d '' file; do
    jq -r --arg pattern "$PATTERN" --arg since "$SINCE" '
      def compact_text:
        [
          .type?,
          .payload.type?,
          .payload.role?,
          .payload.text?,
          .payload.message?,
          .payload.summary?,
          .payload.title?,
          .payload.content?
        ]
        | map(
            if type == "string" then .
            elif type == "array" or type == "object" then tostring
            else empty
            end
          )
        | join(" ")
        | gsub("[[:space:]]+"; " ")
        | .[0:300];

      (.timestamp // .payload.timestamp // "") as $ts
      | select($ts == "" or $ts >= $since)
      | select((. | tostring) | test($pattern; "i"))
      | "\($ts)\t\(input_filename)\t\(compact_text)"
    ' "$file"
  done
```

For a quick recent scan, set `SINCE` to the day you care about. For an all-time
scan, use `SINCE="1970-01-01T00:00:00Z"`.

## Aline Workflow When Available

Aline is a navigation map over history. After the availability guard succeeds:

1. Start broad: search events, sessions, and turns for the general topic.
2. Narrow to a session or event using the ID prefixes in results.
3. Deep-search raw content only when summaries are not enough.
4. Read the concrete transcript before relying on a remembered decision.

Example guarded helper:

```bash
onecontext_search() {
  pattern="$1"
  if command -v aline >/dev/null 2>&1; then
    aline search "$pattern"
    return
  fi

  since="${SINCE:-1970-01-01T00:00:00Z}"
  sessions_root="${CODEX_HOME:-$HOME/.codex}/sessions"
  find "$sessions_root" -type f -name "*.jsonl" -print0 |
    while IFS= read -r -d "" file; do
      jq -r --arg pattern "$pattern" --arg since "$since" '
        (.timestamp // .payload.timestamp // "") as $ts
        | select($ts == "" or $ts >= $since)
        | select((. | tostring) | test($pattern; "i"))
        | "\($ts)\t\(input_filename)\t\((.payload.text // .payload.message // .payload.summary // .type // "") | tostring | gsub("[[:space:]]+"; " ") | .[0:300])"
      ' "$file"
    done
}
```

Useful guarded Aline forms:

```bash
if command -v aline >/dev/null 2>&1; then
  aline search "refactor" -t session
  aline search "error" -s abc123de
  aline search -t content "api_key" --turns t789
  aline watcher session show abc123de
fi
```

## When to Use This Skill

Use OneContext when the user asks to:

- Find when a feature was discussed or implemented.
- Research why a code change happened.
- Locate previous implementations or debugging sessions.
- Check whether a problem has happened before.
- Search prior agent context before changing behavior.

If Aline is unavailable, the JSONL fallback is the primary path, not a last
resort after a failed command.
