#!/usr/bin/env bash
# A hook registration must be keyed on the SCRIPT PATH, not on the whole
# command string.
#
# The command written into settings.json is `<script path>  # <notice text>`.
# The replace used to compare the WHOLE string, so rewording the notice in
# setup left the entry already in settings.json untouched and appended a
# second one beside it: same script, two armed entries, both spawned on every
# matching tool call. It is silent - settings.json stays valid, both entries
# point at the same working script, and the only symptom is latency.
#
# Measured on this host 2026-10-04 before the fix: unsafe-inline-json.sh and
# no-home-root-scan.sh were each registered twice under matcher "Bash" (9
# entries, 7 distinct scripts), costing 78 ms of duplicate hook spawn on every
# single Bash tool call. Brain:
# papercut-setup-upsert-pretool-hook-keys-the-replace-on-the-comment-so-rewording-it-duplicates-the-hook-20261004
#
# Case 1: rewording the notice REPLACES the entry rather than adding one.
# Case 2: a legitimately different script is NOT collapsed into it. Without
#         this, "dedupe harder" passes case 1 by deleting everything.
# Case 3: a sibling path that merely starts with the same prefix survives
#         (`x.sh` must not evict `x.sh.bak-20260923`), so the key is the whole
#         first token and not a prefix.
#
# The live-shape half - setup run against an ALREADY-ARMED settings.json -
# lives in tests/last-stack-setup-heals-a-duplicated-hook-registration.sh.
# It has to be a separate run because a FRESH home cannot reproduce this
# defect at all: each upsert is called once per setup run, so the duplicate
# only appears when an entry with the old wording is already on disk.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Pull the helper out of setup and source it on its own: the test is about the
# function, not about a full setup run.
helper="$tmp/helper.sh"
{
  printf '%s\n' '#!/usr/bin/env bash'
  printf '%s\n' 'set -euo pipefail'
  sed -n '/^upsert_pretool_hook() {$/,/^}$/p' "$ROOT/setup"
} > "$helper"
grep -q 'upsert_pretool_hook()' "$helper" || fail \
  "could not extract upsert_pretool_hook from setup (did the function name or its brace style change?)"
# shellcheck source=/dev/null
. "$helper"

count_script() {
  # entries under $2 whose first token equals $3
  jq --arg matcher "$2" --arg script "$3" '
    [ (.hooks.PreToolUse // [])[]
      | select(.matcher == $matcher)
      | (.hooks // [])[]
      | select(((.command // "") | split(" ")[0]) == $script) ] | length' "$1"
}

# ------------------------------------------------- case 1: reword, not duplicate
s="$tmp/reword.json"
printf '{}\n' > "$s"
upsert_pretool_hook "$s" "Bash" "/h/guard.sh  # first wording of the notice" 5
upsert_pretool_hook "$s" "Bash" "/h/guard.sh  # SECOND, reworded notice" 5
n="$(count_script "$s" "Bash" "/h/guard.sh")"
[ "$n" = "1" ] || fail \
  "case 1: rewording the notice left $n entries for /h/guard.sh under matcher Bash, expected 1. upsert_pretool_hook must key its replace on the script path (the first whitespace-delimited token), not on the whole command string."
jq -e '[(.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[])
        | select(.command | contains("SECOND, reworded notice"))] | length == 1' \
  "$s" >/dev/null || fail "case 1: the surviving entry is not the reworded one"

# -------------------------------------------- case 2: a different script stays
s="$tmp/sibling.json"
printf '{}\n' > "$s"
upsert_pretool_hook "$s" "Bash" "/h/alpha.sh  # notice A" 5
upsert_pretool_hook "$s" "Bash" "/h/beta.sh  # notice B" 5
[ "$(count_script "$s" "Bash" "/h/alpha.sh")" = "1" ] || fail \
  "case 2: registering /h/beta.sh evicted /h/alpha.sh. The replace must only drop entries for the SAME script."
[ "$(count_script "$s" "Bash" "/h/beta.sh")" = "1" ] || fail \
  "case 2: /h/beta.sh was not registered"

# ------------------------------- case 3: a prefix sibling is not the same script
s="$tmp/prefix.json"
printf '{}\n' > "$s"
upsert_pretool_hook "$s" "Bash" "/h/x.sh.bak-20260923  # a backup copy, still armed" 5
upsert_pretool_hook "$s" "Bash" "/h/x.sh  # the live hook" 5
[ "$(count_script "$s" "Bash" "/h/x.sh.bak-20260923")" = "1" ] || fail \
  "case 3: registering /h/x.sh evicted /h/x.sh.bak-20260923. The key is the whole first token, not a string prefix."

echo "ok"
