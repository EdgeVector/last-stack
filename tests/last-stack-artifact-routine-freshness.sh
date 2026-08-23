#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  exit 1
}

export HOST_TRACK_TEST_STATE="$tmp/refreshed"
export LASTSTACK_USE_HOST_TRACK_STATUS=1
export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$tmp/bin"
cat > "$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    if [ -f "$HOST_TRACK_TEST_STATE" ]; then stale=false; local_digest=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb; else stale=true; local_digest=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; fi
    jq -n --argjson stale "$stale" --arg local "$local_digest" \
      '{app:"last-stack",install_mode:"artifact",stale:$stale,manifest_digest:$local,
        channel_manifest_digest:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    ;;
  refresh)
    touch "$HOST_TRACK_TEST_STATE"
    ;;
  check)
    [ -f "$HOST_TRACK_TEST_STATE" ]
    ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"

before="$($ROOT/bin/last-stack-update-check)"
case "$before" in ARTIFACT_UPDATE_AVAILABLE*) ;; *) fail "artifact update check did not report promoted update" ;; esac

prompt="$($ROOT/bin/last-stack-routine-read kanban-watch 2>"$tmp/rr.err")"
[ ! -f "$HOST_TRACK_TEST_STATE" ] || fail "claim path must not run host-track refresh"
printf '%s\n' "$prompt" | grep -q 'card_batch_limit' || fail "routine reader did not return the prompt"
grep -q 'LAST_STACK_ROUTINE_STALE_PROCEED' "$tmp/rr.err" || fail "off-channel reader did not proceed without refresh"
[ "$($ROOT/bin/last-stack-update-check)" != UP_TO_DATE ] || fail "off-channel update-check must not be UP_TO_DATE"

# On-channel matching digest is UP_TO_DATE even if a caller still marks stale.
rm -f "$HOST_TRACK_TEST_STATE"
cat > "$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    jq -n '{app:"last-stack",install_mode:"artifact",stale:true,main_unpublished:true,
            freshness:"soft_stale",
            manifest_digest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            channel_manifest_digest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
    ;;
  refresh)
    echo "refresh must not run on matching digest" >&2
    exit 1
    ;;
  check) exit 0 ;;
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"
[ "$($ROOT/bin/last-stack-update-check)" = UP_TO_DATE ] \
  || fail "matching local==channel digest must be UP_TO_DATE"

printf 'ok: artifact-backed routine reader does not refresh on claim path\n'
