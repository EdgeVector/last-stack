#!/usr/bin/env bash
# heal-soak: graph shape, runner key semantics (one run per incident), and
# node-script stand-in contracts — all against stubs, no live loom or node.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-soak-heal-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

DEF="$ROOT/lib/soak-loom/heal-soak.json"
RUNNER="$ROOT/bin/last-stack-soak-heal-loom"

# --- graph shape ------------------------------------------------------------
jq -e '
  .name == "heal-soak"
  and .version == "2"
  and .start_at == "COLLECT"
  and (.states.DECIDE.type == "choice")
  and (.states.DECIDE.map.green == "DONE")
  and (.states.DECIDE.map.exhausted == "REPORT")
  and (.states.DECIDE.default == "FIX")
  and (.states.WAIT_SOAK.type == "wait")
  and (.states.WAIT_SOAK.until == "duration:20m")
  and (.states.WAIT_SOAK.next == "COLLECT")
  and (.states.WAIT_SOAK.command == null)
  and (.states.FIX.effects == "checked")
  and (.states.DONE.type == "succeed")
  and (.states.FAILED.type == "fail")
  and (.input_schema.required == ["app"])
' "$DEF" >/dev/null || fail "heal-soak.json shape wrong"

# --- runner: loom missing → exit 3 (best-effort contract) ------------------
set +e
env PATH="/usr/bin:/bin" HOME="$tmp" \
  "$RUNNER" --app demo --digest d1 --key soak-red-demo-d1 --quiet
rc=$?
set -e
[ "$rc" -eq 3 ] || fail "loom-missing should exit 3, got $rc"

# --- runner: stubbed loom — publish once, run keyed by the incident card ----
mkdir -p "$tmp/bin"
cat > "$tmp/bin/loom" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/loom-calls"
case "\$1" in
  ping) exit 0 ;;
  publish) exit 0 ;;
  run) printf 'id: ex-test\nstatus: running\nstate: COLLECT\n' ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/loom"

env PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
  LAST_STACK_SOAK_HEAL_STAMP="$tmp/heal-stamp.json" \
  "$RUNNER" --app demo --digest d1234567890abc --key soak-red-demo-d1234567890a --quiet \
  || fail "stubbed runner should exit 0"
grep -q '^publish' "$tmp/loom-calls" || fail "runner should publish the graph"
grep -q -- 'run heal-soak --key soak-red-demo-d1234567890a' "$tmp/loom-calls" \
  || fail "runner should key the run by the incident card"
grep -q '"max_attempts":3' "$tmp/loom-calls" || fail "input should carry max_attempts 3"
jq -e '.status == "running" and .outcome == "ok"' "$tmp/heal-stamp.json" >/dev/null \
  || fail "stamp should record the running execution"

# Repeated kick: same key again (resume, not a second incident).
env PATH="$tmp/bin:/usr/bin:/bin" HOME="$tmp" \
  LAST_STACK_SOAK_HEAL_STAMP="$tmp/heal-stamp.json" \
  "$RUNNER" --app demo --digest ffff567890abc --key soak-red-demo-d1234567890a --quiet \
  || fail "repeat kick should exit 0"
[ "$(grep -c -- 'run heal-soak --key soak-red-demo-d1234567890a' "$tmp/loom-calls")" -eq 2 ] \
  || fail "successor digest must reuse the SAME incident key"

# --- node scripts: stand-in contracts --------------------------------------
export HOST_TRACK_STAMP_DIR="$tmp/stamps"
mkdir -p "$tmp/stamps"

# collect: soak_red + attempt 0 → verdict red
jq -n '{app:"demo", digest:"d1", status:"soak_red", soak_hours:1, checks:1}' \
  > "$tmp/stamps/demo.soak.json"
out="$(LOOM_INPUT='{"app":"demo","attempt":0,"max_attempts":3}' \
  bash "$ROOT/lib/soak-loom/loom-soak-collect.sh")"
printf '%s\n' "$out" | grep -q 'LOOM_CONTEXT_PATCH:.*"verdict":"red"' \
  || fail "collect should classify red: $out"

# collect: attempt 3 → exhausted
out="$(LOOM_INPUT='{"app":"demo","attempt":3,"max_attempts":3}' \
  bash "$ROOT/lib/soak-loom/loom-soak-collect.sh")"
printf '%s\n' "$out" | grep -q '"verdict":"exhausted"' \
  || fail "collect should classify exhausted at attempt 3: $out"

# collect: no stamp → green
rm -f "$tmp/stamps/demo.soak.json"
out="$(LOOM_INPUT='{"app":"demo","attempt":1}' \
  bash "$ROOT/lib/soak-loom/loom-soak-collect.sh")"
printf '%s\n' "$out" | grep -q '"verdict":"green"' \
  || fail "collect should classify green with no stamp: $out"

# fix stand-in: effect intent/done + attempt bump, no host mutation
out="$(LOOM_INPUT='{"app":"demo","digest":"d1","attempt":0}' \
  LOOM_IDEMPOTENCY_KEY=soak-red-demo-d1 bash "$ROOT/lib/soak-loom/loom-soak-fix.sh")"
printf '%s\n' "$out" | grep -q 'LOOM_EFFECT_INTENT:' || fail "fix should declare intent"
printf '%s\n' "$out" | grep -q 'LOOM_EFFECT_DONE:' || fail "fix should declare done"
printf '%s\n' "$out" | grep -q '"attempt":1' || fail "fix should bump attempt: $out"

# report stand-in: never fails, no page without LIVE
out="$(LOOM_INPUT='{"app":"demo","digest":"d1","card":"soak-red-demo-d1"}' \
  bash "$ROOT/lib/soak-loom/loom-soak-report.sh")" || fail "report must not fail"
printf '%s\n' "$out" | grep -q 'soak heal exhausted' || fail "report should say exhausted"

printf 'ok: soak-heal loom graph, incident-keyed runner, node stand-ins\n'
