#!/usr/bin/env bash
# A quiet repository's exact main tip gets a real gate run. The fixture uses a
# real Git remote and executes its checked-out .lastgit/ci.sh; no stub grants a
# success verdict without that gate.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-converge-test.XXXXXX")"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

WORKER="$ROOT/bin/last-stack-post-merge-safe-upgrade"
state="$tmp/state"
remote="$tmp/quiet.git"
seed="$tmp/seed"
mkdir -p "$tmp/bin" "$tmp/status" "$tmp/artifacts" "$state"
git init -q --bare "$remote"
git init -q "$seed"
git -C "$seed" checkout -q -b main
git -C "$seed" config user.name fixture
git -C "$seed" config user.email fixture@example.invalid
git -C "$seed" remote add origin "$remote"
mkdir -p "$seed/.lastgit"

cat >"$seed/.lastgit/ci.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
oid="$(git rev-parse HEAD)"
printf '%s\n' "$oid" >>"$QUIET_GATE_LOG"
[ ! -f FAIL_GATE ] || exit 23
printf '%s\n' "$oid" >"$QUIET_ARTIFACT_ROOT/$oid"
SH
chmod +x "$seed/.lastgit/ci.sh"
printf 'initial\n' >"$seed/payload.txt"
git -C "$seed" add -A
git -C "$seed" commit -qm initial
git -C "$seed" push -q origin main

push_tip() {
  local label="$1" gate_result="${2:-pass}"
  printf '%s\n' "$label" >>"$seed/payload.txt"
  if [ "$gate_result" = fail ]; then
    printf 'fail\n' >"$seed/FAIL_GATE"
  else
    rm -f "$seed/FAIL_GATE"
  fi
  git -C "$seed" add -A
  git -C "$seed" commit -qm "$label"
  git -C "$seed" push -q origin main
  git -C "$seed" rev-parse HEAD
}

cat >"$tmp/bin/lastgit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail

case "${1:-}:${2:-}" in
  cr:list)
    printf '[]\n'
    exit 0
    ;;
  ci:status)
    oid="$3"
    if [ -f "$QUIET_STATUS_DIR/$oid" ]; then
      state="$(cat "$QUIET_STATUS_DIR/$oid")"
      printf '{"state":"%s"}\n' "$state"
    else
      printf 'null\n'
    fi
    exit 0
    ;;
  ci:run)
    repo=""
    oid=""
    shift 2
    while [ $# -gt 0 ]; do
      case "$1" in
        --repo) repo="$2"; shift 2 ;;
        --oid) oid="$2"; shift 2 ;;
        --context|--timeout-ms) shift 2 ;;
        --json) shift ;;
        *) shift ;;
      esac
    done
    [ "$repo" = situations ] || exit 2
    [ -n "$oid" ] || exit 2
    git --git-dir="$QUIET_REMOTE" cat-file -e "$oid^{commit}"
    printf '%s %s\n' "$repo" "$oid" >>"$QUIET_CI_RUN_LOG"
    remaining="$(cat "$QUIET_CI_RUN_FAILS" 2>/dev/null || printf 0)"
    if [ "$remaining" -gt 0 ]; then
      printf '%s\n' "$((remaining - 1))" >"$QUIET_CI_RUN_FAILS"
      exit 75
    fi
    checkout="$(mktemp -d "${TMPDIR:-/tmp}/quiet-ci-run.XXXXXX")"
    git clone -q "$QUIET_REMOTE" "$checkout"
    git -C "$checkout" checkout -q --detach "$oid"
    if (cd "$checkout" && .lastgit/ci.sh); then
      printf 'success\n' >"$QUIET_STATUS_DIR/$oid"
      printf '{"state":"success","oid":"%s"}\n' "$oid"
    else
      printf 'failure\n' >"$QUIET_STATUS_DIR/$oid"
      printf '{"state":"failure","oid":"%s"}\n' "$oid"
      rm -rf "$checkout"
      exit 1
    fi
    rm -rf "$checkout"
    exit 0
    ;;
esac

if [ "${1:-}" = ref ] && [ "${3:-}" = main ] && [ "${2:-}" = situations ]; then
  oid="$(git --git-dir="$QUIET_REMOTE" rev-parse refs/heads/main)"
  printf '%s\trefs/heads/main\tpoint\n' "$oid"
  exit 0
fi
exit 1
SH

cat >"$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = status ] && [ "${2:-}" = --json ]; then
  app="${3:-}"
  mode="$(cat "$QUIET_HOST_MODE" 2>/dev/null || printf fresh)"
  if [ "$app" != situations ]; then mode=fresh; fi
  case "$mode" in
    eligible) printf '{"install_mode":"artifact","stale":false,"main_unpublished":true}\n' ;;
    stale) printf '{"install_mode":"artifact","stale":true,"main_unpublished":true}\n' ;;
    *) printf '{"install_mode":"artifact","stale":false,"main_unpublished":false}\n' ;;
  esac
  exit 0
fi
if [ "${1:-}" = refresh ]; then
  printf '%s\n' "$*" >>"$QUIET_REFRESH_LOG"
  printf 'fresh\n' >"$QUIET_HOST_MODE"
  exit 0
fi
exit 2
SH
chmod +x "$tmp/bin/lastgit" "$tmp/bin/host-track"
touch "$tmp/gate.log" "$tmp/ci-run.log" "$tmp/refresh.log"
printf '0\n' >"$tmp/ci-run-fails"

run_worker() {
  env PATH="$tmp/bin:/usr/bin:/bin" \
    QUIET_REMOTE="$remote" \
    QUIET_STATUS_DIR="$tmp/status" \
    QUIET_ARTIFACT_ROOT="$tmp/artifacts" \
    QUIET_GATE_LOG="$tmp/gate.log" \
    QUIET_CI_RUN_LOG="$tmp/ci-run.log" \
    QUIET_CI_RUN_FAILS="$tmp/ci-run-fails" \
    QUIET_REFRESH_LOG="$tmp/refresh.log" \
    QUIET_HOST_MODE="$tmp/host-mode" \
    LAST_STACK_POST_MERGE_STATE_DIR="$state" \
    LAST_STACK_POST_MERGE_CONVERGE=1 \
    LAST_STACK_POST_MERGE_CONVERGE_AFTER=60 \
    LAST_STACK_POST_MERGE_CONVERGE_INTERVAL=0 \
    LAST_STACK_POST_MERGE_CONVERGE_TIMEOUT=20 \
    LAST_STACK_POST_MERGE_MAX_ATTEMPTS=2 \
    "$WORKER" --once --all "$state" >/dev/null 2>&1 || true
}

backdate_tip() {
  local tip="$1"
  printf '%s %s\n' "$tip" "$(( $(date +%s) - 3600 ))" >"$state/situations.tip-seen"
}

# The quiet tip has no later ref event. First sight waits; the next eligible
# pass runs its checked-out gate, records success, and refreshes the app.
tip1="$(git -C "$seed" rev-parse HEAD)"
printf 'eligible\n' >"$tmp/host-mode"
run_worker
[ -f "$state/situations.tip-seen" ] || fail "first sighting should record the tip"
[ ! -s "$tmp/ci-run.log" ] || fail "first sighting must not run CI"
backdate_tip "$tip1"
run_worker
grep -qx "situations $tip1" "$tmp/ci-run.log" || fail "CI did not target the exact quiet tip"
grep -qx "$tip1" "$tmp/gate.log" || fail "the real fixture gate did not run at the exact tip"
[ -f "$tmp/artifacts/$tip1" ] || fail "the real gate did not publish its artifact"
[ "$(cat "$tmp/status/$tip1")" = success ] || fail "the exact tip did not receive success"
grep -q '^refresh situations$' "$tmp/refresh.log" || fail "successful certification did not refresh"

# stale=true is not the quiet-tip state. It must not start an exact CI run.
tip2="$(push_tip second)"
printf 'stale\n' >"$tmp/host-mode"
before="$(wc -l <"$tmp/ci-run.log" | tr -d ' ')"
run_worker
[ "$(wc -l <"$tmp/ci-run.log" | tr -d ' ')" = "$before" ] || fail "stale app ran convergence"
[ ! -f "$state/situations.tip-seen" ] || fail "ineligible state retained a sighting"

# A transport failure with no terminal status retries only to the configured
# cap. The exact-object command never depends on an event cursor.
tip3="$(push_tip retry)"
printf 'eligible\n' >"$tmp/host-mode"
printf '2\n' >"$tmp/ci-run-fails"
run_worker
backdate_tip "$tip3"
run_worker
run_worker
after_two="$(wc -l <"$tmp/ci-run.log" | tr -d ' ')"
run_worker
[ "$(wc -l <"$tmp/ci-run.log" | tr -d ' ')" = "$after_two" ] || fail "retry cap allowed a third CI run"
grep -q "GIVE_UP converge repo=situations tip=$tip3 after 2 attempts" "$state/post-merge.log" \
  || fail "retry exhaustion was not visible"

# A real gate failure writes a terminal failure and never refreshes or reruns.
tip4="$(push_tip terminal-failure fail)"
printf 'eligible\n' >"$tmp/host-mode"
printf '0\n' >"$tmp/ci-run-fails"
run_worker
backdate_tip "$tip4"
refresh_before="$(wc -l <"$tmp/refresh.log" | tr -d ' ')"
run_worker
[ "$(cat "$tmp/status/$tip4")" = failure ] || fail "failing gate was not visible as failure"
ci_before="$(wc -l <"$tmp/ci-run.log" | tr -d ' ')"
run_worker
[ "$(wc -l <"$tmp/ci-run.log" | tr -d ' ')" = "$ci_before" ] || fail "terminal failure reran"
[ "$(wc -l <"$tmp/refresh.log" | tr -d ' ')" = "$refresh_before" ] || fail "terminal failure refreshed"

printf 'ok: post-merge convergence certifies the exact quiet main tip\n'
