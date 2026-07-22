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

prompt="$($ROOT/bin/last-stack-routine-read kanban-watch)"
[ -f "$HOST_TRACK_TEST_STATE" ] || fail "routine reader did not refresh the stale artifact"
printf '%s\n' "$prompt" | grep -q 'card_batch_limit' || fail "routine reader did not return the prompt after refresh"
[ "$($ROOT/bin/last-stack-update-check)" = UP_TO_DATE ] || fail "artifact update check did not become fresh"

printf 'ok: artifact-backed routine freshness and refresh\n'
