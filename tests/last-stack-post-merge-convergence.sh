#!/usr/bin/env bash
# Convergence tail: a stranded main tip (no ci-required record) gets one
# bounded hand watcher pass + a refresh — but only after the forge's own
# window, only once per tip, and never when the tip is certified. All stubs.
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
mkdir -p "$tmp/bin" "$state"

# lastgit stub: fixture-driven tip + ci state; records watch calls.
cat > "$tmp/bin/lastgit" <<EOF
#!/usr/bin/env bash
case "\$1" in
  cr) [ "\$2" = list ] && { echo '[]'; exit 0; }; exit 0 ;;
  ref) cat "$tmp/tip-\$2" 2>/dev/null || exit 1 ;;
  ci)
    case "\$2" in
      status)
        if [ -f "$tmp/certified-\$5" ]; then
          echo '{"state":"success"}'
        else
          echo 'null'
        fi
        ;;
      watch)
        printf '%s\n' "\$*" >> "$tmp/watch-calls"
        touch "$tmp/certified-\$4"
        ;;
    esac
    ;;
esac
exit 0
EOF
# host-track stub records refreshes.
cat > "$tmp/bin/host-track" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$tmp/refresh-calls"
exit 0
EOF
chmod +x "$tmp/bin/lastgit" "$tmp/bin/host-track"
touch "$tmp/watch-calls" "$tmp/refresh-calls"

# Only the situations repo has a tip in this fixture; the others are silent.
printf '%s\trefs/heads/main\tpoint\n' "abc123def456abc123def456abc123def456abc1" \
  > "$tmp/tip-situations"

run_worker() {
  env PATH="$tmp/bin:/usr/bin:/bin" \
    LAST_STACK_POST_MERGE_STATE_DIR="$state" \
    LAST_STACK_POST_MERGE_CONVERGE=1 \
    LAST_STACK_POST_MERGE_CONVERGE_AFTER=60 \
    LAST_STACK_POST_MERGE_CONVERGE_INTERVAL=0 \
    "$WORKER" --once --all "$state" >/dev/null 2>&1 || true
}

# Pass 1: first sighting — records the tip, does NOT hand-run the watcher.
run_worker
[ ! -s "$tmp/watch-calls" ] || fail "first sighting must not hand-run the watcher"
[ -f "$state/situations.tip-seen" ] || fail "first sighting should record the tip"

# Pass 2 inside the window: still no watch.
run_worker
[ ! -s "$tmp/watch-calls" ] || fail "inside the forge window must not hand-run"

# Backdate the sighting past CONVERGE_AFTER: pass 3 certifies + refreshes.
tip="$(awk '{print $1}' "$state/situations.tip-seen")"
printf '%s %s\n' "$tip" "$(( $(date +%s) - 3600 ))" > "$state/situations.tip-seen"
run_worker
grep -q -- '--repo situations' "$tmp/watch-calls" || fail "stranded tip should get a hand watcher pass"
grep -q -- '--allow-duplicate-coverage' "$tmp/watch-calls" || fail "hand run must use the documented escape hatch"
grep -q 'refresh situations' "$tmp/refresh-calls" || fail "certified tip should refresh the app"
[ ! -f "$state/situations.tip-seen" ] || fail "converged tip should clear the sighting"

# Pass 4: tip now certified — nothing more happens.
: > "$tmp/watch-calls"
run_worker
[ ! -s "$tmp/watch-calls" ] || fail "certified tip must not re-run the watcher"

# DRY_RUN: stranded again, but only logs.
rm -f "$tmp/certified-$tip"
printf '%s %s\n' "$tip" "$(( $(date +%s) - 3600 ))" > "$state/situations.tip-seen"
env PATH="$tmp/bin:/usr/bin:/bin" \
  LAST_STACK_POST_MERGE_STATE_DIR="$state" \
  LAST_STACK_POST_MERGE_CONVERGE=1 \
  LAST_STACK_POST_MERGE_CONVERGE_AFTER=60 \
  LAST_STACK_POST_MERGE_CONVERGE_INTERVAL=0 \
  LAST_STACK_POST_MERGE_DRY_RUN=1 \
  "$WORKER" --once --all "$state" >/dev/null 2>&1 || true
[ ! -s "$tmp/watch-calls" ] || fail "DRY_RUN must not hand-run the watcher"

printf 'ok: post-merge convergence tail\n'
