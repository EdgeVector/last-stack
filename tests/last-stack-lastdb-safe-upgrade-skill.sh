#!/usr/bin/env bash
# Ensure lastdb-safe-upgrade is packaged for multi-harness setup install.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
skill="$ROOT/skills/lastdb-safe-upgrade"
skill_md="$skill/SKILL.md"
driver="$skill/scripts/safe-upgrade-lastdb.sh"
dev_gate="$skill/scripts/dev-photograph-stamp-gate.sh"
dev_proof="$skill/scripts/dev-photograph-candidate-proof.sh"

[ -f "$skill_md" ] || { echo "FAIL: missing $skill_md" >&2; exit 1; }
[ -f "$driver" ] || { echo "FAIL: missing $driver" >&2; exit 1; }
[ -x "$driver" ] || { echo "FAIL: driver not executable: $driver" >&2; exit 1; }
[ -x "$dev_gate" ] || { echo "FAIL: DEV gate not executable: $dev_gate" >&2; exit 1; }
[ -x "$dev_proof" ] || { echo "FAIL: DEV proof not executable: $dev_proof" >&2; exit 1; }

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
bash -n "$dev_gate"
bash -n "$dev_proof"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/dev-photograph-stamp-gate.sh
. "$dev_gate"

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
grep -q 'dev-photograph-candidate-proof.sh' "$driver" || {
  echo "FAIL: driver must invoke the exact-candidate DEV proof helper" >&2
  exit 1
}
grep -q -- '--clone-source "$BACKUP"' "$driver" || {
  echo "FAIL: driver must clone the rollback point selected by this safe-upgrade sequence" >&2
  exit 1
}
grep -q 'lastdb-restore-probe-invite-dev-20260720' "$dev_proof" || {
  echo "FAIL: DEV proof must use the fixed LastSecrets invite slug" >&2
  exit 1
}
grep -q 'env -u LASTDB_HOME -u FOLDDB_HOME -u FOLD_SYNC_DEVICE_ID' "$dev_proof" || {
  echo "FAIL: DEV proof must unset all three home/device overrides" >&2
  exit 1
}
for residue in current-session.json laststore_backup_known_present.json laststore_backup_manifest.json 'cloud_sync.json\*'; do
  grep -q "$residue" "$dev_proof" || {
    echo "FAIL: DEV proof does not scrub $residue" >&2
    exit 1
  }
done
grep -qi 'DEV photograph' "$skill_md" || {
  echo "FAIL: SKILL.md must require a DEV photograph stamp before live cutover" >&2
  exit 1
}

proof_call_line="$(grep -n 'DEV_PROOF_OUT=.*DEV_PHOTOGRAPH_PROOF_SH' "$driver" | head -1 | cut -d: -f1)"
live_marker_line="$(grep -n '^durability_write_sentinels$' "$driver" | tail -1 | cut -d: -f1)"
[ -n "$proof_call_line" ] && [ -n "$live_marker_line" ] \
  && [ "$proof_call_line" -lt "$live_marker_line" ] || {
  echo "FAIL: exact-candidate DEV proof must precede the first live write" >&2
  exit 1
}
venue_gate_line="$(grep -n '^assert_exact_candidate_live_venue$' "$driver" | tail -1 | cut -d: -f1)"
final_binding_line="$(grep -n '^assert_final_candidate_binding$' "$driver" | tail -1 | cut -d: -f1)"
[ -n "$venue_gate_line" ] && [ "$venue_gate_line" -lt "$live_marker_line" ] || {
  echo "FAIL: brew refusal must precede the first live write" >&2
  exit 1
}
[ -n "$final_binding_line" ] && [ "$final_binding_line" -lt "$live_marker_line" ] || {
  echo "FAIL: final candidate binding must precede the first live write" >&2
  exit 1
}

# Exercise the two small fail-closed gates without the full live driver.
eval "$(awk '
  /^assert_exact_candidate_live_venue\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$driver")"
eval "$(awk '
  /^assert_final_candidate_binding\(\)/ { capture=1 }
  capture { print }
  capture && /^}/ { exit }
' "$driver")"
die() { printf 'DIE: %s\n' "$*" >&2; return 1; }
VENUE=sidebin
assert_exact_candidate_live_venue \
  || { echo "FAIL: sidebin venue was refused" >&2; exit 1; }
VENUE=brew
set +e
venue_out="$(assert_exact_candidate_live_venue 2>&1)"
venue_rc=$?
set -e
[ "$venue_rc" -ne 0 ] && printf '%s\n' "$venue_out" | grep -q 'unphotographed bytes' || {
  echo "FAIL: brew venue did not fail closed before live mutation" >&2
  exit 1
}
CANDIDATE_BIN=/candidate/lastdbd
CANDIDATE_CLI_BIN=/candidate/lastdb
LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_candidate_binding_matches_expected() { return 1; }
LASTDB_PROBE_DEV_STAMP_SKIP=1
set +e
binding_out="$(assert_final_candidate_binding 2>&1)"
binding_rc=$?
set -e
[ "$binding_rc" -ne 0 ] && printf '%s\n' "$binding_out" | grep -q 'candidate pair changed' || {
  echo "FAIL: DEV receipt waiver also waived the final candidate binding" >&2
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
grep -q 'queued+readback' "$driver" || {
  echo "FAIL: durability sentinels must declare queued+readback for HTTP 400" >&2
  exit 1
}
grep -q 'durability_mode=' "$driver" || {
  echo "FAIL: Situations notice must record durability_mode" >&2
  exit 1
}
grep -q 'brain put --durable --json' "$skill_md" || {
  echo "FAIL: SKILL.md must document the durable sentinel receipt" >&2
  exit 1
}
grep -q 'queued+readback' "$skill_md" || {
  echo "FAIL: SKILL.md must document queued+readback when --durable returns HTTP 400" >&2
  exit 1
}

# Exercise the shipped functions against a stub brain command. The stub stores
# the exact stdin body for point-read verification. Negative receipts must stop
# before the wrapper writes its live-change marker.
test_tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-durable-canary-test.XXXXXX")"
dev_proof_tmp_root="/tmp/dp.$$"
trap 'rm -rf -- "$test_tmp" "$dev_proof_tmp_root"' EXIT
test_tmp="$(CDPATH= cd -- "$test_tmp" && pwd -P)"
mkdir -p "$test_tmp/bin" "$test_tmp/state"
apply_stub="$test_tmp/bin/brain"
cat >"$apply_stub" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
durable=0
for arg in "$@"; do
  [ "$arg" = "--durable" ] && durable=1
done
case "${1:-}" in
  put)
    body="$(cat)"
    slug="$(printf '%s\n' "$body" | sed -n 's/^slug:[[:space:]]*//p' | head -1)"
    [ -n "$slug" ] || exit 2
    case "${CANARY_RECEIPT_MODE:-durable}" in
      http400)
        if [ "$durable" -eq 1 ]; then
          printf '%s\n' 'HTTP 400: unknown field durability' >&2
          exit 1
        fi
        printf '%s' "$body" >"$CANARY_STUB_DIR/$slug"
        printf '%s\n' '{"ok":true,"durability":"queued"}'
        exit 0
        ;;
      http400-stale)
        if [ "$durable" -eq 1 ]; then
          printf '%s\n' 'HTTP 400: unknown field durability' >&2
          exit 1
        fi
        printf '%s\n' 'nonce: stale#1' >"$CANARY_STUB_DIR/$slug"
        printf '%s\n' '{"ok":true,"durability":"queued"}'
        exit 0
        ;;
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
log() { printf 'LOG: %s\n' "$*" >&2; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
export CURRENT_VER="0.23.3-1435-g211325fc2"

# The sidebin path must check the complete staged pair before either rename.
# It must check the installed pair again before reload and after install.
staged_hash_line="$(grep -n '"staged sidebin pair"' "$driver" | head -1 | cut -d: -f1)"
daemon_rename_line="$(grep -n 'mv -f "\$dest/lastdbd.new" "\$dest/lastdbd"' "$driver" | head -1 | cut -d: -f1)"
cli_rename_line="$(grep -n 'mv -f "\$dest/lastdb.new" "\$dest/lastdb"' "$driver" | head -1 | cut -d: -f1)"
post_rename_hash_line="$(grep -n 'assert_sidebin_installed_hashes_or_restore "post-rename' "$driver" | cut -d: -f1)"
pre_reload_hash_line="$(grep -n 'assert_sidebin_installed_hashes_or_restore "pre-reload' "$driver" | cut -d: -f1)"
reload_line="$(grep -n '^  if ! lastdb_launchd_reload_job' "$driver" | head -1 | cut -d: -f1)"
post_install_hash_line="$(grep -n 'assert_sidebin_installed_hashes_or_restore "post-install' "$driver" | cut -d: -f1)"
installed_version_line="$(grep -n '^log "installed lastdbd --version:' "$driver" | cut -d: -f1)"
[ -n "$staged_hash_line" ] && [ -n "$daemon_rename_line" ] && [ -n "$cli_rename_line" ] \
  && [ "$staged_hash_line" -lt "$daemon_rename_line" ] \
  && [ "$staged_hash_line" -lt "$cli_rename_line" ] \
  && [ "$cli_rename_line" -lt "$post_rename_hash_line" ] \
  && [ "$post_rename_hash_line" -lt "$pre_reload_hash_line" ] \
  && [ "$pre_reload_hash_line" -lt "$reload_line" ] || {
  echo "FAIL: sidebin hash checks do not enclose the rename-to-reload window" >&2
  exit 1
}
[ -n "$post_install_hash_line" ] && [ -n "$installed_version_line" ] \
  && [ "$post_install_hash_line" -lt "$installed_version_line" ] || {
  echo "FAIL: post-install exact-hash gate does not precede the version-only gate" >&2
  exit 1
}

# Extract only the sidebin hash and restore helpers. A same-version byte change
# must fail both the staged and installed gates. The installed gate must put
# both saved files back before it returns failure.
eval "$(awk '
  /^sidebin_pair_hashes_match_expected\(\)/ { capture=1 }
  /^live_install_sidebin\(\)/ { exit }
  capture { print }
' "$driver")"
sidebin_race_dir="$test_tmp/sidebin-race"
sidebin_candidate="$sidebin_race_dir/candidate"
SIDEBIN_DIR="$sidebin_race_dir/live"
mkdir -p "$sidebin_candidate" "$SIDEBIN_DIR"
sidebin_version="0.24.0-77-g0123456789ab"
for name in lastdbd lastdb; do
  cat >"$sidebin_candidate/$name" <<EOF
#!/usr/bin/env bash
printf '$name %s\\n' '$sidebin_version'
EOF
  cat >"$SIDEBIN_DIR/$name" <<EOF
#!/usr/bin/env bash
printf '$name %s\\n' '0.23.9-old'
EOF
  chmod 755 "$sidebin_candidate/$name" "$SIDEBIN_DIR/$name"
done
LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256="$(dev_stamp_sha256_file "$sidebin_candidate/lastdbd")"
LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256="$(dev_stamp_sha256_file "$sidebin_candidate/lastdb")"
SIDEBIN_BACKUP_DAEMON="$sidebin_race_dir/lastdbd.backup"
SIDEBIN_BACKUP_CLI="$sidebin_race_dir/lastdb.backup"
cp -a "$SIDEBIN_DIR/lastdbd" "$SIDEBIN_BACKUP_DAEMON"
cp -a "$SIDEBIN_DIR/lastdb" "$SIDEBIN_BACKUP_CLI"
cp -a "$sidebin_candidate/lastdbd" "$SIDEBIN_DIR/lastdbd.new"
cp -a "$sidebin_candidate/lastdb" "$SIDEBIN_DIR/lastdb.new"
sidebin_pair_hashes_match_expected \
  "$SIDEBIN_DIR/lastdbd.new" "$SIDEBIN_DIR/lastdb.new" "staged test pair" \
  || { echo "FAIL: exact staged sidebin pair was refused" >&2; exit 1; }
printf '%s\n' '# same version, different CLI bytes' >>"$SIDEBIN_DIR/lastdb.new"
[ "$("$SIDEBIN_DIR/lastdb.new" --version | awk '{print $NF}')" = "$sidebin_version" ] \
  || { echo "FAIL: staged mutation test changed the reported version" >&2; exit 1; }
sidebin_pair_hashes_match_expected \
  "$SIDEBIN_DIR/lastdbd.new" "$SIDEBIN_DIR/lastdb.new" "mutated staged test pair" >/dev/null 2>&1 \
  && { echo "FAIL: staged hash gate accepted same-version replacement bytes" >&2; exit 1; }

cp -a "$sidebin_candidate/lastdb" "$SIDEBIN_DIR/lastdb.new"
mv -f "$SIDEBIN_DIR/lastdbd.new" "$SIDEBIN_DIR/lastdbd"
mv -f "$SIDEBIN_DIR/lastdb.new" "$SIDEBIN_DIR/lastdb"
printf '%s\n' '# same version, different installed bytes' >>"$SIDEBIN_DIR/lastdb"
[ "$("$SIDEBIN_DIR/lastdb" --version | awk '{print $NF}')" = "$sidebin_version" ] \
  || { echo "FAIL: installed mutation test changed the reported version" >&2; exit 1; }
set +e
sidebin_race_out="$(assert_sidebin_installed_hashes_or_restore "same-version mutation test" 2>&1)"
sidebin_race_rc=$?
set -e
[ "$sidebin_race_rc" -ne 0 ] \
  && printf '%s\n' "$sidebin_race_out" | grep -q 'restored the pre-cutover sidebin backup pair' \
  || { echo "FAIL: installed hash gate did not reject and restore a same-version mutation" >&2; exit 1; }
cmp -s "$SIDEBIN_BACKUP_DAEMON" "$SIDEBIN_DIR/lastdbd" \
  && cmp -s "$SIDEBIN_BACKUP_CLI" "$SIDEBIN_DIR/lastdb" || {
  echo "FAIL: same-version mutation refusal did not restore both saved files" >&2
  exit 1
}

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
    die() { printf 'DIE: %s\n' "$*" >&2; exit 1; }
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
grep -q 'mode=durable' "$test_tmp/case-durable/stderr" || {
  echo "FAIL: durable receipt did not log mode=durable" >&2
  cat "$test_tmp/case-durable/stderr" >&2
  exit 1
}

run_receipt_case http400 pass
grep -q 'mode=queued+readback' "$test_tmp/case-http400/stderr" || {
  echo "FAIL: HTTP 400 durable put did not arm queued+readback" >&2
  cat "$test_tmp/case-http400/stderr" >&2
  exit 1
}
grep -q 'old_build=0.23.3-1435-g211325fc2' "$test_tmp/case-http400/stderr" || {
  echo "FAIL: queued+readback did not log the old daemon build string" >&2
  cat "$test_tmp/case-http400/stderr" >&2
  exit 1
}
grep -q 'HTTP 400 stderr: HTTP 400: unknown field durability' "$test_tmp/case-http400/stderr" || {
  echo "FAIL: HTTP 400 response body was not printed" >&2
  cat "$test_tmp/case-http400/stderr" >&2
  exit 1
}

for mode in queued missing malformed failed mismatch http400-stale; do
  run_receipt_case "$mode" fail
done
grep -q 'queued+readback of .* did not return this run' "$test_tmp/case-http400-stale/stderr" || {
  echo "FAIL: stale queued+readback nonce did not hard-abort" >&2
  cat "$test_tmp/case-http400-stale/stderr" >&2
  exit 1
}
if grep -q 'mode=queued+readback' "$test_tmp/case-failed/stderr"; then
  echo "FAIL: non-400 durable put failure armed queued+readback" >&2
  cat "$test_tmp/case-failed/stderr" >&2
  exit 1
fi

# Run the proof helper with fake LastSecrets and an exact fake pair. The test
# supplies production residue and ambient overrides. Each fake candidate verb
# refuses unless the helper removes or unsets them.
proof_dir="$test_tmp/dev-proof"
proof_bin="$proof_dir/bin"
proof_candidate="$proof_dir/candidate"
proof_primary="$proof_dir/primary"
proof_source="$proof_dir/rollback-source"
proof_tmp_root="$dev_proof_tmp_root"
proof_receipts="$proof_dir/receipts"
proof_calls="$proof_dir/calls.log"
mkdir -p "$proof_bin" "$proof_candidate" "$proof_primary/data" "$proof_tmp_root" "$proof_receipts"

cat >"$proof_bin/lastsecrets" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "$#" -eq 2 ] && [ "$1" = get ] \
  && [ "$2" = lastdb-restore-probe-invite-dev-20260720 ] || exit 2
printf 'lastsecrets:%s\n' "$2" >>"${FAKE_PROOF_CALLS:?}"
printf '%s\n' "${FAKE_DEV_INVITE:?}"
SH
chmod 755 "$proof_bin/lastsecrets"

cat >"$proof_candidate/lastdb" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
version="0.24.0-123-g0123456789ab"
if [ "${1:-}" = --version ]; then
  printf 'lastdb %s\n' "$version"
  exit 0
fi
[ -z "${LASTDB_HOME+x}" ] && [ -z "${FOLDDB_HOME+x}" ] \
  && [ -z "${FOLD_SYNC_DEVICE_ID+x}" ] || exit 31
[ "${1:-}" = --data-dir ] && [ -n "${2:-}" ] || exit 32
home="$2"
shift 2
case "${1:-}" in
  connect)
    shift
    [ "$*" = "--env dev --invite-code-stdin --use-existing-identity" ] || exit 33
    invite="$(cat)"
    [ "$invite" = "${FAKE_DEV_INVITE:?}" ] || exit 34
    [ -f "$home/identity.key" ] && [ -f "$home/.bootstrap_done" ] || exit 35
    [ ! -e "$home/data/.device_id" ] \
      && [ ! -e "$home/current-session.json" ] \
      && [ ! -e "$home/laststore_backup_known_present.json" ] \
      && [ ! -e "$home/laststore_backup_manifest.json" ] || exit 36
    [ "$(find "$home" -maxdepth 1 -name 'cloud_sync.json*' -print | wc -l | tr -d ' ')" = 0 ] \
      || exit 37
    printf '%s' 'fresh-dev-device' >"$home/data/.device_id"
    chmod 600 "$home/data/.device_id"
    cat >"$home/cloud_sync.json" <<'JSON'
{"api_url":"https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com","api_key":"FAKE-API-CREDENTIAL"}
JSON
    chmod 600 "$home/cloud_sync.json"
    printf 'connect:clean-and-unset\n' >>"${FAKE_PROOF_CALLS:?}"
    ;;
  cloud)
    [ "${2:-}" = snapshot ] && [ "${3:-}" = --json ] || exit 38
    [ -S "$home/data/folddb.sock" ] || exit 39
    printf 'snapshot:unset\n' >>"${FAKE_PROOF_CALLS:?}"
    [ "${FAKE_SNAPSHOT_FAIL:-0}" != 1 ] || exit 40
    printf '%s\n' '{"ok":true,"report":{"counter":9,"cas_counter":9,"manifest_sha256":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee","latest_key":"backup/latest"}}'
    ;;
  *) exit 41 ;;
esac
SH
chmod 755 "$proof_candidate/lastdb"

cat >"$proof_candidate/lastdbd" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import socket
import sys
import time

VERSION = "0.24.0-123-g0123456789ab"
if sys.argv[1:] == ["--version"]:
    print(f"lastdbd {VERSION}")
    raise SystemExit(0)
if any(name in os.environ for name in ("LASTDB_HOME", "FOLDDB_HOME", "FOLD_SYNC_DEVICE_ID")):
    raise SystemExit(51)
if len(sys.argv) != 3 or sys.argv[1] != "--data-dir":
    raise SystemExit(52)
home = sys.argv[2]
for name in (
    "laststore_backup_known_present.json",
    "laststore_backup_manifest.json",
):
    if os.path.lexists(os.path.join(home, name)):
        raise SystemExit(53)
if not os.path.isfile(os.path.join(home, "cloud_sync.json")):
    raise SystemExit(54)
socket_path = os.path.join(home, "data", "folddb.sock")
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(socket_path)
with open(os.environ["FAKE_PROOF_CALLS"], "a", encoding="utf-8") as calls:
    calls.write("daemon:unset\n")
with open(os.path.join(home, "current-session.json"), "w", encoding="utf-8") as marker:
    json.dump({"pid": os.getpid(), "fresh_cow_session": True}, marker)
active = True

def stop(_signum, _frame):
    global active
    active = False

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while active:
    time.sleep(0.05)
server.close()
try:
    os.unlink(socket_path)
except FileNotFoundError:
    pass
PY
chmod 755 "$proof_candidate/lastdbd"

printf '%s' 'IDENTITY-SEED-MARKER' >"$proof_primary/identity.key"
chmod 600 "$proof_primary/identity.key"
printf '%s' 'bootstrap-complete' >"$proof_primary/.bootstrap_done"
chmod 600 "$proof_primary/.bootstrap_done"
printf '%s' 'production-device' >"$proof_primary/data/.device_id"
chmod 600 "$proof_primary/data/.device_id"
printf '%s\n' '{"pid":99999}' >"$proof_primary/current-session.json"
printf '%s\n' production >"$proof_primary/cloud_sync.json"
printf '%s\n' production >"$proof_primary/cloud_sync.json.paused"
printf '%s\n' production >"$proof_primary/cloud_sync.json.backup-20260904"
printf '%s\n' production >"$proof_primary/laststore_backup_known_present.json"
printf '%s\n' production >"$proof_primary/laststore_backup_manifest.json"
printf '%s\n' socket-residue >"$proof_primary/data/folddb.sock"
printf '%s\n' socket-residue >"$proof_primary/data/folddb-full.sock"
printf '%s\n' real-data >"$proof_primary/data/store-fixture"
primary_identity_sha="$(shasum -a 256 "$proof_primary/identity.key" | awk '{print $1}')"
cp -R "$proof_primary" "$proof_source"

proof_oid="0123456789abcdef0123456789abcdef01234567"
proof_version="0.24.0-123-g0123456789ab"
proof_daemon_sha="$(shasum -a 256 "$proof_candidate/lastdbd" | awk '{print $1}')"
proof_cli_sha="$(shasum -a 256 "$proof_candidate/lastdb" | awk '{print $1}')"

unsafe_receipt="$proof_dir/lx-unsafe-${proof_daemon_sha:0:16}-${proof_cli_sha:0:16}.receipt"
printf '%s\n' do-not-delete >"$unsafe_receipt"
set +e
unsafe_out="$(
  HOME="$test_tmp/fake-user-home" \
  LASTDB_HOME="$proof_primary" \
  FOLDDB_HOME="$proof_primary" \
  FOLD_SYNC_DEVICE_ID="production-device" \
  LOOM_EXEC_ID="lx-unsafe" \
  LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID="$proof_oid" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH="$proof_candidate/lastdbd" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH="$proof_candidate/lastdb" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION="$proof_version" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION="$proof_version" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256="$proof_daemon_sha" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256="$proof_cli_sha" \
  LASTDB_DEV_PHOTOGRAPH_LASTSECRETS_BIN="$proof_bin/lastsecrets" \
  LASTDB_DEV_STAMP_ROOT="$proof_receipts" \
  LASTDB_DEV_PHOTOGRAPH_TMP_ROOT="$proof_tmp_root" \
  "$dev_proof" \
    --candidate-lastdbd "$proof_candidate/lastdbd" \
    --candidate-lastdb "$proof_candidate/lastdb" \
    --primary-home "$proof_primary" \
    --clone-source "$proof_source" \
    --receipt "$unsafe_receipt" \
    --source-git-oid "$proof_oid" 2>&1
)"
unsafe_rc=$?
set -e
[ "$unsafe_rc" -ne 0 ] \
  && printf '%s\n' "$unsafe_out" | grep -q 'receipt path is not bound' \
  || { echo "FAIL: DEV proof accepted an unbound receipt path" >&2; exit 1; }
[ "$(cat "$unsafe_receipt")" = do-not-delete ] \
  || { echo "FAIL: DEV proof removed or changed an unbound receipt path" >&2; exit 1; }
[ "$(find "$proof_tmp_root" -mindepth 1 -print | wc -l | tr -d ' ')" = 0 ] \
  || { echo "FAIL: unbound receipt refusal created a proof root" >&2; exit 1; }

proof_receipt="$proof_receipts/lx-ok-${proof_daemon_sha:0:16}-${proof_cli_sha:0:16}.receipt"
: >"$proof_calls"
/bin/sleep 120 &
bystander_pid=$!
set +e
proof_out="$(
  HOME="$test_tmp/fake-user-home" \
  LASTDB_HOME="$proof_primary" \
  FOLDDB_HOME="$proof_primary" \
  FOLD_SYNC_DEVICE_ID="production-device" \
  LOOM_EXEC_ID="lx-ok" \
  LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID="$proof_oid" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH="$proof_candidate/lastdbd" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH="$proof_candidate/lastdb" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION="$proof_version" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION="$proof_version" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256="$proof_daemon_sha" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256="$proof_cli_sha" \
  LASTDB_DEV_PHOTOGRAPH_LASTSECRETS_BIN="$proof_bin/lastsecrets" \
  LASTDB_DEV_STAMP_ROOT="$proof_receipts" \
  LASTDB_DEV_PHOTOGRAPH_TMP_ROOT="$proof_tmp_root" \
  LASTDB_DEV_PHOTOGRAPH_READY_WAITS=100 \
  LASTDB_DEV_PHOTOGRAPH_READY_SLEEP_SECS=0.02 \
  LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_ATTEMPTS=1 \
  FAKE_DEV_INVITE="FAKE-INVITE-CREDENTIAL" \
  FAKE_PROOF_CALLS="$proof_calls" \
  "$dev_proof" \
    --candidate-lastdbd "$proof_candidate/lastdbd" \
    --candidate-lastdb "$proof_candidate/lastdb" \
    --primary-home "$proof_primary" \
    --clone-source "$proof_source" \
    --receipt "$proof_receipt" \
    --source-git-oid "$proof_oid" 2>&1
)"
proof_rc=$?
set -e
[ "$proof_rc" -eq 0 ] || {
  echo "FAIL: hermetic exact-candidate DEV proof returned $proof_rc: $proof_out" >&2
  kill "$bystander_pid" 2>/dev/null || true
  exit 1
}
printf '%s\n' "$proof_out" | grep -q 'DEV_PHOTOGRAPH: GREEN' \
  || { echo "FAIL: hermetic DEV proof did not report GREEN" >&2; exit 1; }
kill -0 "$bystander_pid" 2>/dev/null \
  || { echo "FAIL: DEV proof cleanup killed an unrelated process" >&2; exit 1; }
kill "$bystander_pid" 2>/dev/null || true
wait "$bystander_pid" 2>/dev/null || true
[ -f "$proof_receipt" ] || { echo "FAIL: DEV proof left no receipt" >&2; exit 1; }
[ "$(find "$proof_tmp_root" -mindepth 1 -print | wc -l | tr -d ' ')" = 0 ] \
  || { echo "FAIL: DEV proof did not remove its exact temporary root" >&2; exit 1; }
grep -q 'connect:clean-and-unset' "$proof_calls" \
  && grep -q 'daemon:unset' "$proof_calls" \
  && grep -q 'snapshot:unset' "$proof_calls" \
  || { echo "FAIL: DEV proof did not exercise all exact commands with clean state" >&2; exit 1; }
grep -q 'lastdb-restore-probe-invite-dev-20260720' "$proof_calls" \
  || { echo "FAIL: DEV proof did not use the fixed LastSecrets slug" >&2; exit 1; }
if printf '%s\n' "$proof_out" | grep -Eq 'FAKE-INVITE-CREDENTIAL|FAKE-API-CREDENTIAL|IDENTITY-SEED-MARKER' \
    || grep -Eq 'FAKE-INVITE-CREDENTIAL|FAKE-API-CREDENTIAL|IDENTITY-SEED-MARKER' "$proof_receipt"; then
  echo "FAIL: DEV proof exposed a credential or identity marker" >&2
  exit 1
fi
[ "$(shasum -a 256 "$proof_primary/identity.key" | awk '{print $1}')" = "$primary_identity_sha" ] \
  && [ -f "$proof_primary/cloud_sync.json.backup-20260904" ] \
  && [ -f "$proof_primary/current-session.json" ] \
  && [ -f "$proof_source/cloud_sync.json.backup-20260904" ] \
  && [ -f "$proof_source/laststore_backup_manifest.json" ] \
  || { echo "FAIL: DEV proof changed the primary fixture" >&2; exit 1; }

# A manual snapshot failure leaves no new receipt and still removes only its
# exact candidate process and proof root.
failed_receipt="$proof_receipts/lx-fail-${proof_daemon_sha:0:16}-${proof_cli_sha:0:16}.receipt"
: >"$proof_calls"
/bin/sleep 120 &
bystander_pid=$!
set +e
failed_out="$(
  HOME="$test_tmp/fake-user-home" \
  LASTDB_HOME="$proof_primary" \
  FOLDDB_HOME="$proof_primary" \
  FOLD_SYNC_DEVICE_ID="production-device" \
  LOOM_EXEC_ID="lx-fail" \
  LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID="$proof_oid" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH="$proof_candidate/lastdbd" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH="$proof_candidate/lastdb" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION="$proof_version" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION="$proof_version" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256="$proof_daemon_sha" \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256="$proof_cli_sha" \
  LASTDB_DEV_PHOTOGRAPH_LASTSECRETS_BIN="$proof_bin/lastsecrets" \
  LASTDB_DEV_STAMP_ROOT="$proof_receipts" \
  LASTDB_DEV_PHOTOGRAPH_TMP_ROOT="$proof_tmp_root" \
  LASTDB_DEV_PHOTOGRAPH_READY_WAITS=100 \
  LASTDB_DEV_PHOTOGRAPH_READY_SLEEP_SECS=0.02 \
  LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_ATTEMPTS=1 \
  FAKE_DEV_INVITE="FAKE-INVITE-CREDENTIAL" \
  FAKE_PROOF_CALLS="$proof_calls" \
  FAKE_SNAPSHOT_FAIL=1 \
  "$dev_proof" \
    --candidate-lastdbd "$proof_candidate/lastdbd" \
    --candidate-lastdb "$proof_candidate/lastdb" \
    --primary-home "$proof_primary" \
    --clone-source "$proof_source" \
    --receipt "$failed_receipt" \
    --source-git-oid "$proof_oid" 2>&1
)"
failed_rc=$?
set -e
[ "$failed_rc" -ne 0 ] || { echo "FAIL: failed snapshot returned GREEN" >&2; exit 1; }
[ ! -e "$failed_receipt" ] || { echo "FAIL: failed snapshot wrote a receipt" >&2; exit 1; }
[ "$(find "$proof_tmp_root" -mindepth 1 -print | wc -l | tr -d ' ')" = 0 ] \
  || { echo "FAIL: failed snapshot left its proof root" >&2; exit 1; }
kill -0 "$bystander_pid" 2>/dev/null \
  || { echo "FAIL: failed snapshot cleanup killed an unrelated process" >&2; exit 1; }
kill "$bystander_pid" 2>/dev/null || true
wait "$bystander_pid" 2>/dev/null || true
if printf '%s\n' "$failed_out" | grep -Eq 'FAKE-INVITE-CREDENTIAL|FAKE-API-CREDENTIAL|IDENTITY-SEED-MARKER'; then
  echo "FAIL: failed DEV proof exposed a credential or identity marker" >&2
  exit 1
fi

echo "OK: lastdb-safe-upgrade skill packaged for multi-harness setup"
