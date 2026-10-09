#!/usr/bin/env bash
# The Forgejo merge-gate runner is needed only while a repo is gated on Forgejo.
# EdgeVector/lastgit, the last one, moved to GitHub on 2026-10-08, so the lane
# policy (config/forge-runner-lanes.json) carries merge_gate.retired=true and:
#   - last-stack-fold-ci-health reports ok (detail=forge-retired) and asks launchd
#     nothing; with the flag off it still reports level=down for a missing runner;
#   - last-stack-why-stopped Class C does not fire on a stopped Forgejo runner;
#     with the flag off it still does.
# Before this change both reported a stopped com.edgevector.forgejo-runner as a
# frozen factory ("reload the launchd agent") once Forgejo was shut down.
# Fixture only: launchctl is a stub, and fold-ci-health runs from a COPY so it
# cannot append a heartbeat to the real brain.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/forge-gate-retired.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

SHIPPED="$ROOT/config/forge-runner-lanes.json"
jq -e '.merge_gate.retired == true' "$SHIPPED" >/dev/null \
  || fail "the shipped lane policy must retire the merge-gate lane"

mkdir -p "$tmp/stub" "$tmp/copy/bin" "$tmp/copy/config"
# launchctl: the Forgejo runner is NOT loaded (Forgejo is stopped). Every call is logged.
cat >"$tmp/stub/launchctl" <<'SH'
#!/usr/bin/env bash
echo "$*" >>"${STUB_LAUNCHCTL_LOG:?}"
exit 113
SH
chmod +x "$tmp/stub/launchctl"
export STUB_LAUNCHCTL_LOG="$tmp/launchctl.log"

jq '.merge_gate.retired = false' "$SHIPPED" >"$tmp/policy-gate-on.json"
jq -e '.merge_gate.retired == false' "$tmp/policy-gate-on.json" >/dev/null || fail "fixture policy"

# --- fold-ci-health (run from a copy: no heartbeat helper sits beside it) ---------
cp "$ROOT/bin/last-stack-fold-ci-health" "$tmp/copy/bin/"
chmod +x "$tmp/copy/bin/last-stack-fold-ci-health"
cp "$SHIPPED" "$tmp/copy/config/forge-runner-lanes.json"
health="$tmp/copy/bin/last-stack-fold-ci-health"

: >"$STUB_LAUNCHCTL_LOG"
out="$(PATH="$tmp/stub:$PATH" "$health")" || fail "retired gate: fold-ci-health must exit 0, got: $out"
printf '%s\n' "$out" | grep -q 'level=ok' || fail "retired gate: expected level=ok, got: $out"
printf '%s\n' "$out" | grep -q 'detail=forge-retired' || fail "retired gate: expected detail=forge-retired, got: $out"
printf '%s\n' "$out" | grep -q 'hint:' && fail "retired gate: must not hint to reload a launchd agent: $out"
[ ! -s "$STUB_LAUNCHCTL_LOG" ] || fail "retired gate: fold-ci-health asked launchd about a runner: $(cat "$STUB_LAUNCHCTL_LOG")"

json="$(PATH="$tmp/stub:$PATH" "$health" --json)" || fail "retired gate: --json must exit 0"
printf '%s\n' "$json" | jq -e '.level == "ok" and .ok == 0 and .bad == 0 and .detail == "forge-retired"' >/dev/null \
  || fail "retired gate: --json wrong: $json"

# The env seam points at another policy; the same script now reports the stopped runner.
: >"$STUB_LAUNCHCTL_LOG"
set +e
out="$(LAST_STACK_FORGE_LANES_CONFIG="$tmp/policy-gate-on.json" PATH="$tmp/stub:$PATH" "$health")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "gate on: a stopped runner must exit 1, got rc=$rc out=$out"
printf '%s\n' "$out" | grep -q 'level=down' || fail "gate on: expected level=down, got: $out"
printf '%s\n' "$out" | grep -q 'forgejo-runner=missing' || fail "gate on: expected the missing runner in the detail: $out"
grep -q 'com.edgevector.forgejo-runner' "$STUB_LAUNCHCTL_LOG" || fail "gate on: launchd was not asked about the runner"

# A policy copy in the tree (what an install carries) is read without any env seam.
cp "$tmp/policy-gate-on.json" "$tmp/copy/config/forge-runner-lanes.json"
set +e
out="$(PATH="$tmp/stub:$PATH" "$health")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "gate on (tree config): expected rc=1, got $rc out=$out"
cp "$SHIPPED" "$tmp/copy/config/forge-runner-lanes.json"

# A missing policy file must not hide a dead runner: fail closed (old behavior).
set +e
out="$(LAST_STACK_FORGE_LANES_CONFIG="$tmp/no-such-policy.json" PATH="$tmp/stub:$PATH" "$health")"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "missing policy: expected rc=1 (fail closed), got $rc out=$out"

# --- why-stopped Class C -----------------------------------------------------------
bin="$ROOT/bin/last-stack-why-stopped"
mkdir -p "$tmp/ws"
cat >"$tmp/ws/heal" <<'SH'
#!/usr/bin/env bash
printf 'LAST_STACK_CLASS_A_HEAL result=ok detail=already-healthy reason=why-stopped\n'
SH
cat >"$tmp/ws/host-track" <<'SH'
#!/usr/bin/env bash
jq -n '{app:"last-stack",install_mode:"artifact",stale:false,freshness:"fresh",artifact_problem:null}'
SH
cat >"$tmp/ws/kanban" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"ready":0,"counts":{},"cards":[]}'
SH
# `lastdb` is a stub that answers nothing, and HOME is a temp dir: why-stopped must not
# query the live node or read the live routines/heartbeat logs from a fixture test.
cat >"$tmp/stub/lastdb" <<'SH'
#!/usr/bin/env bash
exit 1
SH
cp "$tmp/stub/lastdb" "$tmp/stub/lastdbd"
chmod +x "$tmp/ws/heal" "$tmp/ws/host-track" "$tmp/ws/kanban" "$tmp/stub/lastdb" "$tmp/stub/lastdbd"
mkdir -p "$tmp/home"
: >"$tmp/hb.log"

classes_with() {  # classes_with <policy-or-empty>  -> the classes string
  local policy="${1:-}" json
  json="$(
    if [ -n "$policy" ]; then export LASTSTACK_WHY_STOPPED_FORGE_LANES_CONFIG="$policy"; fi
    PATH="$tmp/stub:$PATH" HOME="$tmp/home" \
    LASTSTACK_CLASS_A_HEAL_BIN="$tmp/ws/heal" \
    LASTSTACK_WHY_STOPPED_HOST_TRACK_BIN="$tmp/ws/host-track" \
    LASTSTACK_WHY_STOPPED_KANBAN_BIN="$tmp/ws/kanban" \
    LASTSTACK_WHY_STOPPED_NO_HEARTBEAT=1 \
    LAST_STACK_HEARTBEATS_PATH="$tmp/hb.log" \
      "$bin" --json --quiet | awk '/^\{/{print; exit}'
  )"
  [ -n "$json" ] || fail "why-stopped printed no JSON"
  printf '%s\n' "$json" | jq -r '.classes'
}
has_class() { case "+$1+" in *+"$2"+*) return 0 ;; esac; return 1; }

: >"$STUB_LAUNCHCTL_LOG"
cls="$(classes_with "")"
has_class "$cls" C && fail "retired gate: a stopped Forgejo runner must not raise Class C (classes=$cls)"
grep -q 'forgejo-runner' "$STUB_LAUNCHCTL_LOG" && fail "retired gate: why-stopped asked launchd about the Forgejo runner"

cls="$(classes_with "$tmp/policy-gate-on.json")"
has_class "$cls" C || fail "gate on: a stopped Forgejo runner must raise Class C (classes=$cls)"

echo "ok last-stack-forge-gate-retired"
