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

cat >"$TMP/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
if [ "${1:-}" = "help" ] && [ "${FAKE_RELOAD_UNAVAILABLE:-0}" = "1" ]; then
  exit 64
fi
if [ "${1:-}" = "bootstrap" ] && [ "${FAKE_BOOTSTRAP_FAIL:-0}" = "1" ]; then
  exit 65
fi
EOF
chmod +x "$TMP/launchctl"
export FAKE_LAUNCHCTL_LOG="$TMP/launchctl.log"

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

: >"$FAKE_LAUNCHCTL_LOG"
set +e
FAKE_BOOTSTRAP_FAIL=1 lastdb_launchd_reload_job \
  "$TMP/launchctl" gui/501 com.test.lastdbd "$TMP/primary.plist" \
  >"$TMP/bootstrap.out" 2>"$TMP/bootstrap.err"
bootstrap_rc=$?
set -e
[ "$bootstrap_rc" -ne 0 ]
grep -q 'LASTDB_LAUNCHD_RELOAD=failed step=bootstrap' "$TMP/bootstrap.err"
if grep -q '^kickstart' "$FAKE_LAUNCHCTL_LOG"; then
  echo "FAIL: a failed reload must not pretend an unloaded service can kickstart" >&2
  exit 1
fi

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

echo "PASS: lastdb-safe-upgrade reloads launchd jobs and detects config drift"
