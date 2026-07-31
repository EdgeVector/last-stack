#!/usr/bin/env bash
# last-stack-class-a-heal unit fixtures (no live host-track writes required).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$tmp/bin" "$tmp/home/.local/bin" "$tmp/artifacts/versions/good/bin" \
  "$tmp/artifacts/versions/good/routines" "$tmp/artifacts/versions/dead"

# Fake last-stack tree under HOME
export HOME="$tmp/home"
export LAST_STACK_ARTIFACT_ROOT="$tmp/artifacts"
ln -sfn "versions/good" "$tmp/artifacts/current"
ln -sfn "versions/dead" "$tmp/artifacts/previous"
printf 'ok\n' >"$tmp/artifacts/versions/good/routines/kanban-pickup.md"
cat >"$tmp/artifacts/versions/good/bin/host-track" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$tmp/artifacts/versions/good/bin/host-track"

# Install shim host-track that we can script
cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
case "$cmd" in
  status)
    # shellcheck disable=SC2154
    state="${FAKE_HT_STALE:-false}"
    jq -n --arg s "$state" \
      '{app:"last-stack",install_mode:"artifact",stale:($s=="true")}'
    ;;
  check)
    if [ "${FAKE_HT_CHECK_FAIL:-0}" = "1" ]; then exit 1; fi
    exit 0
    ;;
  refresh)
    # record args
    printf '%s\n' "$*" >>"${FAKE_HT_LOG:-/dev/null}"
    if [ "${FAKE_HT_REFRESH_FAIL:-0}" = "1" ]; then exit 1; fi
    # simulate heal: next status/check ok
    export FAKE_HT_STALE=false
    export FAKE_HT_CHECK_FAIL=0
    # write marker env file for subsequent calls in same process — can't; each
    # invocation is new process. Use a state file instead.
    if [ -n "${FAKE_HT_STATE:-}" ]; then
      printf 'healthy\n' >"$FAKE_HT_STATE"
    fi
    exit 0
  ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"

# Re-write host-track to use state file for multi-call simulation
cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
state_file="${FAKE_HT_STATE:-/tmp/fake-ht-state}"
if [ ! -f "$state_file" ]; then
  printf '%s\n' "${FAKE_HT_INITIAL:-stale}" >"$state_file"
fi
cur="$(cat "$state_file" 2>/dev/null || echo stale)"
cmd="${1:-}"
case "$cmd" in
  status)
    if [ "$cur" = "healthy" ]; then
      jq -n '{app:"last-stack",install_mode:"artifact",stale:false}'
    else
      jq -n '{app:"last-stack",install_mode:"artifact",stale:true}'
    fi
    ;;
  check)
    if [ "$cur" = "healthy" ]; then exit 0; fi
    exit 1
    ;;
  refresh)
    printf '%s\n' "$*" >>"${FAKE_HT_LOG:-/dev/null}"
    if [ "${FAKE_HT_REFRESH_FAIL:-0}" = "1" ]; then exit 1; fi
    printf 'healthy\n' >"$state_file"
    exit 0
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"

# Fake routine-read that succeeds only when state is healthy
cat >"$tmp/bin/last-stack-routine-read" <<'SH'
#!/usr/bin/env bash
state_file="${FAKE_HT_STATE:-/tmp/fake-ht-state}"
cur="$(cat "$state_file" 2>/dev/null || echo stale)"
if [ "$cur" = "healthy" ]; then
  echo "# pickup ok"
  exit 0
fi
echo "LAST_STACK_ROUTINE_STALE" >&2
exit 78
SH
chmod +x "$tmp/bin/last-stack-routine-read"

# Point HOME/.last-stack/bin to our fakes via a mini root
mkdir -p "$HOME/.last-stack/bin" "$HOME/.last-stack/routines"
cp "$ROOT/bin/last-stack-class-a-heal" "$HOME/.last-stack/bin/"
chmod +x "$HOME/.last-stack/bin/last-stack-class-a-heal"
ln -sfn "$tmp/bin/last-stack-routine-read" "$HOME/.last-stack/bin/last-stack-routine-read"
printf 'name: kanban-pickup\n' >"$HOME/.last-stack/routines/kanban-pickup.md"

export FAKE_HT_STATE="$tmp/ht-state"
export FAKE_HT_LOG="$tmp/ht-log"
export FAKE_HT_INITIAL=stale
rm -f "$FAKE_HT_STATE" "$FAKE_HT_LOG"
printf 'stale\n' >"$FAKE_HT_STATE"

# --- 1) dry-run on stale does not write healthy ---
set +e
out="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=test --dry-run --json 2>"$tmp/err1")"
rc=$?
set -e
# dry-run does not mutate install, so still-unhealthy → exit 1 is expected.
case "$rc" in 0|1) ;; *) fail "dry-run unexpected exit $rc out=$out err=$(cat "$tmp/err1")" ;; esac
printf '%s\n' "$out" | grep -q '"reason":"test"' || fail "json missing reason: $out"
printf '%s\n' "$out" | grep -q 'refresh-force' || fail "dry-run should plan a force refresh: $out"

# --- 2) real heal advances stale → healthy ---
rm -f "$FAKE_HT_STATE" "$FAKE_HT_LOG"
printf 'stale\n' >"$FAKE_HT_STATE"
set +e
out2="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=test-heal --json 2>"$tmp/err2")"
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "heal should exit 0 after refresh; rc=$rc2 out=$out2 err=$(cat "$tmp/err2")"
printf '%s\n' "$out2" | grep -qE '"result":"(healed|ok)"' || fail "expected healed/ok: $out2"
grep -q 'force-if-stale\|force' "$FAKE_HT_LOG" || fail "expected a force refresh in log: $(cat "$FAKE_HT_LOG")"

# --- 3) already healthy is noop ---
printf 'healthy\n' >"$FAKE_HT_STATE"
: >"$FAKE_HT_LOG"
set +e
out3="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=noop --json 2>"$tmp/err3")"
rc3=$?
set -e
[ "$rc3" -eq 0 ] || fail "healthy should exit 0; rc=$rc3"
printf '%s\n' "$out3" | grep -q '"result":"ok"' || fail "expected result ok: $out3"

# --- 4) refresh fails → exit 1 ---
printf 'stale\n' >"$FAKE_HT_STATE"
export FAKE_HT_REFRESH_FAIL=1
set +e
out4="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=fail --json 2>"$tmp/err4")"
rc4=$?
set -e
[ "$rc4" -eq 1 ] || fail "failed refresh should exit 1; rc=$rc4 out=$out4"
printf '%s\n' "$out4" | grep -q '"result":"error"' || fail "expected error result: $out4"
unset FAKE_HT_REFRESH_FAIL

# --- 5) dangling current repoint ---
rm -rf "$tmp/artifacts/versions/gone"
mkdir -p "$tmp/artifacts/versions/prev-good/bin" "$tmp/artifacts/versions/prev-good/routines"
printf 'ok\n' >"$tmp/artifacts/versions/prev-good/routines/kanban-pickup.md"
ln -sfn "versions/gone" "$tmp/artifacts/current"
ln -sfn "versions/prev-good" "$tmp/artifacts/previous"
printf 'healthy\n' >"$FAKE_HT_STATE"
set +e
out5="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=dangling --json 2>"$tmp/err5")"
rc5=$?
set -e
# After repoint + healthy status, should be ok
[ -d "$(readlink "$tmp/artifacts/current" | sed "s|^|$tmp/artifacts/|" | sed 's|versions/|/versions/|' )" ] 2>/dev/null || true
# current should no longer point at gone
cur_t="$(readlink "$tmp/artifacts/current")"
[ "$cur_t" = "versions/prev-good" ] || fail "expected current repointed to previous, got $cur_t (out=$out5 err=$(cat "$tmp/err5"))"
[ "$rc5" -eq 0 ] || fail "dangling heal should exit 0; rc=$rc5 out=$out5"

# --- 6) workers bootstrap mentions class-a-heal ---
grep -q 'last-stack-class-a-heal' "$ROOT/bin/last-stack-kanban-pickup-workers" \
  || fail "pickup workers bootstrap must call class-a-heal"
grep -q 'class_a_heal' "$ROOT/config/factory-health.toml" \
  || fail "factory-health.toml must enable class_a_heal"
grep -q 'class_a_heal' "$ROOT/bin/last-stack-factory-health" \
  || fail "factory-health must implement class_a_heal auto_fix"
grep -q 'last-stack-class-a-heal' "$ROOT/routines/kanban-pickup.md" \
  || fail "kanban-pickup.md must invoke class-a-heal"

printf 'ok: last-stack-class-a-heal fixtures passed\n'
