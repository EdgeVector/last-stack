#!/usr/bin/env bash
# Ensure lastdb-safe-upgrade is packaged for multi-harness setup install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$ROOT/skills/lastdb-safe-upgrade"
skill_md="$skill/SKILL.md"
driver="$skill/scripts/safe-upgrade-lastdb.sh"

[ -f "$skill_md" ] || { echo "FAIL: missing $skill_md" >&2; exit 1; }
[ -f "$driver" ] || { echo "FAIL: missing $driver" >&2; exit 1; }
[ -x "$driver" ] || { echo "FAIL: driver not executable: $driver" >&2; exit 1; }

grep -q '^name:[[:space:]]*lastdb-safe-upgrade' "$skill_md" || {
  echo "FAIL: SKILL.md frontmatter name mismatch" >&2
  exit 1
}
# Must not hard-code Claude-only install path as the only driver location.
if grep -n 'bash ~/.claude/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh' "$skill_md" >/dev/null; then
  echo "FAIL: SKILL.md still hard-codes Claude-only driver path" >&2
  exit 1
fi
grep -q '\.last-stack/skills/lastdb-safe-upgrade' "$skill_md" || {
  echo "FAIL: SKILL.md should document last-stack install path" >&2
  exit 1
}
grep -q '\.codex/skills/lastdb-safe-upgrade' "$skill_md" || {
  echo "FAIL: SKILL.md should document Codex install path" >&2
  exit 1
}

# bash -n on driver
bash -n "$driver"

grep -q 'DEFAULT_LASTDBD_RSS_LIMIT_MB="${LASTDBD_DEFAULT_RSS_LIMIT_MB:-16384}"' "$driver" || {
  echo "FAIL: safe-upgrade driver must default the resident primary memory limit to 16384 MiB" >&2
  exit 1
}
grep -q 'ensure_primary_launchd_rss_limit' "$driver" || {
  echo "FAIL: safe-upgrade driver must stamp LASTDBD_RSS_LIMIT_MB into the primary LaunchAgent before sidebin job reload" >&2
  exit 1
}
if grep -q 'else 6144' "$skill_md"; then
  echo "FAIL: SKILL.md still documents the obsolete 6144 MiB RSS fallback" >&2
  exit 1
fi

# setup --host codex would register this name (dry structure check)
name="$(grep -m1 '^name:' "$skill_md" | sed 's/^name:[[:space:]]*//' | tr -d '[:space:]')"
[ "$name" = "lastdb-safe-upgrade" ] || {
  echo "FAIL: resolved skill name '$name'" >&2
  exit 1
}

# Candidate-class + live-scan wiring (full unit tests in sibling test file).
grep -q 'candidate-class-checks.sh' "$driver" || {
  echo "FAIL: driver must source candidate-class-checks.sh" >&2
  exit 1
}
grep -q 'binary-pair-checks.sh' "$driver" || {
  echo "FAIL: driver must source binary-pair-checks.sh" >&2
  exit 1
}
grep -q 'lastdb and lastdbd must come from the same artifact' "$driver" || {
  echo "FAIL: driver must reject daemon-only or version-skewed artifacts" >&2
  exit 1
}
grep -q 'LIVE_LAT_SCAN_MS\|live_scan_ms' "$driver" || {
  echo "FAIL: driver must track live scan latency" >&2
  exit 1
}
grep -q 'latency-bar-checks.sh' "$driver" || {
  echo "FAIL: driver must source latency-bar-checks.sh (correlated regression term)" >&2
  exit 1
}
grep -q 'lat_correlated_within_bar' "$driver" || {
  echo "FAIL: driver must call lat_correlated_within_bar" >&2
  exit 1
}
grep -q 'lat_apply_like_to_like_bars' "$driver" || {
  echo "FAIL: driver must call lat_apply_like_to_like_bars" >&2
  exit 1
}
grep -q 'lat_cold_point_ms' "$driver" || {
  echo "FAIL: driver must record lat_cold_point_ms" >&2
  exit 1
}
grep -q 'lat_hot_point_ms' "$driver" || {
  echo "FAIL: driver must record lat_hot_point_ms" >&2
  exit 1
}
grep -q 'dev-photograph-stamp-gate.sh' "$driver" || {
  echo "FAIL: driver must source dev-photograph-stamp-gate.sh" >&2
  exit 1
}
grep -q 'assert_dev_photograph_stamp_ok' "$driver" || {
  echo "FAIL: driver must call assert_dev_photograph_stamp_ok before live cutover" >&2
  exit 1
}
grep -qi 'DEV photograph' "$skill_md" || {
  echo "FAIL: SKILL.md must require a DEV photograph stamp before live cutover" >&2
  exit 1
}
grep -q 'live-socket-health.sh' "$driver" || {
  echo "FAIL: driver must source live-socket-health.sh" >&2
  exit 1
}
grep -q 'wait_for_live_unix_socket_health' "$driver" || {
  echo "FAIL: driver must wait for listener + /health after launchd reload" >&2
  exit 1
}

# The canary must request local persistence and inspect the node receipt. A
# resident read-back after a queued receipt lost one of four sentinels during
# the 2026-09-02 cutover, so either half alone is not restart proof.
grep -q 'brain put --durable --json' "$driver" || {
  echo "FAIL: durability sentinels must request durable brain writes" >&2
  exit 1
}
grep -q '\.durability == "durable"' "$driver" || {
  echo "FAIL: durability sentinels must require the node's durable receipt" >&2
  exit 1
}
grep -q 'brain put --durable --json' "$skill_md" || {
  echo "FAIL: SKILL.md must document the durable sentinel receipt" >&2
  exit 1
}

# Exercise the shipped functions against a stub brain command. The stub stores
# the exact stdin body for point-read verification. Negative receipts must stop
# before the wrapper writes its live-change marker.
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-durable-canary-test.XXXXXX")"
trap 'rm -rf -- "$test_tmp"' EXIT
mkdir -p "$test_tmp/bin" "$test_tmp/state"
apply_stub="$test_tmp/bin/brain"
cat >"$apply_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  put)
    body="$(cat)"
    slug="$(printf '%s\n' "$body" | sed -n 's/^slug:[[:space:]]*//p' | head -1)"
    [ -n "$slug" ] || exit 2
    case "${CANARY_RECEIPT_MODE:-durable}" in
      mismatch) printf '%s\n' 'nonce: stale#1' >"$CANARY_STUB_DIR/$slug" ;;
      *) printf '%s' "$body" >"$CANARY_STUB_DIR/$slug" ;;
    esac
    case "${CANARY_RECEIPT_MODE:-durable}" in
      durable|mismatch) printf '%s\n' '{"ok":true,"durability":"durable"}' ;;
      queued) printf '%s\n' '{"ok":true,"durability":"queued"}' ;;
      missing) printf '%s\n' '{"ok":true}' ;;
      malformed) printf '%s\n' 'not-json' ;;
      failed) exit 1 ;;
      *) exit 2 ;;
    esac
    ;;
  get)
    cat "$CANARY_STUB_DIR/${2:?missing slug}"
    ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$apply_stub"

export PATH="$test_tmp/bin:$PATH"
export CANARY_STUB_DIR="$test_tmp/state"
export LASTDB_DURABILITY_CANARY_N=4
export LASTDB_DURABILITY_READ_WAIT_S=1
export PRIMARY_SOCK="$test_tmp/fake.sock"
export PRIMARY_HOME="$test_tmp/home"
mkdir -p "$PRIMARY_HOME"
run_op_with_deadline() {
  shift
  "$@"
}
die() {
  printf 'DIE: %s\n' "$*" >&2
  return 1
}
log() { :; }

# Extract the exact canary variables and functions without executing the full
# upgrade driver.
eval "$(awk '
  /^DURABILITY_N=/ { capture=1 }
  /^measure_op_median_ms\(\)/ { exit }
  capture { print }
' "$driver")"

# The safe-upgrade producer must arm Fold's boot-ledger evidence before either
# venue can stop the daemon. It must remove an unconsumed marker if no start
# request succeeded, and leave a successful-start marker for the new daemon.
intent_call_line="$(grep -n '^write_upgrade_restart_intent$' "$driver" | cut -d: -f1)"
sidebin_call_line="$(grep -n '^  live_install_sidebin$' "$driver" | cut -d: -f1)"
brew_call_line="$(grep -n '^  live_install_brew$' "$driver" | cut -d: -f1)"
[ -n "$intent_call_line" ] \
  && [ "$intent_call_line" -lt "$sidebin_call_line" ] \
  && [ "$intent_call_line" -lt "$brew_call_line" ] || {
  echo "FAIL: restart intent must precede both live install paths" >&2
  exit 1
}
grep -q 'cleanup_upgrade_restart_intent' "$driver" || {
  echo "FAIL: safe-upgrade cleanup must remove an unstarted restart intent" >&2
  exit 1
}
grep -q 'RESTART_INTENT_START_REQUESTED=1' "$driver" || {
  echo "FAIL: a successful supervisor start must preserve the restart intent" >&2
  exit 1
}

canary_primary_home="$PRIMARY_HOME"
intent_home="$test_tmp/restart-intent-home"
mkdir -p "$intent_home"
printf '%s\n' '{"pid":4321}' >"$intent_home/current-session.json"
PRIMARY_HOME="$intent_home"
RESTART_INTENT_PATH=""
RESTART_INTENT_START_REQUESTED=0
write_upgrade_restart_intent
intent_file="$intent_home/restart-intent.json"
jq -e '
  (. | keys | sort) == ["cause", "created_at", "previous_pid"]
  and .cause == "upgrade"
  and .previous_pid == 4321
  and (.created_at | type) == "number"
  and .created_at > 0
' "$intent_file" >/dev/null || {
  echo "FAIL: restart intent does not match the Fold boot-ledger contract" >&2
  exit 1
}
intent_mode="$(stat -f '%Lp' "$intent_file" 2>/dev/null || stat -c '%a' "$intent_file")"
[ "$intent_mode" = 600 ] || {
  echo "FAIL: restart intent mode is $intent_mode, expected 600" >&2
  exit 1
}
cleanup_upgrade_restart_intent
[ ! -e "$intent_file" ] || {
  echo "FAIL: cleanup kept a marker when no start request succeeded" >&2
  exit 1
}

RESTART_INTENT_PATH=""
write_upgrade_restart_intent
RESTART_INTENT_START_REQUESTED=1
cleanup_upgrade_restart_intent
[ -e "$intent_file" ] || {
  echo "FAIL: cleanup removed the marker after a successful start request" >&2
  exit 1
}
rm -f "$intent_file"
PRIMARY_HOME="$canary_primary_home"
RESTART_INTENT_PATH=""
RESTART_INTENT_START_REQUESTED=0

run_receipt_case() {
  local mode="$1" expected="$2"
  local case_dir="$test_tmp/case-$mode"
  local marker="$case_dir/live-change"
  rm -rf -- "$case_dir"
  mkdir -p "$case_dir"
  export CANARY_STUB_DIR="$case_dir"
  export CANARY_RECEIPT_MODE="$mode"
  set +e
  (
    set -e
    durability_write_sentinels
    : >"$marker"
  ) >/dev/null 2>"$case_dir/stderr"
  local rc=$?
  set -e
  if [ "$expected" = pass ]; then
    [ "$rc" -eq 0 ] || {
      echo "FAIL: durable receipt case returned $rc" >&2
      cat "$case_dir/stderr" >&2
      exit 1
    }
    [ -f "$marker" ] || { echo "FAIL: durable receipt did not reach marker" >&2; exit 1; }
    [ "$(find "$case_dir" -type f -name 'lastdb-safe-upgrade-durability-canary-*' | wc -l | tr -d ' ')" = 4 ] || {
      echo "FAIL: durable receipt case did not point-read four sentinels" >&2
      exit 1
    }
  else
    [ "$rc" -ne 0 ] || { echo "FAIL: $mode receipt reached live change" >&2; exit 1; }
    [ ! -e "$marker" ] || { echo "FAIL: $mode receipt wrote live-change marker" >&2; exit 1; }
  fi
}

run_receipt_case durable pass
for mode in queued missing malformed failed mismatch; do
  run_receipt_case "$mode" fail
done

echo "OK: lastdb-safe-upgrade skill packaged for multi-harness setup"
