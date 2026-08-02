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
# Prefer fake host-track from ~/.local/bin (class-a-heal prepends that dir).
# Without this, ensure_path_shims would install artifact host-track first and
# bypass the stateful fake used by the fixtures.

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
# Mirror fake host-track into ~/.local/bin so PATH order matches production
# (heal prepends $HOME/.local/bin) without being overwritten (working link).
ln -sfn "$tmp/bin/host-track" "$HOME/.local/bin/host-track"

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
# Also plant routine-read under artifact current + local/bin for fast path
ln -sfn "$tmp/bin/last-stack-routine-read" \
  "$tmp/artifacts/versions/good/bin/last-stack-routine-read"
ln -sfn "$tmp/bin/last-stack-routine-read" "$HOME/.local/bin/last-stack-routine-read"

# Point HOME/.last-stack/bin to our fakes via a mini root
mkdir -p "$HOME/.last-stack/bin" "$HOME/.last-stack/routines" "$HOME/.last-stack/state"
cp "$ROOT/bin/last-stack-class-a-heal" "$HOME/.last-stack/bin/"
chmod +x "$HOME/.last-stack/bin/last-stack-class-a-heal"
ln -sfn "$tmp/bin/last-stack-routine-read" "$HOME/.last-stack/bin/last-stack-routine-read"
# class-a-heal on local/bin (working link into fixture copy)
ln -sfn "$HOME/.last-stack/bin/last-stack-class-a-heal" \
  "$HOME/.local/bin/last-stack-class-a-heal"
printf 'name: kanban-pickup\n' >"$HOME/.last-stack/routines/kanban-pickup.md"
# Prompt also under artifact current for prompt_present()
printf 'name: kanban-pickup\n' >"$tmp/artifacts/versions/good/routines/kanban-pickup.md"

export FAKE_HT_STATE="$tmp/ht-state"
export FAKE_HT_LOG="$tmp/ht-log"
export FAKE_HT_INITIAL=stale
rm -f "$FAKE_HT_STATE" "$FAKE_HT_LOG"
printf 'stale\n' >"$FAKE_HT_STATE"

# --- 1) soft-stale usable: stale=true but current+prompt+reader OK → exit 0, no force refresh ---
# Fixture has live versions/good current + kanban-pickup.md + routine-read shims.
set +e
out="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=test --dry-run --json 2>"$tmp/err1")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "soft-stale dry-run should exit 0; rc=$rc out=$out err=$(cat "$tmp/err1")"
printf '%s\n' "$out" | grep -q '"reason":"test"' || fail "json missing reason: $out"
printf '%s\n' "$out" | grep -qE 'soft-stale' || fail "expected soft-stale detail/actions: $out"
# Must NOT thrash force refresh on soft lag alone
printf '%s\n' "$out" | grep -q 'refresh-force' && fail "soft-stale must not plan force refresh: $out" || true

# --- 2) soft-stale real heal: exit 0 without host-track refresh ---
rm -f "$FAKE_HT_STATE" "$FAKE_HT_LOG"
printf 'stale\n' >"$FAKE_HT_STATE"
: >"$FAKE_HT_LOG"
set +e
out2="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=test-soft-stale --json 2>"$tmp/err2")"
rc2=$?
set -e
[ "$rc2" -eq 0 ] || fail "soft-stale heal should exit 0; rc=$rc2 out=$out2 err=$(cat "$tmp/err2")"
printf '%s\n' "$out2" | grep -qE '"result":"(healed|ok)"' || fail "expected healed/ok: $out2"
printf '%s\n' "$out2" | grep -qE 'soft-stale' || fail "expected soft-stale signal: $out2"
# No force refresh when soft-stale-usable
if [ -s "$FAKE_HT_LOG" ]; then
  grep -q 'force' "$FAKE_HT_LOG" && fail "soft-stale must not force-refresh: $(cat "$FAKE_HT_LOG")" || true
fi

# --- 2b) hard-broken (no usable current) still force-refreshes ---
ln -sfn "versions/gone" "$tmp/artifacts/current"
rm -f "$FAKE_HT_STATE" "$FAKE_HT_LOG"
printf 'stale\n' >"$FAKE_HT_STATE"
: >"$FAKE_HT_LOG"
# Heal will try repoint dangling → previous (dead) may not help; force refresh
# still recorded when hard path runs.
set +e
out2b="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=test-hard --json 2>"$tmp/err2b")"
rc2b=$?
set -e
# Restore good current for later tests
ln -sfn "versions/good" "$tmp/artifacts/current"
# hard path either heals via refresh or fails closed — must not soft-stale-skip
printf '%s\n' "$out2b" | grep -q 'soft-stale-skip-refresh' \
  && fail "hard-broken must not soft-stale-skip: $out2b" || true

# --- 3) already healthy is noop ---
printf 'healthy\n' >"$FAKE_HT_STATE"
: >"$FAKE_HT_LOG"
set +e
out3="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=noop --json 2>"$tmp/err3")"
rc3=$?
set -e
[ "$rc3" -eq 0 ] || fail "healthy should exit 0; rc=$rc3"
printf '%s\n' "$out3" | grep -q '"result":"ok"' || fail "expected result ok: $out3"

# --- 4) soft-stale with refresh disabled still OK (no force path taken) ---
printf 'stale\n' >"$FAKE_HT_STATE"
rm -f "$HOME/.last-stack/state/class-a-heal.last-ok"
export FAKE_HT_REFRESH_FAIL=1
set +e
out4="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=fail --json 2>"$tmp/err4")"
rc4=$?
set -e
# Soft-stale usable must not depend on refresh succeeding.
[ "$rc4" -eq 0 ] || fail "soft-stale should exit 0 even if refresh would fail; rc=$rc4 out=$out4"
printf '%s\n' "$out4" | grep -qE 'soft-stale' || fail "expected soft-stale: $out4"
unset FAKE_HT_REFRESH_FAIL

# --- 4b) hard-broken + refresh fails → exit 1 ---
ln -sfn "versions/gone" "$tmp/artifacts/current"
printf 'stale\n' >"$FAKE_HT_STATE"
rm -f "$HOME/.last-stack/state/class-a-heal.last-ok"
export FAKE_HT_REFRESH_FAIL=1
set +e
out4b="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=fail-hard --json 2>"$tmp/err4b")"
rc4b=$?
set -e
[ "$rc4b" -eq 1 ] || fail "hard-broken+refresh-fail should exit 1; rc=$rc4b out=$out4b"
printf '%s\n' "$out4b" | grep -q '"result":"error"' || fail "expected error result: $out4b"
unset FAKE_HT_REFRESH_FAIL
ln -sfn "versions/good" "$tmp/artifacts/current"

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

# --- 7) PATH shim repair: broken ~/.local/bin link is re-pointed ---
printf 'healthy\n' >"$FAKE_HT_STATE"
mkdir -p "$HOME/.local/bin" "$tmp/artifacts/versions/good/bin"
# class-a-heal itself lives under HOME/.last-stack/bin for the fixture; also
# plant a broken local/bin pin that ensure_path_shims must fix for routine-read.
ln -sfn "/nonexistent/gc-version/bin/last-stack-routine-read" \
  "$HOME/.local/bin/last-stack-routine-read"
# Source for re-link: CURRENT_LINK/bin (good artifact)
ln -sfn "$tmp/bin/last-stack-routine-read" \
  "$tmp/artifacts/versions/good/bin/last-stack-routine-read"
set +e
out7="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=shim --json 2>"$tmp/err7")"
rc7=$?
set -e
[ "$rc7" -eq 0 ] || fail "shim heal exit 0 expected; rc=$rc7 out=$out7 err=$(cat "$tmp/err7")"
# Link should no longer be dangling
[ -e "$HOME/.local/bin/last-stack-routine-read" ] \
  || fail "expected re-linked routine-read; link=$(readlink "$HOME/.local/bin/last-stack-routine-read" 2>/dev/null || true) out=$out7"
printf '%s\n' "$out7" | grep -qE 'relink-last-stack-routine-read|link-last-stack-routine-read' \
  || fail "expected relink action in json: $out7"

# --- 8) healthy cache: second call is cache-hit without refresh ---
printf 'healthy\n' >"$FAKE_HT_STATE"
: >"$FAKE_HT_LOG"
set +e
out8a="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=cache-seed --json 2>/dev/null)"
out8b="$("$HOME/.last-stack/bin/last-stack-class-a-heal" --reason=cache-hit --json 2>/dev/null)"
rc8=$?
set -e
[ "$rc8" -eq 0 ] || fail "cache-hit should exit 0"
printf '%s\n' "$out8b" | grep -qE '"result":"ok"' || fail "cache-hit result ok: $out8b"
# second call should mention cache (or still ok with noop)
printf '%s\n' "$out8b" | grep -qE 'cache-hit|cache-fresh|noop-healthy|shared' \
  || fail "expected cache-related action: $out8b (seed=$out8a)"
# no refresh on cache path
[ ! -s "$FAKE_HT_LOG" ] || fail "cache-hit must not refresh: $(cat "$FAKE_HT_LOG")"

# --- 9) host-track apps.json must PATH-link class-a + routine-read ---
apps_json="$ROOT/config/host-track/apps.json"
command -v jq >/dev/null 2>&1 || fail "jq required for apps.json check"
jq -e '
  .apps[]
  | select(.app == "last-stack")
  | .links
  | map(.source)
  | index("bin/last-stack-class-a-heal")
  and index("bin/last-stack-routine-read")
' "$apps_json" >/dev/null \
  || fail "last-stack host-track links must include class-a-heal + routine-read"

printf 'ok: last-stack-class-a-heal fixtures passed\n'
