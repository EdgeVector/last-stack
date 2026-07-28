#!/usr/bin/env bash
# A pointer-stale-but-self-consistent skill-pack must NEVER stop the fleet.
# When the in-process refresh cannot heal (e.g. a sandboxed routine cannot write
# ~/.local/bin), routine-read proceeds on the current skill-pack with a loud
# warning while the out-of-band auto-refresh catches up. Genuine content
# corruption (pointer current, content bad) still hard-blocks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
tmp="$(mktemp -d)"
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT
fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

export LASTSTACK_USE_HOST_TRACK_STATUS=1
export PATH="$tmp/bin:/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"
mkdir -p "$tmp/bin"

# --- Scenario 1: pointer-stale, refresh + check always fail -> PROCEED ---
cat > "$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    jq -n '{app:"last-stack",install_mode:"artifact",stale:true,
            manifest_digest:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            channel_manifest_digest:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}'
    ;;
  refresh) echo "host-track: Operation not permitted" >&2; exit 1 ;;  # sandbox cannot write ~/.local/bin
  check)   exit 1 ;;                                                   # still behind
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"

set +e
out="$("$ROOT/bin/last-stack-routine-read" kanban-watch 2>"$tmp/err")"
rc=$?
set -e
[ "$rc" -eq 0 ] || fail "stale-but-unhealable routine-read blocked (exit $rc) instead of proceeding"
grep -q 'LAST_STACK_ROUTINE_STALE_PROCEED' "$tmp/err" || fail "did not emit the proceed-on-stale warning"
printf '%s\n' "$out" | grep -q 'card_batch_limit' || fail "did not return the prompt after proceeding"
grep -q 'LAST_STACK_ROUTINE_STALE ' "$tmp/err" && fail "hard-blocked (stale_fail) on a merely-stale skill-pack"

# --- Scenario 2: pointer CURRENT but content bad (corrupt) -> HARD BLOCK ---
cat > "$tmp/bin/host-track" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  status)
    jq -n '{app:"last-stack",install_mode:"artifact",stale:false,
            manifest_digest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            channel_manifest_digest:"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"}'
    ;;
  refresh) exit 1 ;;   # --force cannot fix corruption
  check)   exit 1 ;;   # content still bad
  *) exit 2 ;;
esac
SH
chmod +x "$tmp/bin/host-track"

set +e
"$ROOT/bin/last-stack-routine-read" kanban-watch >/dev/null 2>"$tmp/err2"
rc2=$?
set -e
[ "$rc2" -ne 0 ] || fail "corrupt skill-pack was allowed to proceed instead of blocking"
grep -q 'LAST_STACK_ROUTINE_STALE ' "$tmp/err2" || fail "corrupt case did not hard-block via stale_fail"

printf 'ok: routine-read proceeds on stale-but-valid, blocks on corrupt\n'
