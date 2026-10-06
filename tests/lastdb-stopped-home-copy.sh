#!/usr/bin/env bash
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
SCRIPT="$ROOT/skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh"
bash -n "$SCRIPT"
# shellcheck source=../skills/lastdb-safe-upgrade/scripts/stopped-home-copy.sh
. "$SCRIPT"

TEST_ROOT="$(mktemp -d /private/tmp/lastdb-stopped-copy-test.XXXXXX)"
trap 'rm -rf "$TEST_ROOT"' EXIT
home="$TEST_ROOT/home"
copy="$TEST_ROOT/copy"
mkdir -p "$home/data/data"
printf 'fake identity\n' >"$home/identity.key"
printf '{"fake":"cloud-config"}\n' >"$home/cloud_sync.json.paused"
: >"$home/.cloud_resume_required"
printf 'one record\n' >"$home/data/data/record"
printf '{"version":1,"pid":1234,"start_ts":5678,"flush_ok":true}\n' \
  >"$home/.shutdown_flush_ready"

validate_cloud_off_home "$home"
: >"$home/.cloud_backup_source_copy"
if validate_cloud_off_home "$home" >"$TEST_ROOT/live-marker.out" 2>&1; then
  echo 'FAIL: a source copy marker on the live home passed' >&2; exit 1
fi
unlink "$home/.cloud_backup_source_copy"
validate_copy_path "$copy" "$home"
situations() { printf '{"ok":false,"blocks":[{"slug":"test-block"}]}\n'; }
if require_restart_preflight >"$TEST_ROOT/preflight.out" 2>&1; then
  echo 'FAIL: blocked restart preflight passed' >&2; exit 1
fi
[ ! -e "$copy" ] && [ -f "$home/data/data/record" ] \
  || { echo 'FAIL: blocked preflight changed the source or copy' >&2; exit 1; }
printf 'PREFLIGHT-GATE: blocked restart refused before copy\n'
situations() { printf '{"ok":true,"blocks":[]}\n'; }
require_restart_preflight
unset -f situations
validate_shutdown_receipt "$home" 1234 5678
if validate_shutdown_receipt "$home" 1234 5679 >"$TEST_ROOT/stale.out" 2>&1; then
  echo 'FAIL: the receipt accepted another session' >&2; exit 1
fi
printf 'RECEIPT-GATE: stale session refused\n'

timeout_bin="$(command -v gtimeout || command -v timeout)"
before_free="$(free_kib "$home")"
copy_stopped_home "$home" "$copy" "$timeout_bin" "$before_free"
validate_shutdown_receipt "$copy" 1234 5678
(unset home; validate_shutdown_receipt "$copy" 1234 5678) \
  || { echo 'FAIL: receipt check used the caller home instead of its argument' >&2; exit 1; }
cmp -s "$home/data/data/record" "$copy/data/data/record"
[ ! -e "$copy/cloud_sync.json" ] && [ ! -e "$copy/.cloud_resume_requested" ] \
  || { echo 'FAIL: the stopped copy permits live cloud sync' >&2; exit 1; }
python3 "$ROOT/skills/lastdb-safe-upgrade/scripts/write-stopped-copy-marker.py" \
  --copy "$copy" --pid 1234 --start-ts 5678
jq -e '.version == 1 and .source_pid == 1234 and .source_start_ts == 5678
  and (.copied_at_unix_s | type) == "number"' "$copy/.cloud_backup_source_copy" >/dev/null \
  || { echo 'FAIL: the copy marker has the wrong session' >&2; exit 1; }
[ ! -e "$home/.cloud_backup_source_copy" ] \
  || { echo 'FAIL: the source received the copy marker' >&2; exit 1; }
if python3 "$ROOT/skills/lastdb-safe-upgrade/scripts/write-stopped-copy-marker.py" \
  --copy "$home" --pid 1234 --start-ts 5679 >"$TEST_ROOT/marker-bad.out" 2>&1; then
  echo 'FAIL: the marker accepted a mismatched shutdown receipt' >&2; exit 1
fi
[ ! -e "$home/.cloud_backup_source_copy" ] \
  || { echo 'FAIL: a bad receipt left a source marker' >&2; exit 1; }
printf 'COPY-MARKER-GATE: stopped session bound to final copy only\n'

# The old daemon has no flush receipt. The owner approved one stopped source
# with that limit. The action consumes the claim after the stop succeeds.
waiver_home="$TEST_ROOT/waiver-home"
waiver_copy="$TEST_ROOT/waiver-copy"
mkdir -p "$waiver_home/data/data"
printf 'fake identity\n' >"$waiver_home/identity.key"
printf '{"fake":"cloud-config"}\n' >"$waiver_home/cloud_sync.json.paused"
printf 'one old record\n' >"$waiver_home/data/data/record"
if validate_cloud_off_home "$waiver_home" >"$TEST_ROOT/normal-missing-resume.out" 2>&1; then
  echo 'FAIL: normal copy accepted an absent resume marker' >&2; exit 1
fi
validate_cloud_off_home "$waiver_home" waiver
claim_script="$ROOT/skills/lastdb-safe-upgrade/scripts/claim-stopped-copy-waiver.py"
decision=decision-2026-10-06-cloud-sync-rescue-risk-acceptance
if python3 "$claim_script" --home "$waiver_home" --pid 1234 --start-ts 5678 \
  --copy-path "$waiver_copy" --decision-slug wrong >"$TEST_ROOT/wrong-decision.out" 2>&1; then
  echo 'FAIL: wrong approval claimed the waiver' >&2; exit 1
fi
[ ! -e "$waiver_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: wrong approval wrote a claim' >&2; exit 1; }
python3 "$claim_script" --home "$waiver_home" --pid 1234 --start-ts 5678 \
  --copy-path "$waiver_copy" --decision-slug "$decision"
if python3 "$claim_script" --home "$waiver_home" --pid 1234 --start-ts 5678 \
  --copy-path "$waiver_copy" --decision-slug "$decision" >"$TEST_ROOT/claim-again.out" 2>&1; then
  echo 'FAIL: the one-time waiver was claimed twice' >&2; exit 1
fi
before_free="$(free_kib "$waiver_home")"
printf '{"pid":1234,"start_ts":5678}\n' >"$waiver_home/current-session.json"
if copy_stopped_home "$waiver_home" "$TEST_ROOT/waiver-copy-with-session" \
  "$timeout_bin" "$before_free" waiver >"$TEST_ROOT/waiver-session.out" 2>&1; then
  echo 'FAIL: a live session entered the waiver copy' >&2; exit 1
fi
unlink "$waiver_home/current-session.json"
copy_stopped_home "$waiver_home" "$waiver_copy" "$timeout_bin" "$before_free" waiver
other_copy="$TEST_ROOT/waiver-other-copy"
copy_stopped_home "$waiver_home" "$other_copy" "$timeout_bin" "$before_free" waiver
if python3 "$ROOT/skills/lastdb-safe-upgrade/scripts/write-stopped-copy-marker.py" \
  --copy "$other_copy" --pid 1234 --start-ts 5678 \
  --accept-unproved-flush "$decision" >"$TEST_ROOT/waiver-other-copy.out" 2>&1; then
  echo 'FAIL: waiver marker accepted another copy' >&2; exit 1
fi
if python3 "$ROOT/skills/lastdb-safe-upgrade/scripts/write-stopped-copy-marker.py" \
  --copy "$waiver_copy" --pid 1234 --start-ts 5679 \
  --accept-unproved-flush "$decision" >"$TEST_ROOT/waiver-wrong-session.out" 2>&1; then
  echo 'FAIL: waiver marker accepted another session' >&2; exit 1
fi
python3 "$ROOT/skills/lastdb-safe-upgrade/scripts/write-stopped-copy-marker.py" \
  --copy "$waiver_copy" --pid 1234 --start-ts 5678 --accept-unproved-flush "$decision"
jq -e '(keys | sort) == (["version","source_pid","source_start_ts","copied_at_unix_s", "flush_proof", "owner_approved", "stop_proof"] | sort)
  and .version == 2 and .source_pid == 1234 and .source_start_ts == 5678
  and .flush_proof == "absent" and .owner_approved == "2026-10-06"
  and .stop_proof == "supervised_sigterm_no_forced_kill"' \
  "$waiver_copy/.cloud_backup_source_copy" >/dev/null \
  || { echo 'FAIL: waiver marker differs from the approved contract' >&2; exit 1; }
[ ! -e "$waiver_home/.cloud_backup_source_copy" ] \
  || { echo 'FAIL: waiver marker reached the live home' >&2; exit 1; }
curl() { printf '{"status":{"sync":{"enabled":false}}}\n'; }
require_live_cloud_off "$waiver_home/data/folddb.sock" \
  || { echo 'FAIL: live Cloud Sync Off failed the restart gate' >&2; exit 1; }
curl() { printf '{"status":{"sync":{"enabled":true}}}\n'; }
if require_live_cloud_off "$waiver_home/data/folddb.sock" >"$TEST_ROOT/sync-on.out" 2>&1; then
  echo 'FAIL: live Cloud Sync On passed the restart gate' >&2; exit 1
fi
unset -f curl
printf 'WAIVER-GATE: one approval, one stopped copy, Cloud Sync Off\n'

# A failed supervised stop does not consume the live-home waiver.
failed_home="$TEST_ROOT/failed-stop-home"
failed_copy="$TEST_ROOT/failed-stop-copy"
fake_bin="$TEST_ROOT/fake-bin"
fake_plist="$TEST_ROOT/fake-primary.plist"
mkdir -p "$failed_home/data/data" "$fake_bin"
printf 'fake identity\n' >"$failed_home/identity.key"
printf '{"fake":"cloud-config"}\n' >"$failed_home/cloud_sync.json.paused"
printf '{"pid":1234,"start_ts":5678}\n' >"$failed_home/current-session.json"
printf '#!/bin/sh\nexit 0\n' >"$fake_bin/lastdbd"
printf '#!/bin/sh\nexit 0\n' >"$fake_bin/lastdb"
chmod +x "$fake_bin/lastdbd" "$fake_bin/lastdb"
printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' \
  '<plist version="1.0"><dict><key>ProgramArguments</key><array>' \
  "<string>$fake_bin/lastdbd</string>" '</array></dict></plist>' >"$fake_plist"
daemon_sha="$(shasum -a 256 "$fake_bin/lastdbd" | awk '{print $1}')"
cli_sha="$(shasum -a 256 "$fake_bin/lastdb" | awk '{print $1}')"
if (
  SIDEBIN_DIR="$fake_bin"; LAUNCHD_PLIST="$fake_plist"
  require_restart_preflight() { :; }
  safe_upgrade_owner_lock_acquire() { :; }
  safe_upgrade_owner_lock_release() { :; }
  lastdb_launchd_job_pid() { printf '1234\n'; }
  live_unix_socket_listener_pid() { printf '1234\n'; }
  live_unix_socket_is_healthy() { return 0; }
  lastdb_launchd_graceful_prestop() { return 1; }
  recover_on_exit() { :; }
  main --copy "$failed_copy" --launchd-label com.test.lastdbd \
    --primary-home "$failed_home" --expected-lastdbd-sha256 "$daemon_sha" \
    --expected-lastdb-sha256 "$cli_sha" --accept-unproved-flush "$decision"
) >"$TEST_ROOT/failed-stop.out" 2>&1; then
  echo 'FAIL: failed supervised stop passed' >&2; exit 1
fi
[ ! -e "$failed_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: a failed supervised stop consumed the waiver' >&2; exit 1; }
[ ! -e "$failed_copy" ] \
  || { echo 'FAIL: a failed supervised stop made a copy' >&2; exit 1; }
printf 'WAIVER-STOP-GATE: failed stop leaves primary claim absent\n'

# A later copy error releases the claim only after the primary recovers.
release_home="$TEST_ROOT/release-home"
release_copy="$TEST_ROOT/release-copy"
mkdir -p "$release_home/data/data"
printf 'fake identity\n' >"$release_home/identity.key"
printf '{"fake":"cloud-config"}\n' >"$release_home/cloud_sync.json.paused"
python3 "$claim_script" --home "$release_home" --pid 1234 --start-ts 5678 \
  --copy-path "$release_copy" --decision-slug "$decision"
if (
  WAIVER_CLAIMED=1; STOP_STARTED=1; RESTARTED=0; RESTART_REQUESTED=0
  PRIMARY_HOME="$release_home"; COPY_DIR="$release_copy"; STAGE_COPY="$release_copy.incomplete"
  OLD_PID=1234; SOURCE_START_TS=5678; ACCEPT_UNPROVED_FLUSH="$decision"
  LAUNCHD_LABEL=com.test.lastdbd; OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { [ -f "$TEST_ROOT/recovery-restarted" ]; }
  lastdb_launchd_job_loaded() { return 1; }
  restart_primary() { : >"$TEST_ROOT/recovery-restarted"; }
  require_live_cloud_off() { return 0; }
  safe_upgrade_owner_lock_release() { :; }
  false
  recover_on_exit
) >"$TEST_ROOT/release-after-copy-error.out" 2>&1; then
  echo 'FAIL: a failed copy reported success' >&2; exit 1
fi
[ ! -e "$release_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: a recovered failed copy consumed the waiver' >&2; exit 1; }
grep -q 'STOPPED_COPY_WAIVER=available_after_failed_copy' "$TEST_ROOT/release-after-copy-error.out" \
  || { echo 'FAIL: a recovered failed copy lacked a release proof' >&2; exit 1; }
python3 "$claim_script" --home "$release_home" --pid 1234 --start-ts 5678 \
  --copy-path "$release_copy" --decision-slug "$decision"
if (
  WAIVER_CLAIMED=1; STOP_STARTED=0; RESTARTED=1
  PRIMARY_HOME="$release_home"; COPY_DIR="$release_copy"; STAGE_COPY="$release_copy.incomplete"
  OLD_PID=1234; SOURCE_START_TS=5678; ACCEPT_UNPROVED_FLUSH="$decision"
  LAUNCHD_LABEL=com.test.lastdbd; OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 1; }
  require_live_cloud_off() { return 0; }
  safe_upgrade_owner_lock_release() { :; }
  false
  recover_on_exit
) >"$TEST_ROOT/release-unhealthy.out" 2>&1; then
  echo 'FAIL: an unhealthy primary reported a safe retry' >&2; exit 1
fi
[ -f "$release_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: an unhealthy primary released the waiver' >&2; exit 1; }
if (
  WAIVER_CLAIMED=1; STOP_STARTED=0; RESTARTED=1
  PRIMARY_HOME="$release_home"; COPY_DIR="$release_copy"; STAGE_COPY="$release_copy.incomplete"
  OLD_PID=1234; SOURCE_START_TS=5678; ACCEPT_UNPROVED_FLUSH="$decision"
  LAUNCHD_LABEL=com.test.lastdbd; OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 0; }
  require_live_cloud_off() { return 1; }
  safe_upgrade_owner_lock_release() { :; }
  false
  recover_on_exit
) >"$TEST_ROOT/release-sync-on.out" 2>&1; then
  echo 'FAIL: Cloud Sync On reported a safe retry' >&2; exit 1
fi
[ -f "$release_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: Cloud Sync On released the waiver' >&2; exit 1; }
printf '{"fake":"active-cloud-config"}\n' >"$release_home/cloud_sync.json"
if (
  WAIVER_CLAIMED=1; STOP_STARTED=0; RESTARTED=1
  PRIMARY_HOME="$release_home"; COPY_DIR="$release_copy"; STAGE_COPY="$release_copy.incomplete"
  OLD_PID=1234; SOURCE_START_TS=5678; ACCEPT_UNPROVED_FLUSH="$decision"
  LAUNCHD_LABEL=com.test.lastdbd; OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 0; }
  require_live_cloud_off() { return 0; }
  safe_upgrade_owner_lock_release() { :; }
  false
  recover_on_exit
) >"$TEST_ROOT/release-active-config.out" 2>&1; then
  echo 'FAIL: active cloud config reported a safe retry' >&2; exit 1
fi
[ -f "$release_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: active cloud config released the waiver' >&2; exit 1; }
unlink "$release_home/cloud_sync.json"
mkdir "$release_copy.incomplete"
: >"$release_copy.incomplete/.cloud_backup_source_copy"
if (
  WAIVER_CLAIMED=1; STOP_STARTED=0; RESTARTED=1
  PRIMARY_HOME="$release_home"; COPY_DIR="$release_copy"; STAGE_COPY="$release_copy.incomplete"
  OLD_PID=1234; SOURCE_START_TS=5678; ACCEPT_UNPROVED_FLUSH="$decision"
  LAUNCHD_LABEL=com.test.lastdbd; OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 0; }
  require_live_cloud_off() { return 0; }
  safe_upgrade_owner_lock_release() { :; }
  false
  recover_on_exit
) >"$TEST_ROOT/release-stage-marker.out" 2>&1; then
  echo 'FAIL: a marked stage reported a safe retry' >&2; exit 1
fi
[ -f "$release_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: a marked stage released the waiver' >&2; exit 1; }
unlink "$release_copy.incomplete/.cloud_backup_source_copy"
mkdir "$release_copy"
if python3 "$claim_script" --release --home "$release_home" --pid 1234 --start-ts 5678 \
  --copy-path "$release_copy" --decision-slug "$decision" \
  >"$TEST_ROOT/release-published.out" 2>&1; then
  echo 'FAIL: a published copy released the waiver claim' >&2; exit 1
fi
[ -f "$release_home/.cloud_backup_unproved_flush_claim" ] \
  || { echo 'FAIL: a published copy lost its waiver claim' >&2; exit 1; }
printf 'WAIVER-RETRY-GATE: failed copy can retry only after primary recovery\n'

ln -s "$home/data/data/record" "$home/data/data/live-alias"
if require_plain_data_tree "$home/data" "$timeout_bin" >"$TEST_ROOT/link.out" 2>&1; then
  echo 'FAIL: source data symlink can reach the live home' >&2; exit 1
fi
printf 'SYMLINK-GATE: source data symlink refused\n'

# A failed stop can leave the original daemon healthy. Do not reload it.
if (
  set +e
  STOP_STARTED=1; RESTARTED=0; RESTART_REQUESTED=0
  SIDEBIN_DIR="$TEST_ROOT/bin"; mkdir -p "$SIDEBIN_DIR"
  LAUNCHD_LABEL=com.test.lastdbd; LAUNCHD_PLIST="$TEST_ROOT/primary.plist"
  PRIMARY_HOME="$home"; OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 0; }
  restart_primary() { printf 'reload\n' >>"$TEST_ROOT/reloads"; return 1; }
  false
  recover_on_exit
) >"$TEST_ROOT/old-healthy.out" 2>&1; then
  echo 'FAIL: failed stop did not report an error' >&2; exit 1
fi
[ ! -e "$TEST_ROOT/reloads" ] \
  || { echo 'FAIL: recovery reloaded a healthy old daemon' >&2; exit 1; }
grep -q 'STOPPED_COPY_RECOVERY=green primary=running' "$TEST_ROOT/old-healthy.out"
printf 'RECOVERY-GATE: healthy old daemon kept\n'

# A first restart can leave launchd loaded while the daemon still boots.
# A second reload would interrupt that boot.
if (
  set +e
  STOP_STARTED=1; RESTARTED=0; RESTART_REQUESTED=1
  SIDEBIN_DIR="$TEST_ROOT/bin"; LAUNCHD_LABEL=com.test.lastdbd
  LAUNCHD_PLIST="$TEST_ROOT/primary.plist"; PRIMARY_HOME="$home"
  OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 1; }
  lastdb_launchd_job_loaded() { return 0; }
  wait_for_live_unix_socket_health() { return 1; }
  restart_primary() { printf 'reload\n' >>"$TEST_ROOT/reloads"; return 0; }
  false
  recover_on_exit
) >"$TEST_ROOT/booting.out" 2>&1; then
  echo 'FAIL: a loaded but unhealthy supervisor reported success' >&2; exit 1
fi
[ ! -e "$TEST_ROOT/reloads" ] \
  || { echo 'FAIL: recovery sent a second reload to a booting supervisor' >&2; exit 1; }
grep -q 'STOPPED_COPY_RECOVERY=red primary=loaded-but-unhealthy' "$TEST_ROOT/booting.out" \
  || { echo 'FAIL: a loaded supervisor entered the absent-job branch' >&2; exit 1; }
printf 'RECOVERY-GATE: booting supervisor not reloaded\n'

# If the first reload leaves no job and no listener, request one bootstrap.
# Do not start another bootout/reload cycle.
if (
  set +e
  STOP_STARTED=1; RESTARTED=0; RESTART_REQUESTED=1
  SIDEBIN_DIR="$TEST_ROOT/bin"; LAUNCHD_LABEL=com.test.lastdbd
  LAUNCHD_PLIST="$TEST_ROOT/primary.plist"; PRIMARY_HOME="$home"
  OWNER_LOCK_HELD=0
  primary_is_supervised_and_healthy() { return 1; }
  lastdb_launchd_job_loaded() { return 1; }
  bootstrap_absent_primary_once() { printf 'bootstrap\n' >>"$TEST_ROOT/bootstraps"; return 0; }
  restart_primary() { printf 'reload\n' >>"$TEST_ROOT/reloads"; return 0; }
  false
  recover_on_exit
) >"$TEST_ROOT/unloaded.out" 2>&1; then
  echo 'FAIL: an absent job after the first reload reported success' >&2; exit 1
fi
[ ! -e "$TEST_ROOT/reloads" ] \
  || { echo 'FAIL: recovery sent a second reload after the first request' >&2; exit 1; }
[ "$(wc -l <"$TEST_ROOT/bootstraps" | tr -d ' ')" = 1 ] \
  || { echo 'FAIL: recovery did not request exactly one bootstrap' >&2; exit 1; }
grep -q 'STOPPED_COPY_RECOVERY=green primary=running method=single-bootstrap' \
  "$TEST_ROOT/unloaded.out"
printf 'RECOVERY-GATE: absent supervisor got one bootstrap\n'

# The bootstrap helper itself refuses an uncertain loaded job.
if (
  SIDEBIN_DIR="$TEST_ROOT/bin"; LAUNCHCTL_BIN="$TEST_ROOT/launchctl"
  printf '#!/bin/sh\nprintf "bootstrap\\n" >>"%s"\n' "$TEST_ROOT/bootstraps" >"$LAUNCHCTL_BIN"
  chmod +x "$LAUNCHCTL_BIN"
  printf '#!/bin/sh\nexit 0\n' >"$SIDEBIN_DIR/lastdbd"; chmod +x "$SIDEBIN_DIR/lastdbd"
  lastdb_launchd_job_loaded() { return 0; }
  live_unix_socket_has_listener() { return 1; }
  wait_for_live_unix_socket_health() { return 0; }
  primary_is_supervised_and_healthy() { return 0; }
  bootstrap_absent_primary_once gui/501 com.test.lastdbd "$TEST_ROOT/primary.plist" "$home/data/folddb.sock"
); then
  echo 'FAIL: a loaded supervisor got a second bootstrap' >&2; exit 1
fi
[ "$(wc -l <"$TEST_ROOT/bootstraps" | tr -d ' ')" = 1 ] \
  || { echo 'FAIL: uncertain supervisor got another bootstrap' >&2; exit 1; }
printf 'RECOVERY-GATE: uncertain supervisor left alone\n'

# One proven absent job receives one direct bootstrap without a bootout.
if (
  SIDEBIN_DIR="$TEST_ROOT/bin"; LAUNCHCTL_BIN="$TEST_ROOT/bootstrap-launchctl"
  printf '#!/bin/sh\nprintf "bootstrap\\n" >>"%s"\ntouch "%s"\n' \
    "$TEST_ROOT/direct-bootstraps" "$TEST_ROOT/direct-job-loaded" >"$LAUNCHCTL_BIN"
  chmod +x "$LAUNCHCTL_BIN"
  lastdb_launchd_job_loaded() { [ -f "$TEST_ROOT/direct-job-loaded" ]; }
  live_unix_socket_has_listener() { return 1; }
  wait_for_live_unix_socket_health() { return 0; }
  primary_is_supervised_and_healthy() { return 0; }
  bootstrap_absent_primary_once gui/501 com.test.lastdbd "$TEST_ROOT/primary.plist" "$home/data/folddb.sock"
); then
  [ "$(wc -l <"$TEST_ROOT/direct-bootstraps" | tr -d ' ')" = 1 ] \
    || { echo 'FAIL: direct recovery used more than one bootstrap' >&2; exit 1; }
else
  echo 'FAIL: direct bootstrap did not recover an absent supervisor' >&2; exit 1
fi
printf 'RECOVERY-GATE: direct bootstrap starts absent supervisor once\n'

echo 'PASS lastdb-stopped-home-copy'
