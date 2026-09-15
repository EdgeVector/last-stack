#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-safe-upgrade-loom"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-safe-upgrade-loom-local.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home"
touch "$tmp/pings" "$tmp/loom.log"

cat >"$tmp/bin/loom" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

log="${FAKE_LOOM_LOG:?}"
printf '%s\n' "$*" >>"$log"
case "${1:-}" in
  ping)
    count="$(sed -n '1p' "${FAKE_LOOM_PINGS:?}")"
    count="${count:-0}"
    count=$((count + 1))
    printf '%s\n' "$count" >"$FAKE_LOOM_PINGS"
    if [ "$count" -eq 1 ]; then
      exit 1
    fi
    ;;
  write-probe)
    if [ "${FAKE_LOOM_PROBE_REFUSED:-0}" -eq 1 ]; then
      printf '%s\n' '{"ok":false,"recovery_eligible":true}'
      exit 42
    fi
    ;;
  validate|publish)
    ;;
  run)
    printf '%s\n' 'lx-local-recovery' 'status: succeeded' 'state: DONE'
    ;;
  reconcile-local)
    ;;
  *)
    printf 'unexpected loom command: %s\n' "$*" >&2
    exit 2
    ;;
esac
EOF
chmod 755 "$tmp/bin/loom"

output="$({
  HOME="$tmp/home" \
  PATH="$tmp/bin:$PATH" \
  FAKE_LOOM_LOG="$tmp/loom.log" \
  FAKE_LOOM_PINGS="$tmp/pings" \
  LAST_STACK_LOOM_LOCAL_RECOVERY_DIR="$tmp/recovery" \
    "$BIN" --stand-in --json
})"

[ "$(printf '%s\n' "$output" | jq -r '.outcome')" = "ok" ] \
  || { printf '%s\n' "$output" >&2; exit 1; }
[ "$(printf '%s\n' "$output" | jq -r '.control_plane')" = "local-recovery" ] \
  || { printf '%s\n' "$output" >&2; exit 1; }
grep -q -- 'run lastdb-safe-upgrade' "$tmp/loom.log"
grep -q -- '--local-recovery' "$tmp/loom.log"
grep -q -- '--definition' "$tmp/loom.log"
grep -q -- '--local-recovery-dir' "$tmp/loom.log"
grep -q -- 'reconcile-local' "$tmp/loom.log"
! grep -q -- '^validate ' "$tmp/loom.log"
! grep -q -- '^publish ' "$tmp/loom.log"

printf '%s\n' '1' >"$tmp/pings"
: >"$tmp/loom.log"
output="$({
  HOME="$tmp/home" \
  PATH="$tmp/bin:$PATH" \
  FAKE_LOOM_LOG="$tmp/loom.log" \
  FAKE_LOOM_PINGS="$tmp/pings" \
  FAKE_LOOM_PROBE_REFUSED=1 \
  LAST_STACK_LOOM_LOCAL_RECOVERY_DIR="$tmp/recovery-probe" \
    "$BIN" --stand-in --json
})"
[ "$(printf '%s\n' "$output" | jq -r '.outcome')" = "ok" ] \
  || { printf '%s\n' "$output" >&2; exit 1; }
[ "$(printf '%s\n' "$output" | jq -r '.control_plane')" = "local-recovery" ] \
  || { printf '%s\n' "$output" >&2; exit 1; }
grep -q -- '^write-probe ' "$tmp/loom.log"
grep -q -- 'run lastdb-safe-upgrade' "$tmp/loom.log"
! grep -q -- '^validate ' "$tmp/loom.log"
! grep -q -- '^publish ' "$tmp/loom.log"

printf '%s\n' 'PASS: safe-upgrade launcher selects local Loom recovery after a failed write-plane probe'
