#!/usr/bin/env bash
# PreToolUse hook + reusable scanner — "needs-human" / "NeedsTom" auto-fetch gate.
#
# Standing rule: if you think you need a human, look it up in brain FIRST.
#
# Modes:
#   --scan "<question>"   Print brain + org-secrets + merged-PR scan and exit.
#   (hook, stdin JSON)    PreToolUse:
#     1. Bash marker `needs-human "<question>"` → deny with scan as reason.
#     2. First write to brain `open-decisions` per session → deny once with scan.

set -u
export PATH="$HOME/.local/bin:$HOME/.bun/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

scan() {
  local q="$1"
  local fb secs prs kw r repo
  fb="$(brain ask "$q" --limit 5 2>/dev/null)" || fb="$(brain ask "$q" 2>/dev/null)" || fb="(brain unreachable — retry \`brain ask\` manually)"

  kw="$(printf '%s' "$q" | tr 'A-Z' 'a-z' | grep -oE '[a-z_]{4,}' | sort -u | head -8 | paste -sd'|' - 2>/dev/null)"
  secs="$(env -u GH_TOKEN -u GITHUB_TOKEN gh secret list --org EdgeVector 2>/dev/null | grep -iE "${kw:-zzzzzz}" | head -10)"
  [ -z "$secs" ] && secs="(no org Actions secret name matched \"${kw:-}\" — list all with: gh secret list --org EdgeVector)"

  prs=""
  for repo in fold exemem-infra schema-infra fkanban brain last-stack; do
    r="$(env -u GH_TOKEN -u GITHUB_TOKEN gh pr list --repo "EdgeVector/$repo" --search "$q in:title,body" --state all --limit 3 --json number,title,state 2>/dev/null || true)"
    if [ -n "$r" ] && [ "$r" != "[]" ]; then prs="$prs
  $repo: $r"; fi
  done
  [ -z "$prs" ] && prs="(no PR title/body matched — widen the search manually if unsure)"

  printf '%s' "🔎 NEEDS-HUMAN AUTO-CHECK (standing rule: search brain BEFORE escalating).
Question: \"$q\"

── brain (top matches — the decision usually lives here) ──
$fb

── EdgeVector org Actions secrets (name match) ──
$secs

── PRs across repos (search \"$q\") ──$prs

➡️ DECIDE: if a recorded brain decision, an existing org secret, or a merged PR
already answers this, it is NOT a human gate — drive it autonomously. Only escalate
the genuinely-unresolved / outward / novel set."
}

if [ "${1:-}" = "--scan" ]; then
  scan "${2:-(no question supplied)}"
  exit 0
fi

input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // ""' 2>/dev/null || echo "")"

emit_deny() {
  jq -n --arg r "$1" '{hookSpecificOutput:{hookEventName:"PreToolUse",permissionDecision:"deny",permissionDecisionReason:$r}}'
  exit 0
}

case "$tool" in
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || echo "")"
    if printf '%s' "$cmd" | grep -qiE '^[[:space:]]*(needs[-_]?human|needs[-_]?tom)([[:space:]]|$)'; then
      q="$(printf '%s' "$cmd" \
            | sed -E 's/^[[:space:]]*[Nn][Ee][Ee][Dd][Ss][-_]?([Hh][Uu][Mm][Aa][Nn]|[Tt][Oo][Mm])[[:space:]]*//' \
            | sed -E 's/^["'\'']//; s/["'\''][[:space:]]*$//')"
      [ -z "$q" ] && q="(no question text supplied — state the decision you think needs a human)"
      emit_deny "$(scan "$q")"
    fi
    exit 0
    ;;
  mcp__brain__brain_put)
    # Accept legacy MCP tool name once; product is brain.
    slug="$(printf '%s' "$input" | jq -r '.tool_input.slug // ""' 2>/dev/null || echo "")"
    if [ "$slug" = "open-decisions" ]; then
      sid="$(printf '%s' "$input" | jq -r '.session_id // "nosess"' 2>/dev/null || echo "nosess")"
      sentinel="${TMPDIR:-/tmp}/needs-human-opendecisions.${sid}.done"
      if [ ! -f "$sentinel" ]; then
        touch "$sentinel" 2>/dev/null || true
        body="$(printf '%s' "$input" | jq -r '.tool_input.body // ""' 2>/dev/null || echo "")"
        q="$(printf '%s' "$body" | grep -ioE '(NEEDS-DECISION|HOLD)[^\n]{0,80}' | head -1)"
        [ -z "$q" ] && q="open-decisions escalation"
        emit_deny "You're writing brain open-decisions (the human-escalation surface). Standing rule: search brain FIRST. One-time backstop scan below — fold its findings in, then RE-SUBMIT this write if the item is still genuinely human-only. (Won't fire again this session.)

$(scan "$q")"
      fi
    fi
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
