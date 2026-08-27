#!/usr/bin/env bash
# ship-soak: initial run, same-key tick resume, terminal retirement, and the
# hard per-tick bound. The fixture uses a Loom stub and isolated state.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-ship-soak-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

RUNNER="$ROOT/bin/last-stack-ship-soak-loom"
TICK="$ROOT/bin/last-stack-ship-soak-tick"
mkdir -p "$tmp/bin" "$tmp/definitions" "$tmp/scripts" "$tmp/state" "$tmp/home"
printf '{}\n' > "$tmp/definitions/land-cr.json"
printf '{}\n' > "$tmp/definitions/ship-soak.json"
touch "$tmp/scripts/loom-ship-soak-verify.sh" "$tmp/scripts/loom-implement.sh"
printf 'waiting\n' > "$tmp/status"
printf 'SOAK_WAIT\n' > "$tmp/state-name"

cat > "$tmp/bin/loom" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/loom-calls"
case "\$1" in
  ping|publish) exit 0 ;;
  run)
    status="\$(cat "$tmp/status")"
    state="\$(cat "$tmp/state-name")"
    printf 'lx-ship-test-1\nid: lx-ship-test-1\nstatus: %s\nstate: %s\n' "\$status" "\$state"
    ;;
esac
exit 0
EOF
chmod +x "$tmp/bin/loom"

common_env=(
  PATH="$tmp/bin:$PATH"
  HOME="$tmp/home"
  LAST_STACK_SHIP_SOAK_STATE_DIR="$tmp/state"
  LOOM_SHIP_DEFS="$tmp/definitions"
  LOOM_SHIP_SCRIPTS="$tmp/scripts"
)

input='{"app":"demo","private_note":"input-must-not-enter-state"}'
env "${common_env[@]}" "$RUNNER" --app demo --key ship-demo-1 --input "$input" --quiet \
  || fail "initial ship-soak run should pass"
grep -q '^publish .*/land-cr.json$' "$tmp/loom-calls" \
  || fail "runner should publish land-cr before use"
grep -q '^publish .*/ship-soak.json$' "$tmp/loom-calls" \
  || fail "runner should publish ship-soak before use"
grep -q '^run ship-soak --key ship-demo-1 --input ' "$tmp/loom-calls" \
  || fail "runner should use the requested idempotency key"

registration="$(find "$tmp/state" -maxdepth 1 -name '*.json' -print -quit)"
[ -n "$registration" ] || fail "runner should write one registration"
jq -e '
  .schema_version == 1
  and .app == "demo"
  and .key == "ship-demo-1"
  and .execution_id == "lx-ship-test-1"
  and .status == "waiting"
  and .state == "SOAK_WAIT"
  and .active == true
' "$registration" >/dev/null || fail "active registration is wrong"
if grep -q 'input-must-not-enter-state' "$registration"; then
  fail "registration must not persist graph input"
fi

# The Host Track tick resumes the same key with an empty retry input. Loom
# resolves the existing execution before it validates the definition input.
env "${common_env[@]}" LAST_STACK_SHIP_SOAK_RUNNER="$RUNNER" \
  "$TICK" --app demo --quiet || fail "same-key tick should pass"
[ "$(grep -c '^run ship-soak --key ship-demo-1' "$tmp/loom-calls")" -eq 2 ] \
  || fail "tick should resume the same execution once"
tail -1 "$tmp/loom-calls" | grep -q -- '--input {}' \
  || fail "a resume should not need the original graph input"

# A terminal view retires the registration. Later ticks skip it.
printf 'succeeded\n' > "$tmp/status"
printf 'DONE\n' > "$tmp/state-name"
env "${common_env[@]}" LAST_STACK_SHIP_SOAK_RUNNER="$RUNNER" \
  "$TICK" --app demo --quiet || fail "terminal tick should pass"
jq -e '.status == "succeeded" and .state == "DONE" and .active == false' \
  "$registration" >/dev/null || fail "terminal registration should be inactive"
runs_before="$(grep -c '^run ship-soak --key ship-demo-1' "$tmp/loom-calls")"
env "${common_env[@]}" LAST_STACK_SHIP_SOAK_RUNNER="$RUNNER" \
  "$TICK" --app demo --quiet || fail "inactive tick should be a noop"
[ "$(grep -c '^run ship-soak --key ship-demo-1' "$tmp/loom-calls")" -eq "$runs_before" ] \
  || fail "inactive execution should not run again"

# Two active records with a one-run bound must invoke only one resume.
for n in 1 2; do
  jq -n --arg key "bounded-$n" \
    '{schema_version:1, app:"bounded", key:$key, execution_id:"lx", status:"waiting",
      state:"SOAK_WAIT", active:true, updated_at:"t"}' > "$tmp/state/bounded-$n.json"
done
cat > "$tmp/bounded-runner" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/bounded-calls"
exit 0
EOF
chmod +x "$tmp/bounded-runner"
env PATH="$PATH" HOME="$tmp/home" LAST_STACK_SHIP_SOAK_STATE_DIR="$tmp/state" \
  LAST_STACK_SHIP_SOAK_RUNNER="$tmp/bounded-runner" LAST_STACK_SHIP_SOAK_TICK_MAX=1 \
  "$TICK" --app bounded --quiet || fail "bounded tick should pass"
[ "$(wc -l < "$tmp/bounded-calls" | tr -d ' ')" -eq 1 ] \
  || fail "tick must honor its hard per-run bound"

printf 'ok: ship-soak start, same-key tick resume, terminal retirement, hard bound\n'
