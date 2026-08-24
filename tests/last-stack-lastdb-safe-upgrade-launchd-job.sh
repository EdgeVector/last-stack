#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
CHECKS="$ROOT/skills/lastdb-safe-upgrade/scripts/launchd-job-checks.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

bash -n "$CHECKS"
bash -n "$DRIVER"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/launchd-job-checks.sh
. "$CHECKS"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-launchd-job-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A launchctl stub whose LOADED state is a file, so a test can model the real
# race: bootstrap exits nonzero while the job did (or did not) come up.
#   FAKE_RELOAD_UNAVAILABLE=1   -> `help` fails, forcing the kickstart fallback
#   FAKE_BOOTSTRAP_FAIL=1       -> every bootstrap exits 65 (the EIO shape)
#   FAKE_BOOTSTRAP_FAIL_TIMES=n -> only the first n bootstraps exit 65
#   FAKE_LOADED_FILE            -> `print` succeeds iff this file exists
#   FAKE_BOOTOUT_FAIL=1         -> bootout exits nonzero
#   FAKE_BOOTSTRAP_LOADS_ANYWAY -> a failing bootstrap still loads the job
cat >"$TMP/launchctl" <<'STUBEOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
loaded_file="${FAKE_LOADED_FILE:-}"
case "${1:-}" in
  help)
    [ "${FAKE_RELOAD_UNAVAILABLE:-0}" = "1" ] && exit 64
    exit 0
    ;;
  print)
    [ -n "$loaded_file" ] || exit 0
    [ -e "$loaded_file" ] && exit 0
    exit 113
    ;;
  bootout)
    [ "${FAKE_BOOTOUT_FAIL:-0}" = "1" ] && exit 68
    [ -n "$loaded_file" ] && rm -f "$loaded_file"
    exit 0
    ;;
  bootstrap)
    if [ "${FAKE_BOOTSTRAP_FAIL:-0}" = "1" ]; then
      # The real shape from 2026-08-23: launchd can answer EIO for a bootstrap
      # that DID take effect ("already bootstrapped"), so a caller reading the
      # exit code alone declares an outage that is not happening.
      if [ "${FAKE_BOOTSTRAP_LOADS_ANYWAY:-0}" = "1" ] && [ -n "$loaded_file" ]; then
        : >"$loaded_file"
      fi
      exit 65
    fi
    n="${FAKE_BOOTSTRAP_FAIL_TIMES:-0}"
    if [ "$n" -gt 0 ]; then
      count_file="${FAKE_BOOTSTRAP_COUNT_FILE:?}"
      tries="$(cat "$count_file" 2>/dev/null || echo 0)"
      tries=$((tries + 1))
      printf '%s\n' "$tries" >"$count_file"
      if [ "$tries" -le "$n" ]; then exit 65; fi
    fi
    [ -n "$loaded_file" ] && : >"$loaded_file"
    exit 0
    ;;
esac
exit 0
STUBEOF
chmod +x "$TMP/launchctl"
export FAKE_LAUNCHCTL_LOG="$TMP/launchctl.log"
export FAKE_LOADED_FILE="$TMP/job.loaded"
export FAKE_BOOTSTRAP_COUNT_FILE="$TMP/bootstrap.count"
export LASTDB_LAUNCHD_BOOTSTRAP_RETRY_DELAYS="0 0 0"
: >"$FAKE_LOADED_FILE"

reload_out="$(lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist")"
grep -q 'LASTDB_LAUNCHD_RESTART_PATH=job-reload' <<<"$reload_out"
grep -q '^bootout gui/501/com.test.lastdbd$' "$FAKE_LAUNCHCTL_LOG"
grep -q "^bootstrap gui/501 $TMP/primary.plist$" "$FAKE_LAUNCHCTL_LOG"
if grep -q '^kickstart' "$FAKE_LAUNCHCTL_LOG"; then
  echo "FAIL: supported reload path must not use kickstart" >&2
  exit 1
fi

: >"$FAKE_LAUNCHCTL_LOG"
fallback_out="$(FAKE_RELOAD_UNAVAILABLE=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist")"
grep -q 'LASTDB_LAUNCHD_RESTART_PATH=kickstart' <<<"$fallback_out"
grep -q '^kickstart -k gui/501/com.test.lastdbd$' "$FAKE_LAUNCHCTL_LOG"

# --- The EIO that is NOT a failure: bootstrap exits nonzero, job IS loaded ---
# launchd answers the same Input/output error for "already bootstrapped", so an
# exit code alone must never be read as an unloaded primary.
: >"$FAKE_LAUNCHCTL_LOG"
: >"$FAKE_LOADED_FILE"
already_out="$(FAKE_BOOTSTRAP_FAIL=1 FAKE_BOOTSTRAP_LOADS_ANYWAY=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist" 2>/dev/null)"
grep -q 'LASTDB_LAUNCHD_RELOAD=ok' <<<"$already_out" \
  || { echo "FAIL: bootstrap EIO with the job loaded must count as reloaded" >&2; exit 1; }

# --- The race the card is about: first bootstrap fails, a retry brings it up --
: >"$FAKE_LAUNCHCTL_LOG"
: >"$FAKE_LOADED_FILE"
: >"$FAKE_BOOTSTRAP_COUNT_FILE"
retry_out="$(FAKE_BOOTSTRAP_FAIL_TIMES=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist" 2>"$TMP/retry.err")"
grep -q 'LASTDB_LAUNCHD_RELOAD=ok' <<<"$retry_out" \
  || { echo "FAIL: a retried bootstrap must report reload ok" >&2; exit 1; }
grep -q 'LASTDB_LAUNCHD_BOOTSTRAP=recovered attempts=2' <<<"$retry_out" \
  || { echo "FAIL: recovery must name the attempt count: $retry_out" >&2; exit 1; }
grep -q 'LASTDB_LAUNCHD_BOOTSTRAP=retry attempt=1' "$TMP/retry.err" \
  || { echo "FAIL: the retry must be visible on stderr" >&2; exit 1; }
[ -e "$FAKE_LOADED_FILE" ] \
  || { echo "FAIL: the job must be loaded after the retry" >&2; exit 1; }
[ "$(grep -c '^bootstrap ' "$FAKE_LAUNCHCTL_LOG")" -ge 2 ] \
  || { echo "FAIL: expected a second bootstrap attempt" >&2; exit 1; }

# --- Terminal: every attempt fails and the job never loads --------------------
: >"$FAKE_LAUNCHCTL_LOG"
rm -f "$FAKE_LOADED_FILE"
set +e
FAKE_BOOTSTRAP_FAIL=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist" \
  >"$TMP/bootstrap.out" 2>"$TMP/bootstrap.err"
bootstrap_rc=$?
set -e
[ "$bootstrap_rc" -ne 0 ] \
  || { echo "FAIL: an unloaded job after every retry must fail" >&2; exit 1; }
grep -q 'LASTDB_LAUNCHD_RELOAD=failed step=bootstrap' "$TMP/bootstrap.err"
grep -q 'LASTDB_LAUNCHD_RECOVERY=.*bootstrap gui/501' "$TMP/bootstrap.err" \
  || { echo "FAIL: terminal failure must print the recovery command" >&2; exit 1; }
[ "$(grep -c '^bootstrap ' "$FAKE_LAUNCHCTL_LOG")" -ge 4 ] \
  || { echo "FAIL: expected the full retry ladder before giving up" >&2; exit 1; }
if grep -q '^kickstart' "$FAKE_LAUNCHCTL_LOG"; then
  echo "FAIL: a failed reload must not pretend an unloaded service can kickstart" >&2
  exit 1
fi

# --- Repairing an ALREADY unloaded primary: bootout fails, that is fine -------
: >"$FAKE_LAUNCHCTL_LOG"
rm -f "$FAKE_LOADED_FILE"
repair_out="$(FAKE_BOOTOUT_FAIL=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist" 2>/dev/null)"
grep -q 'LASTDB_LAUNCHD_BOOTOUT=already-unloaded' <<<"$repair_out" \
  || { echo "FAIL: bootout on an unloaded job must not abort the repair" >&2; exit 1; }
grep -q 'LASTDB_LAUNCHD_RELOAD=ok' <<<"$repair_out" \
  || { echo "FAIL: the repair must go on to bootstrap the job" >&2; exit 1; }

# --- But a bootout failure with the job STILL loaded is a real failure --------
: >"$FAKE_LAUNCHCTL_LOG"
: >"$FAKE_LOADED_FILE"
set +e
FAKE_BOOTOUT_FAIL=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist" \
  >/dev/null 2>"$TMP/bootout.err"
bootout_rc=$?
set -e
[ "$bootout_rc" -ne 0 ] \
  || { echo "FAIL: bootout failing on a loaded job must abort" >&2; exit 1; }
grep -q 'LASTDB_LAUNCHD_RELOAD=failed step=bootout' "$TMP/bootout.err"
if grep -q '^bootstrap ' "$FAKE_LAUNCHCTL_LOG"; then
  echo "FAIL: must not bootstrap over a job that is still loaded" >&2
  exit 1
fi

: >"$FAKE_LOADED_FILE"

cat >"$TMP/plistbuddy" <<'EOF'
#!/usr/bin/env bash
cat <<'OUT'
Dict {
    LASTDB_PRESENT = yes
    LASTDB_MISSING = yes
    PATH = /usr/bin
}
OUT
EOF
cat >"$TMP/ps" <<'EOF'
#!/usr/bin/env bash
printf 'lastdbd --data-dir /tmp LASTDB_PRESENT=yes PATH=/usr/bin\n'
EOF
chmod +x "$TMP/plistbuddy" "$TMP/ps"
export LASTDB_PLISTBUDDY_BIN="$TMP/plistbuddy"
export LASTDB_PS_BIN="$TMP/ps"

drift_out="$(lastdb_live_config_drift_check "$TMP/primary.plist" 123 2>&1)"
grep -q 'LIVE_CONFIG_DRIFT=WARN' <<<"$drift_out"
grep -q 'missing_keys=LASTDB_MISSING' <<<"$drift_out"
if grep -q 'missing_keys=.*PATH\|missing_keys=.*LASTDB_PRESENT' <<<"$drift_out"; then
  echo "FAIL: config-drift check reported keys present in the process" >&2
  exit 1
fi

set +e
LASTDB_LIVE_CONFIG_ENFORCE=1 lastdb_live_config_drift_check \
  "$TMP/primary.plist" 123 >/dev/null 2>&1
enforce_rc=$?
set -e
[ "$enforce_rc" -ne 0 ]

grep -q 'launchd-job-checks.sh' "$DRIVER"
grep -q 'LASTDB_LIVE_CONFIG_ENFORCE' "$SKILL_MD"
grep -q 'bootout.*bootstrap\|bootout.*then.*bootstrap' "$SKILL_MD"


# --- Driver: the cutover lock is released on EVERY exit path -----------------
# Recurrences 2 and 3 both leaked $SIDEBIN/.cutover.lock because `die` exits
# before the rm at the end of live_install_sidebin, and the next run then
# refused to start for 10 minutes behind a lock whose owner was long gone.
# Extract the REAL cleanup_work body and run it, rather than asserting on text.
sed -n '/^cleanup_work() {/,/^}/p' "$DRIVER" >"$TMP/cleanup_work.sh"
grep -q 'CUTOVER_LOCK' "$TMP/cleanup_work.sh" \
  || { echo "FAIL: cleanup_work does not release the cutover lock" >&2; exit 1; }

: >"$TMP/held.lock"
mkdir -p "$TMP/work-dir"
(
  set -u
  # shellcheck source=/dev/null
  . "$TMP/cleanup_work.sh"
  WORK="$TMP/work-dir"
  CUTOVER_LOCK="$TMP/held.lock"
  ROLLBACK_READY=0
  cleanup_work
)
[ ! -e "$TMP/held.lock" ] \
  || { echo "FAIL: cleanup_work left the cutover lock behind" >&2; exit 1; }
[ ! -d "$TMP/work-dir" ] \
  || { echo "FAIL: cleanup_work stopped removing the work dir" >&2; exit 1; }

# Vacuity companion: with no lock registered it must not explode or delete $WORK's parent.
mkdir -p "$TMP/work-dir2"
(
  set -u
  # shellcheck source=/dev/null
  . "$TMP/cleanup_work.sh"
  WORK="$TMP/work-dir2"
  ROLLBACK_READY=0
  cleanup_work
) || { echo "FAIL: cleanup_work must tolerate an unset CUTOVER_LOCK" >&2; exit 1; }

# The lock must be registered as soon as it is written, not at function end.
grep -A6 'CAND_VER \$ts" >"\$lock"' "$DRIVER" | grep -q 'CUTOVER_LOCK="\$lock"' \
  || { echo "FAIL: the cutover lock is not registered right after it is taken" >&2; exit 1; }

# --- Driver: an unloaded primary pages a human, before dying ----------------
grep -q 'page_human()' "$DRIVER" \
  || { echo "FAIL: driver has no page_human helper" >&2; exit 1; }
grep -B2 'die "launchd job-definition reload failed' "$DRIVER" | grep -q 'page_human' \
  || { echo "FAIL: an UNLOADED primary must page before it dies" >&2; exit 1; }
grep -q 'RA_BIN' "$DRIVER" \
  || { echo "FAIL: page_human must use the ra notify argv the fleet already uses" >&2; exit 1; }

echo "PASS: lastdb-safe-upgrade retries bootstrap, releases the cutover lock, and detects config drift"
