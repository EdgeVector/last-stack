#!/usr/bin/env bash
# setup must HEAL an already-armed settings.json that holds a hook entry with
# stale notice text, instead of appending a second entry beside it.
#
# This is the live shape of the defect, and a fresh home cannot reproduce it:
# each upsert_pretool_hook call runs once per setup run, so with an empty
# settings.json every script is registered exactly once whatever the replace
# is keyed on. The duplicate only appears when an entry for the same script is
# ALREADY on disk carrying the wording of an earlier last-stack version - which
# is every machine that has run setup more than once across a notice reword.
#
# Measured on this host 2026-10-04: 9 PreToolUse entries under matcher "Bash",
# 7 distinct scripts. unsafe-inline-json.sh and no-home-root-scan.sh each
# appeared twice, with two different trailing comments, and both copies were
# spawned on every Bash tool call - 78 ms of pure duplicate per call. Brain:
# papercut-setup-upsert-pretool-hook-keys-the-replace-on-the-comment-so-rewording-it-duplicates-the-hook-20261004
#
# The fixture seeds the stale wording with a WRONG notice (not an absent one):
# an entry that is missing entirely is healed by any implementation, so only a
# present-and-different entry can tell the two keys apart.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
hooks_dir="$HOME/.claude/hooks"

# An armed machine from an earlier last-stack: the same scripts setup registers,
# each with notice text that no longer matches what setup writes today.
jq -n --arg h "$hooks_dir" '{
  hooks: {
    PreToolUse: [
      { matcher: "Bash",
        hooks: [
          { type: "command", command: "\($h)/unsafe-inline-json.sh  # stale wording from an earlier version", timeout: 5 },
          { type: "command", command: "\($h)/no-home-root-scan.sh  # also stale wording", timeout: 5 },
          { type: "command", command: "\($h)/no-list-as-census.sh  # stale wording too", timeout: 5 }
        ] },
      { matcher: "mcp__brain__brain_list",
        hooks: [
          { type: "command", command: "\($h)/no-list-as-census.sh  # stale MCP wording", timeout: 5 }
        ] }
    ]
  }
}' > "$HOME/.claude/settings.json"

"$ROOT/setup" --host claude >"$tmp/setup.out" 2>"$tmp/setup.err" || {
  sed -n '1,40p' "$tmp/setup.err" >&2
  fail "setup --host claude exited non-zero against an armed settings.json"
}

settings="$HOME/.claude/settings.json"

dupes="$(jq -r '
  (.hooks.PreToolUse // [])[]
  | .matcher as $m
  | (.hooks // [])
  | map((.command // "") | split(" ")[0])
  | group_by(.) | map(select(length > 1)) | .[]
  | "\($m) \(.[0]) x\(length)"' "$settings")"
[ -z "$dupes" ] || fail \
  "setup left a script registered more than once under one matcher:
$dupes
upsert_pretool_hook must key its replace on the script path, not on the whole
command string - rewording the trailing notice orphans the armed entry and
appends a second one, and both get spawned on every matching tool call."

# The surviving entry must be the CURRENT wording, not the stale one that was
# seeded: a replace that drops the new entry instead of the old one also
# produces no duplicate, and would be just as wrong.
for hook in unsafe-inline-json.sh no-home-root-scan.sh no-list-as-census.sh; do
  stale="$(jq --arg h "$hooks_dir/$hook" '
    [ (.hooks.PreToolUse // [])[] | (.hooks // [])[]
      | select((.command // "") | startswith($h))
      | select((.command // "") | test("stale")) ] | length' "$settings")"
  [ "$stale" = "0" ] || fail \
    "$hook kept its stale notice text ($stale entries). The replace must drop the armed entry and keep the one setup writes today."
done

# Every script setup registers must still be armed afterwards: a heal that
# deletes rather than replaces is not a heal.
for hook in unsafe-inline-json.sh no-home-root-scan.sh no-unbounded-workspace-walk.sh routine-shell-lint.sh no-list-as-census.sh; do
  n="$(jq --arg h "$hooks_dir/$hook" '
    [ (.hooks.PreToolUse // [])[] | (.hooks // [])[]
      | select(((.command // "") | split(" ")[0]) == $h) ] | length' "$settings")"
  [ "$n" -ge 1 ] || fail "$hook is not registered at all after setup ran"
done

# no-list-as-census.sh guards two spellings of the same banned verb. A deny on
# one spelling is a silent pass on the other, so both matchers must carry it,
# and must carry the wording setup writes today - counting entries by script
# path alone would be satisfied by the stale one this fixture seeds.
#
# Reachability, measured 2026-10-04: a mutation that deletes the
# mcp__brain__brain_list registration from setup is caught by the STALE check
# above before it reaches here, because the fixture arms that matcher with
# stale text and the stale entry survives the deletion. So this case is a
# second line of defence under this fixture, not the only one. The mutation
# that reaches it removes the registration AND the fixture's stale MCP seed
# together; that combined probe goes red here with n=0.
for matcher in Bash mcp__brain__brain_list; do
  n="$(jq --arg m "$matcher" --arg h "$hooks_dir/no-list-as-census.sh" '
    [ (.hooks.PreToolUse // [])[] | select(.matcher == $m) | (.hooks // [])[]
      | select(((.command // "") | split(" ")[0]) == $h)
      | select((.command // "") | test("stale") | not) ] | length' "$settings")"
  [ "$n" = "1" ] || fail \
    "no-list-as-census.sh is registered $n times with current wording on matcher $matcher, expected exactly 1"
done

echo "ok"
