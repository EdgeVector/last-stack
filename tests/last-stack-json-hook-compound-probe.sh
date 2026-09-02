#!/usr/bin/env bash
# Compound probe for the JSON PreToolUse hook (card
# last-stack-json-hook-safe-flow-example-and-probe-20260831).
#
# Feeds the hook the same Bash PreToolUse envelope the agent runtime uses, then
# also runs the documented capture helper live. Blocked forms must deny; the
# capture-then-jq flow must pass the hook and produce parseable JSON.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HOOK="$ROOT/hooks/unsafe-inline-json.sh"
CAP="$ROOT/bin/last-stack-json-capture"

scratch="$(mktemp -d "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-json-hook-compound.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

hook_out() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "$HOOK"
}

assert_deny() {
  local cmd="$1"
  local label="$2"
  local needle="$3"
  local out
  out="$(hook_out "$cmd")"
  if ! printf '%s' "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1; then
    printf 'expected DENY (%s), got: %s\n' "$label" "$out" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | grep -q "$needle"; then
    printf 'deny for %s missing %s\n%s\n' "$label" "$needle" "$out" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | grep -q 'last-stack-json-capture'; then
    printf 'deny for %s does not show last-stack-json-capture\n%s\n' "$label" "$out" >&2
    exit 1
  fi
  if ! printf '%s' "$out" | grep -q 'jq . /tmp/data.json'; then
    printf 'deny for %s does not show the jq follow-up\n%s\n' "$label" "$out" >&2
    exit 1
  fi
}

assert_allow() {
  local cmd="$1"
  local label="$2"
  local out
  out="$(hook_out "$cmd")"
  if [ -n "$out" ]; then
    printf 'expected ALLOW (%s), got: %s\n' "$label" "$out" >&2
    exit 1
  fi
}

# 1. node -e / python -c JSON parsing is denied, and the deny names the helper.
assert_deny \
  'node -e "const d=JSON.parse(process.argv[1]); console.log(d.x)" "$json"' \
  'node -e JSON.parse' \
  'unsafe inline JSON parsing'
assert_deny \
  "python3 -c \"import json; d = json.loads(open('x').read()); print(d)\"" \
  'python3 -c json.loads' \
  'unsafe inline JSON parsing'

# 2. A JSON stream with merged stderr is denied, and the deny names the helper.
assert_deny \
  'kanban show example --json 2>&1 | jq .' \
  'merged stderr piped to jq' \
  'stderr is being merged into machine-readable JSON'

# 3. last-stack-json-capture <file> -- <json-command> then jq <file> is allowed.
safe_flow='"$HOME/.last-stack/bin/last-stack-json-capture" /tmp/data.json -- kanban show example --json
jq . /tmp/data.json'
assert_allow "$safe_flow" 'install-path capture then jq'
assert_allow \
  'last-stack-json-capture /tmp/data.json -- kanban list --column todo --json; jq -r ".cards[].slug" /tmp/data.json' \
  'PATH capture then jq'

# 4. The documented safe flow runs without a hook is_error: capture then jq
#    against a noisy JSON command (stderr present, stdout still parseable).
noisy="$scratch/noisy"
cat >"$noisy" <<'CMD'
#!/usr/bin/env bash
echo "warning: cache is cold" >&2
printf '{"slug":"compound-probe","ok":true}\n'
CMD
chmod +x "$noisy"

status="$("$CAP" "$scratch/out.json" -- "$noisy")"
printf '%s' "$status" | grep -q 'json=yes' \
  || { echo "live capture expected json=yes in: $status" >&2; exit 1; }
[ "$(jq -r .slug "$scratch/out.json")" = "compound-probe" ] \
  || { echo "jq could not read live capture: $(cat "$scratch/out.json")" >&2; exit 1; }
grep -q 'warning: cache is cold' "$scratch/out.json.err" \
  || { echo "live capture did not keep stderr in .err" >&2; exit 1; }

live_cmd="$(printf '%s\n' \
  "\"$CAP\" \"$scratch/out.json\" -- \"$noisy\"" \
  "jq -r .slug \"$scratch/out.json\"")"
assert_allow "$live_cmd" 'live capture helper command string'

echo "ok"
