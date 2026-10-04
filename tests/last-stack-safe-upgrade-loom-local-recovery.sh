#!/usr/bin/env bash
# The safe-upgrade launcher always keeps its execution state in the local
# journal (decision-2026-10-04-safe-upgrade-always-local-journal). A slow
# primary that times out every LastDB call must not stop it: on 2026-10-04 the
# write probe, `validate`/`publish`, and the `loom run` execution write each
# timed out at 60 s on a thrashing primary, and the upgrade that carried the
# fix never reached its first probe
# (papercut-safe-upgrade-blocked-by-slow-primary-write-timeouts-20261004).
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
BIN="$ROOT/bin/last-stack-safe-upgrade-loom"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-safe-upgrade-loom-local.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/home"
: >"$tmp/loom.log"

# Every command that needs the LastDB node fails like the 2026-10-04 primary.
# Only the local run and the post-run reconcile are expected.
cat >"$tmp/bin/loom" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
log="${FAKE_LOOM_LOG:?}"
printf '%s\n' "$*" >>"$log"
case "${1:-}" in
  ping|write-probe|validate|publish|show)
    printf '%s\n' 'Error: lastdb POST /api/mutation timed out after 60s' >&2
    exit 1
    ;;
  run)
    [ -z "${LOOM_EXEC_ID:-}" ] || { echo 'inherited LOOM_EXEC_ID reached loom run' >&2; exit 2; }
    case " $* " in *' --local-recovery '*) ;; *) echo 'run without --local-recovery' >&2; exit 2 ;; esac
    printf '%s\n' 'lx-local-recovery' "status: ${FAKE_LOOM_RUN_STATUS:-succeeded}" 'state: DONE'
    ;;
  reconcile-local)
    [ "${FAKE_LOOM_RECONCILE_FAILS:-0}" -eq 0 ] || exit 1
    ;;
  *)
    printf 'unexpected loom command: %s\n' "$*" >&2
    exit 2
    ;;
esac
SH
chmod 755 "$tmp/bin/loom"

# A launcher that exits non-zero must fail the NAMED case, not a bare set -e.
# The launcher's stderr goes to $tmp/err; the FAIL line goes to the real stderr.
run_case() {
  local case_name="$1"; shift
  set +e
  output="$("$@" 2>"$tmp/err")"
  local rc=$?
  set -e
  [ "$rc" -eq 0 ] || { printf 'FAIL %s: launcher rc=%s output=%s stderr=%s\n' "$case_name" "$rc" "$output" "$(cat "$tmp/err")" >&2; exit 1; }
}

run_launcher() {
  HOME="$tmp/home" \
  PATH="$tmp/bin:$PATH" \
  FAKE_LOOM_LOG="$tmp/loom.log" \
  LAST_STACK_LOOM_LOCAL_RECOVERY_DIR="$tmp/recovery" \
    "$BIN" --stand-in --json
}

# 1. Every LastDB call times out: the launcher still runs locally and never
#    touches the node before the run.
run_case "case 1" run_launcher
[ "$(printf '%s\n' "$output" | jq -r '.outcome')" = ok ] \
  || { printf 'FAIL case 1: %s\n' "$output" >&2; exit 1; }
[ "$(printf '%s\n' "$output" | jq -r '.control_plane')" = local-recovery ] \
  || { printf 'FAIL case 1 control plane: %s\n' "$output" >&2; exit 1; }
grep -q -- '--local-recovery-dir' "$tmp/loom.log"
grep -q -- '--definition' "$tmp/loom.log"
grep -q -- '^reconcile-local ' "$tmp/loom.log"
for verb in ping write-probe validate publish show; do
  if grep -q -- "^$verb" "$tmp/loom.log"; then
    echo "FAIL case 1: the launcher called loom $verb, which needs the LastDB node" >&2
    exit 1
  fi
done

# 2. An inherited parent execution id must not reach `loom run --local-recovery`
#    (loom refuses a local run under a parent).
: >"$tmp/loom.log"
LOOM_EXEC_ID=lx-parent run_case "case 2" run_launcher
[ "$(printf '%s\n' "$output" | jq -r '.outcome')" = ok ] \
  || { printf 'FAIL case 2: %s\n' "$output" >&2; exit 1; }

# 3. A failed reconcile is a report, not a gate: the run result stands.
: >"$tmp/loom.log"
FAKE_LOOM_RECONCILE_FAILS=1 run_case "case 3" run_launcher
[ "$(printf '%s\n' "$output" | jq -r '.outcome')" = ok ] \
  || { printf 'FAIL case 3: %s\n' "$output" >&2; exit 1; }
grep -q 'pending reconciliation' "$tmp/err" \
  || { echo 'FAIL case 3: no pending-reconciliation notice' >&2; exit 1; }

# 4. A non-succeeded local run is RED (exit 3) and is not reconciled as ok.
: >"$tmp/loom.log"
set +e
output="$(FAKE_LOOM_RUN_STATUS=failed run_launcher 2>/dev/null)"
rc=$?
set -e
[ "$rc" -eq 3 ] && [ "$(printf '%s\n' "$output" | jq -r '.outcome')" = error ] \
  || { printf 'FAIL case 4: rc=%s %s\n' "$rc" "$output" >&2; exit 1; }
if grep -q -- '^reconcile-local ' "$tmp/loom.log"; then
  echo 'FAIL case 4: a failed run was reconciled' >&2
  exit 1
fi

printf '%s\n' 'PASS: safe-upgrade launcher always runs on the local journal, even when every LastDB call times out'
