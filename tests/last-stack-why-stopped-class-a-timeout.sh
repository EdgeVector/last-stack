#!/usr/bin/env bash
# Class A must not fire on the 8s class-a-heal wrapper timeout when heal
# would exit 0. Timeout is not Class A by itself. result=error and
# host-track hard-broken still are.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
bin="$ROOT/bin/last-stack-why-stopped"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

chmod +x "$bin"
bash -n "$bin"

mkdir -p "$tmp/bin"
hb="$tmp/heartbeats.log"
: >"$hb"

cat >"$tmp/bin/heal" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
sleep_s="${FAKE_HEAL_SLEEP_S:-0}"
if [ "$sleep_s" != "0" ]; then
  sleep "$sleep_s"
fi
printf 'LAST_STACK_CLASS_A_HEAL result=%s detail=%s reason=why-stopped\n' \
  "${FAKE_HEAL_RESULT:-ok}" "${FAKE_HEAL_DETAIL:-already-healthy}"
exit "${FAKE_HEAL_EXIT:-0}"
SH
chmod +x "$tmp/bin/heal"

cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
fresh="${FAKE_HT_FRESHNESS:-soft_stale}"
stale=true
if [ "$fresh" = "fresh" ]; then
  stale=false
fi
problem="${FAKE_HT_PROBLEM:-}"
if [ -n "$problem" ]; then
  jq -n --arg f "$fresh" --arg p "$problem" --argjson s "$stale" \
    '{app:"last-stack",install_mode:"artifact",stale:$s,freshness:$f,artifact_problem:$p}'
else
  jq -n --arg f "$fresh" --argjson s "$stale" \
    '{app:"last-stack",install_mode:"artifact",stale:$s,freshness:$f,artifact_problem:null}'
fi
SH
chmod +x "$tmp/bin/host-track"

cat >"$tmp/bin/kanban" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' '{"ready":0,"counts":{},"cards":[]}'
SH
chmod +x "$tmp/bin/kanban"

classes_of() {
  # why-stopped --json prints JSON then ROUTINE_RESULT. First JSON object wins.
  printf '%s\n' "$1" | awk 'BEGIN{found=0} /^\{/{print; found=1; exit} END{if(!found) exit 1}'
}

has_class_a() {
  local json cls
  json="$(classes_of "$1")" || fail "no JSON in why-stopped output: $1"
  cls="$(printf '%s\n' "$json" | jq -r '.classes')"
  case "+$cls+" in
    *+A+*) return 0 ;;
  esac
  return 1
}

run_why() {
  LASTSTACK_CLASS_A_HEAL_BIN="$tmp/bin/heal" \
  LASTSTACK_WHY_STOPPED_HOST_TRACK_BIN="$tmp/bin/host-track" \
  LASTSTACK_WHY_STOPPED_KANBAN_BIN="$tmp/bin/kanban" \
  LASTSTACK_WHY_STOPPED_NO_HEARTBEAT=1 \
  LAST_STACK_HEARTBEATS_PATH="$hb" \
  LASTSTACK_WHY_STOPPED_CLASS_A_TIMEOUT_S="${LASTSTACK_WHY_STOPPED_CLASS_A_TIMEOUT_S:-8}" \
    "$bin" --json --quiet
}

# Case 1 (card END STATE): heal sleeps 10s then exits 0 → wrapper timeout
# is not Class A. Default 8s timeout. Host-track is soft-stale.
out=""
rc=0
set +e
out="$(
  FAKE_HEAL_SLEEP_S=10 \
  FAKE_HEAL_RESULT=ok \
  FAKE_HEAL_DETAIL=already-healthy \
  FAKE_HEAL_EXIT=0 \
  FAKE_HT_FRESHNESS=soft_stale \
    run_why
)"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "timeout-healthy case exit $rc out=$out"
if has_class_a "$out"; then
  fail "heal sleep 10s exit 0 must omit Class A, got: $out"
fi

# Case 2: immediate exit 0 with prompt-root-still-red → no Class A
out="$(
  FAKE_HEAL_SLEEP_S=0 \
  FAKE_HEAL_RESULT=ok \
  FAKE_HEAL_DETAIL=already-healthy \
  FAKE_HEAL_EXIT=0 \
  FAKE_HT_FRESHNESS=soft_stale \
    run_why
)"
if has_class_a "$out"; then
  fail "already-healthy/prompt-root-still-red must omit Class A, got: $out"
fi

# Case 3: heal result=error exit 1 → Class A
out="$(
  FAKE_HEAL_SLEEP_S=0 \
  FAKE_HEAL_RESULT=error \
  FAKE_HEAL_DETAIL=still-unhealthy \
  FAKE_HEAL_EXIT=1 \
  FAKE_HT_FRESHNESS=soft_stale \
    run_why
)"
has_class_a "$out" || fail "heal result=error must fire Class A, got: $out"

# Case 4: wrapper timeout + host-track hard-broken → Class A still fires.
# Short timeout keeps this case cheap; the classify path is the same.
out="$(
  LASTSTACK_WHY_STOPPED_CLASS_A_TIMEOUT_S=1 \
  FAKE_HEAL_SLEEP_S=3 \
  FAKE_HEAL_RESULT=ok \
  FAKE_HEAL_EXIT=0 \
  FAKE_HT_FRESHNESS=hard_broken \
    run_why
)"
has_class_a "$out" || fail "hard-broken after heal timeout must fire Class A, got: $out"

echo "ok last-stack-why-stopped-class-a-timeout"
