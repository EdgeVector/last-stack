#!/usr/bin/env bash
# A Situations triage projection in shipped prose must keep `.title`.
#
# A Situation SLUG is immutable and a Situation BODY gets amended, so the slug
# is the least current field in the row. The prescribed triage projection used
# to be `[.slug, .status, (.severity // "-")] | @tsv`, which shows an agent the
# slug and nothing else. Measured 2026-10-04: the one active Situation on this
# host had the slug `lastdb-brain-cleanout-use-gbrain-20260923` while its own
# summary had read "Do not read, write or sync gbrain" since 2026-09-26, and
# the slug names an action a won't-undo user rule forbids. Brain:
# papercut-situations-triage-one-liner-drops-the-title-so-an-immutable-slug-is-the-only-field-an-agent-reads-20261004
#
# This prose is materialized by `setup` into every harness root
# (~/.claude/CLAUDE.md and each AGENTS.md), so a regression here reaches every
# agent on the host as its FIRST command.
#
# The matcher is the triage projection SHAPE, not a file list: any jq array
# projection in shipped prose that selects a slug, a status and a severity
# together is a Situations triage line. No allowlist, so a second site added
# later is covered without an edit here.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"

bad=0
while IFS= read -r hit; do
  file="${hit%%:*}"
  rest="${hit#*:}"
  line="${rest%%:*}"
  text="${rest#*:}"
  case "$text" in
    *.title*) continue ;;
  esac
  printf 'FAIL: %s:%s prescribes a Situations triage projection without .title\n' "$file" "$line" >&2
  printf '      %s\n' "$text" >&2
  bad=$((bad + 1))
done < <(
  grep -rnE '\[[^]]*\.slug[^]]*\]' \
    --include='*.md' instructions routines skills docs 2>/dev/null \
  | grep -E '\.status' \
  | grep -E 'severity'
)

if [ "$bad" -gt 0 ]; then
  cat >&2 <<'MSG'

A Situation slug cannot be corrected: it is referenced by blocked_actions
consumers, brain records and preflight output, and `situations` has no
supersede-with-redirect verb. Only the body can be amended. So a projection
without .title shows the agent the one field an amendment can never reach.

Add .title to the projection:

  jq -r '.[] | [.slug, .status, (.severity // "-"), .title] | @tsv' /tmp/sit.json
MSG
  exit 1
fi

# The projection must actually be PRESENT, not merely never wrong. A guard that
# passes on an empty match set would go green if the canonical form were
# deleted or reworded past the matcher.
canonical=$(
  grep -rnE '\[[^]]*\.slug[^]]*\]' --include='*.md' instructions 2>/dev/null \
    | grep -cE '\.status.*severity' || true
)
if [ "$canonical" -lt 1 ]; then
  printf 'FAIL: no Situations triage projection found under instructions/ at all; this guard matched nothing and cannot certify anything\n' >&2
  exit 1
fi

printf 'ok  triage projections checked=%s  missing_title=0\n' "$canonical"
