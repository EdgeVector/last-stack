#!/usr/bin/env bash
# last-stack-json-capture keeps stdout and stderr apart, and the pattern it
# produces must never trip the merged-stream guard that motivated it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
CAP="$ROOT/bin/last-stack-json-capture"
HOOK="$ROOT/hooks/unsafe-inline-json.sh"

scratch="$(mktemp -d "${TMPDIR:-${TMP:-${TEMP:-/tmp}}}/last-stack-json-capture.XXXXXX")"
trap 'rm -rf "$scratch"' EXIT

noisy="$scratch/noisy"
cat >"$noisy" <<'CMD'
#!/usr/bin/env bash
echo "warning: cache is cold" >&2
echo "progress: 1 of 2" >&2
printf '{"slug":"demo","count":2}\n'
CMD
chmod +x "$noisy"

# ── the core promise: a noisy command still yields parseable JSON ────────────
status="$("$CAP" "$scratch/out.json" "$noisy")"

[ "$(cat "$scratch/out.json")" = '{"slug":"demo","count":2}' ] \
  || { echo "stdout file polluted: $(cat "$scratch/out.json")" >&2; exit 1; }

grep -q 'warning: cache is cold' "$scratch/out.json.err" \
  || { echo "stderr not captured to .err" >&2; exit 1; }

grep -q 'warning' "$scratch/out.json" \
  && { echo "stderr leaked into the JSON file" >&2; exit 1; }

# The status line is the point: it must say the capture parsed.
printf '%s' "$status" | grep -q 'json=yes' \
  || { echo "expected json=yes in: $status" >&2; exit 1; }
printf '%s' "$status" | grep -q 'rc=0' \
  || { echo "expected rc=0 in: $status" >&2; exit 1; }

# jq really can read it — the failure this whole guard family exists to stop.
[ "$(jq -r .slug "$scratch/out.json")" = "demo" ] \
  || { echo "jq could not read the captured file" >&2; exit 1; }

# ── the wrapped command's exit status survives ──────────────────────────────
failing="$scratch/failing"
cat >"$failing" <<'CMD'
#!/usr/bin/env bash
echo "boom" >&2
exit 7
CMD
chmod +x "$failing"

rc=0
"$CAP" "$scratch/fail.json" "$failing" >"$scratch/fail.status" 2>"$scratch/fail.diag" || rc=$?
[ "$rc" -eq 7 ] || { echo "expected exit 7, got $rc" >&2; exit 1; }
grep -q 'json=no' "$scratch/fail.status" \
  || { echo "expected json=no for empty stdout" >&2; exit 1; }
grep -q 'boom' "$scratch/fail.json.err" \
  || { echo "stderr of a failing command not captured" >&2; exit 1; }
# An unparseable capture must say so where the agent will see it.
grep -q 'did not parse as JSON' "$scratch/fail.diag" \
  || { echo "expected a stderr diagnostic on unparseable capture" >&2; exit 1; }

# ── usage errors are refused, not silently mis-parsed ───────────────────────
rc=0
"$CAP" "$scratch/only-one-arg.json" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "expected usage exit 2, got $rc" >&2; exit 1; }

rc=0
"$CAP" "$scratch/no/such/dir/out.json" true >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 2 ] || { echo "expected exit 2 for a missing directory, got $rc" >&2; exit 1; }

# ── and the pattern it teaches must pass the guard it replaces ──────────────
hook_out() {
  jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}' | "$HOOK"
}

out="$(hook_out 'last-stack-json-capture /tmp/cards.json kanban list --column todo --json
jq -r ".cards[].slug" /tmp/cards.json')"
[ -z "$out" ] || { echo "capture pattern tripped the guard: $out" >&2; exit 1; }

# The deny text must point at the helper, or agents keep hand-rolling plumbing.
deny="$(hook_out 'kanban show example --json 2>&1 | jq .')"
printf '%s' "$deny" | grep -q 'last-stack-json-capture' \
  || { echo "deny hint does not mention last-stack-json-capture" >&2; exit 1; }

echo "ok"
