#!/usr/bin/env bash
# setup must be able to ARM a hook on every event the harness uses, and must be
# able to DE-REGISTER one from any of them.
#
# `install_claude_hooks` had exactly one registration helper,
# `upsert_pretool_hook`, so the five live orphan hooks on SessionStart / Stop /
# UserPromptSubmit / PostToolUse could not be registered by anything setup
# contained. Brain:
# papercut-setup-has-only-a-pretooluse-registration-helper-so-five-of-eight-orphan-hooks-cannot-be-managed-20261004
#
# The prescribed fix was "the same jq with the event as a variable". That is
# INCOMPLETE, and the incompleteness is what these cases pin. Measured on a
# live settings.json: PreToolUse and PostToolUse groups carry a `matcher` key;
# SessionStart, Stop and UserPromptSubmit groups carry `keys=[hooks]` and no
# matcher. A generic helper that always wrote `{matcher, hooks}` would append a
# SECOND group beside the armed matcher-less one and never find it again — so
# the hook arms twice and a re-run can never replace it. Case 1 pins the group
# SHAPE and case 2 pins the replace, because a passing registration proves
# neither.
#
# These cases drive the real installer against a throwaway HOME. setup is a
# top-to-bottom script with no main guard, so it cannot be sourced; the fixture
# registrations are patched into a copy of the tree instead.
#
# Mutation-probed 2026-10-04, six probes, each RED on the assertion it targets:
# the prescribed naive generic (case 1 shape), a full-command replace key
# (case 2), a non-PreToolUse no-op (case 1 wiring), a PreToolUse-only remove
# (case 4), and never finding an existing matcher group (case 3, duplicate
# groups). The in-group duplicate count below is deliberately DOUBLE-PROTECTED:
# any mutation that reaches it fails case 2 first, and its independent probe
# lives in tests/last-stack-setup-hook-registration-is-keyed-on-the-script.sh
# and tests/last-stack-setup-heals-a-duplicated-hook-registration.sh. It is kept
# here as a regression pin on the matcher-keyed axis — do not delete it as
# redundant.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp"
}
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

src="$tmp/src"
mkdir -p "$src"
(cd "$ROOT" && tar --exclude='./.git' -cf - .) | (cd "$src" && tar -xf -)
[ -f "$src/setup" ] || fail "tree copy did not carry setup"

# A hook on a matcher-less event, and a retired hook that must be swept from
# one. Both are fixtures: they exist only inside this throwaway copy.
cat > "$src/hooks/zz-upsert-probe-stop.sh" <<'PROBE'
#!/usr/bin/env bash
# Fixture only. Never shipped.
exit 0
PROBE
chmod 755 "$src/hooks/zz-upsert-probe-stop.sh"

# Patch the fixture registrations into the copy, just before the permission
# loop. NOTICE_TEXT is substituted per run so the second run reaches the
# replace path with DIFFERENT notice text — the case that key must survive.
python3 - "$src/setup" <<'PY'
import io, sys
p = sys.argv[1]
s = io.open(p, encoding='utf-8').read()
anchor = "  for tool in \\\n"
assert s.count(anchor) == 1, "permission-loop anchor not unique: %d" % s.count(anchor)
inject = '''  remove_hook_by_script "$settings" "zz-upsert-probe-retired.sh"
  upsert_hook "$settings" "Stop" "" \\
    "$hooks_dir/zz-upsert-probe-stop.sh  # fixture ${ZZ_NOTICE:-first}" \\
    5

'''
s = s.replace(anchor, inject + anchor)
io.open(p, 'w', encoding='utf-8').write(s)
PY
grep -Fq 'zz-upsert-probe-stop.sh' "$src/setup" || fail "fixture registration was not injected"

export HOME="$tmp/home"
mkdir -p "$HOME/.claude"
# Pre-arm the retired fixture on a matcher-less event, so the sweep has
# something to find that a PreToolUse-only remove could never reach.
cat > "$HOME/.claude/settings.json" <<'SETTINGS'
{
  "hooks": {
    "Stop": [
      { "hooks": [ { "type": "command", "command": "/pre/existing/zz-upsert-probe-retired.sh  # retired", "timeout": 5 } ] }
    ]
  }
}
SETTINGS

run_setup() {
  ZZ_NOTICE="$1" "$src/setup" --host claude >"$tmp/setup.$1.out" 2>"$tmp/setup.$1.err" || {
    sed -n '1,40p' "$tmp/setup.$1.err" >&2
    fail "setup --host claude exited non-zero (run: $1)"
  }
}

settings="$HOME/.claude/settings.json"
run_setup first

# ------------------------------------------- case 1: the matcher-less SHAPE
# The entry must land on Stop, and its group must carry NO matcher key. A
# helper that wrote one would still pass a "the command is present" assertion.
stop_groups_with_probe="$(jq -r '
  [(.hooks.Stop // [])[]
    | select(any((.hooks // [])[]; (.command // "") | startswith(env.HOME + "/.claude/hooks/zz-upsert-probe-stop.sh")))]
  | length' "$settings")"
[ "$stop_groups_with_probe" = "1" ] || fail \
  "expected the Stop fixture hook in exactly 1 group, found $stop_groups_with_probe. setup must register a matcher-less event with upsert_hook \"\$settings\" \"Stop\" \"\" ..."

matcher_keys="$(jq -r '
  [(.hooks.Stop // [])[]
    | select(any((.hooks // [])[]; (.command // "") | startswith(env.HOME + "/.claude/hooks/zz-upsert-probe-stop.sh")))
    | select(has("matcher"))]
  | length' "$settings")"
[ "$matcher_keys" = "0" ] || fail \
  "the Stop group carrying the fixture hook has a \"matcher\" key. Stop/SessionStart/UserPromptSubmit groups are matcher-LESS on a real host; writing a matcher creates a second group beside the armed one that a re-run can never find."

# ------------------------------- case 2: a REWORDED notice must REPLACE, not add
# The wrong value is different notice text, never absent text (an absent
# command would fail case 1 instead and prove nothing about the key).
run_setup second
probe_entries="$(jq -r '
  [(.hooks.Stop // [])[] | (.hooks // [])[]
    | select((.command // "") | startswith(env.HOME + "/.claude/hooks/zz-upsert-probe-stop.sh"))]
  | length' "$settings")"
[ "$probe_entries" = "1" ] || fail \
  "re-running setup with different notice text left $probe_entries entries for the Stop fixture hook, expected 1. The replace must be keyed on the SCRIPT PATH, not the whole command string."

grep -Fq 'fixture second' "$settings" || fail \
  "the surviving Stop entry does not carry the second run's notice text, so the replace did not happen — the first entry was kept and the second dropped."

# --------------------------- case 3: the matcher-keyed path still de-duplicates
# Two assertions, because a per-script count alone is wrong in BOTH directions.
# One script legitimately appears more than once per EVENT: no-list-as-census.sh
# is armed on matcher Bash and on matcher mcp__brain__brain_list, since a deny
# on one spelling of the banned verb is a silent pass on the other. So
# uniqueness holds per matcher GROUP, not per event.
dupes="$(jq -r '
  [(.hooks.PreToolUse // [])[]
    | (.hooks // []) | map((.command // "") | split(" ")[0])
    | group_by(.) | map(select(length > 1)) | length] | add // 0' "$settings")"
[ "$dupes" = "0" ] || fail \
  "$dupes script(s) are registered twice inside one PreToolUse matcher group after two setup runs."

# And a per-group count cannot see a helper that stopped FINDING the armed group
# and appended a second one with the same matcher beside it: one entry each,
# zero in-group duplicates, and the hook running twice on every call. That is
# the defect case 1 pins for matcher-less events, on the matcher-keyed axis.
dup_groups="$(jq -r '
  [(.hooks.PreToolUse // [])[] | .matcher? // "<none>"]
  | group_by(.) | map(select(length > 1)) | length' "$settings")"
[ "$dup_groups" = "0" ] || fail \
  "$dup_groups matcher value(s) appear in more than one PreToolUse group. upsert_hook must FIND the existing group for a matcher, not append a second one."

# ----------------- case 4: the generic remove reaches a non-PreToolUse event
if grep -Fq 'zz-upsert-probe-retired.sh' "$settings"; then
  fail "the retired fixture hook is still armed on Stop. remove_hook_by_script must sweep EVERY event; a PreToolUse-only sweep cannot de-register a hook armed on Stop or SessionStart."
fi

echo "ok"
