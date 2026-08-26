#!/usr/bin/env bash
# FIX: land a real fix for the red soak through the normal gates. Default is
# a contract stand-in (CI). LOOM_LIVE=1 (or LOOM_SOAK_HEAL_LIVE=1) runs an
# agent against the app's repo, reading the red probe output and the notes of
# PRIOR attempts from context so attempt two does not repeat attempt one.
# The loop has no bypass: the fix merges as an ordinary lastgit CR.
set -euo pipefail

input="${LOOM_INPUT:-"{}"}"
app="$(printf '%s' "$input" | jq -r '.app // empty')"
digest="$(printf '%s' "$input" | jq -r '.digest // empty')"
probe_tail="$(printf '%s' "$input" | jq -r '.probe_tail // empty')"
attempt="$(printf '%s' "$input" | jq -r '.attempt // 0')"
notes="$(printf '%s' "$input" | jq -r '.attempt_notes // empty')"
card="$(printf '%s' "$input" | jq -r '.card // empty')"
key="${LOOM_IDEMPOTENCY_KEY:-soak-heal-$app}"
attempt=$((attempt + 1))

live=0
[ "${LOOM_LIVE:-}" = "1" ] && live=1
[ "${LOOM_SOAK_HEAL_LIVE:-}" = "1" ] && live=1

if [ "$live" -ne 1 ]; then
  printf 'LOOM_EFFECT_INTENT:{"kind":"pr_open","target":"%s-a%s"}\n' "$key" "$attempt"
  printf 'LOOM_EFFECT_DONE:{"kind":"pr_open","target":"%s-a%s"}\n' "$key" "$attempt"
  jq -cn --argjson attempt "$attempt" \
    --arg note "attempt $attempt: stand-in (no host mutation)" \
    '{attempt:$attempt, fix_status:"stand-in", attempt_notes:$note}' \
    | sed 's/^/LOOM_CONTEXT_PATCH:/'
  echo "soak-fix stand-in app=$app attempt=$attempt"
  exit 0
fi

agent=""
for cand in claude grok; do
  if command -v "$cand" >/dev/null 2>&1; then agent="$cand"; break; fi
done
[ -n "$agent" ] || { echo "soak-fix: no agent CLI on PATH" >&2; exit 1; }

printf 'LOOM_EFFECT_INTENT:{"kind":"pr_open","target":"%s-a%s"}\n' "$key" "$attempt"

brief="$(cat <<BRIEF
host-track soak-watch rejected the $app candidate ${digest:0:12} (soak RED).
Follow the kanban-agent skill for card $card in the $app repo (LastGit venue,
lastdb:///). Work in an isolated worktree. Diagnose the red probe, land the
smallest real fix as a normal CR with auto-merge on ci-required, and drive it
to MERGED. Do not touch host-track current/canary symlinks by hand — the
pipeline redeploys after your merge. This is heal attempt $attempt of 3.

Red probe output (tail):
$probe_tail

Notes from prior attempts (do not repeat them):
$notes
BRIEF
)"

out="$("$agent" -p "$brief" 2>&1 | tail -c 4000)" || {
  jq -cn --argjson attempt "$attempt" --arg note "attempt $attempt: agent run failed" \
    '{attempt:$attempt, fix_status:"agent-failed", attempt_notes:$note}' \
    | sed 's/^/LOOM_CONTEXT_PATCH:/'
  echo "soak-fix agent failed app=$app attempt=$attempt" >&2
  exit 1
}

printf 'LOOM_EFFECT_DONE:{"kind":"pr_open","target":"%s-a%s"}\n' "$key" "$attempt"
note="attempt $attempt: $(printf '%s' "$out" | tail -c 500 | tr '\n' ' ')"
jq -cn --argjson attempt "$attempt" --arg note "$notes
$note" \
  '{attempt:$attempt, fix_status:"landed", attempt_notes:$note}' \
  | sed 's/^/LOOM_CONTEXT_PATCH:/'
echo "soak-fix app=$app attempt=$attempt done"
