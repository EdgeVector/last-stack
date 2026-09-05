#!/usr/bin/env bash
set -euo pipefail

# A HEAL-node-spawned agent exports the ambient live-loom contract; scrub it
# so every invocation below controls its own LOOM_* env.
unset LOOM_LIVE LOOM_CANARY_LIVE LOOM_CANARY_RED_LIVE \
  LOOM_EXEC_ID LOOM_INPUT LOOM_IDEMPOTENCY_KEY LOOM_SCRIPTS \
  LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256 \
  LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256 \
  LASTDB_SAFE_UPGRADE_EXPECTED_ARTIFACT_DIGEST \
  LASTDB_DEV_STAMP_RECEIPT || true

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
FRESH="$ROOT/lib/canary-loom/lastdb-candidate-freshness.py"
STEP="$ROOT/lib/canary-loom/loom-safe-upgrade-step.sh"
GRAPH="$ROOT/lib/canary-loom/lastdb-safe-upgrade.json"
LAUNCHER="$ROOT/bin/last-stack-safe-upgrade-loom"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
RECOVERY="$ROOT/skills/lastdb-safe-upgrade/scripts/cutover-timeout-recovery.sh"
DOGFOOD="$ROOT/bin/last-stack-lastdb-canary-dogfood"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

bash -n "$STEP"
bash -n "$LAUNCHER"
bash -n "$DRIVER"
bash -n "$RECOVERY"
python3 -m py_compile "$FRESH" "$DOGFOOD"

[ "$(jq -r .version "$GRAPH")" = "6" ] || fail "safe-upgrade graph version did not advance"
grep -q 'SAFE_UPGRADE_PROTOCOL_VERSION="6"' "$LAUNCHER" \
  || fail "launcher key namespace does not match safe-upgrade graph version 6"
[ "$(jq -r '.states.DECIDE.map.current' "$GRAPH")" = "DONE" ] \
  || fail "equal candidate does not finish as a no-op"
probe_timeout="$(jq -er '.states.PROBE.timeout_sec | numbers' "$GRAPH")"
cutover_timeout="$(jq -er '.states.CUTOVER.timeout_sec | numbers' "$GRAPH")"
[ "$cutover_timeout" -ge "$probe_timeout" ] \
  || fail "CUTOVER timeout must cover every check that PROBE runs"
[ "$cutover_timeout" -ge 7200 ] \
  || fail "CUTOVER timeout cannot cover the measured real-data safety pass"
grep -q '"PROBE", probe_env' "$STEP" \
  || fail "PROBE wrapper does not use the bounded driver runner"
grep -q '"CUTOVER",' "$STEP" \
  || fail "CUTOVER wrapper does not use the bounded driver runner"
grep -q 'start_new_session=True' "$STEP" \
  || fail "safe-upgrade driver does not own an isolated process group"
grep -q 'signal_process_group(proc, signal.SIGTERM)' "$STEP" \
  || fail "safe-upgrade timeout does not permit owned cleanup traps"
grep -q 'signal_process_group(proc, signal.SIGKILL)' "$STEP" \
  || fail "safe-upgrade timeout lacks a bounded cleanup escalation"
if grep -Eq 'timeout=(3600|7200)' "$STEP"; then
  fail "safe-upgrade wrapper retains a timeout separate from the graph"
fi

tmp="$(mktemp -d "${TMPDIR:-/tmp}/last-stack-safe-upgrade-loom.XXXXXX")"
cleanup_test() {
  if [ -n "${CUTOVER_SUPERVISED_PID_FILE:-}" ] \
      && [ -s "$CUTOVER_SUPERVISED_PID_FILE" ]; then
    kill "$(cat "$CUTOVER_SUPERVISED_PID_FILE")" 2>/dev/null || true
  fi
  if [ -n "${CUTOVER_FIXTURE_ROOT:-}" ]; then
    rm -rf "$CUTOVER_FIXTURE_ROOT"
  fi
  rm -rf "$tmp"
}
trap cleanup_test EXIT
tmp="$(CDPATH= cd -- "$tmp" && pwd -P)"
export LOOM_SAFE_UPGRADE_CUTOVER_RECOVERY_SCRIPT="$RECOVERY"

repo="$tmp/fold"
git init -q "$repo"
base_branch="$(git -C "$repo" symbolic-ref --short HEAD)"
git -C "$repo" config user.email test@example.com
git -C "$repo" config user.name test
git -C "$repo" commit -q --allow-empty -m a
oid_a="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" commit -q --allow-empty -m b
oid_b="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q -b side "$oid_a"
git -C "$repo" commit -q --allow-empty -m side
oid_side="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" checkout -q "$base_branch"

make_candidate() {
  local dir="$1" version="$2" oid="$3"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\nprintf "lastdbd %s\\n"\n' "$version" >"$dir/lastdbd"
  printf '#!/usr/bin/env bash\nprintf "lastdb %s\\n"\n' "$version" >"$dir/lastdb"
  chmod 755 "$dir/lastdbd" "$dir/lastdb"
  if [ -n "$oid" ]; then
    printf '{"source_git_oid":"%s"}\n' "$oid" >"$dir/manifest.json"
  fi
}

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

artifact_digest() {
  printf '%s\0%s\0%s\0%s\0%s\0%s\0%s' \
    "$1" "$2" "$3" "$4" "$5" "$6" "$7" \
    | shasum -a 256 | awk '{print $1}'
}

candidate_input() {
  local dir="$1" oid="$2" version daemon cli daemon_sha cli_sha digest
  daemon="$(CDPATH= cd -- "$dir" && printf '%s/lastdbd\n' "$(pwd -P)")"
  cli="$(CDPATH= cd -- "$dir" && printf '%s/lastdb\n' "$(pwd -P)")"
  version="$("$daemon" --version | awk '{print $NF}')"
  daemon_sha="$(sha256_file "$daemon")"
  cli_sha="$(sha256_file "$cli")"
  digest="$(artifact_digest \
    "$oid" "$daemon" "$cli" "$daemon_sha" "$cli_sha" "$version" "$version")"
  jq -cn \
    --arg candidate "$daemon" \
    --arg candidate_cli "$cli" \
    --arg version "$version" \
    --arg lastdbd_version "$version" \
    --arg lastdb_version "$version" \
    --arg lastdbd_sha256 "$daemon_sha" \
    --arg lastdb_sha256 "$cli_sha" \
    --arg source_git_oid "$oid" \
    --arg candidate_artifact_digest "$digest" \
    --arg safe_upgrade_protocol_version 6 \
    '{candidate:$candidate,candidate_cli:$candidate_cli,version:$version,lastdbd_version:$lastdbd_version,lastdb_version:$lastdb_version,lastdbd_sha256:$lastdbd_sha256,lastdb_sha256:$lastdb_sha256,source_git_oid:$source_git_oid,candidate_artifact_digest:$candidate_artifact_digest,safe_upgrade_protocol_version:$safe_upgrade_protocol_version}'
}

make_candidate "$tmp/current-a" "0.23.3-1-g${oid_a:0:12}" "$oid_a"
make_candidate "$tmp/current-b" "0.23.3-2-g${oid_b:0:12}" "$oid_b"
make_candidate "$tmp/candidate-a" "0.23.3-1-g${oid_a:0:12}" "$oid_a"
make_candidate "$tmp/candidate-b" "0.23.3-2-g${oid_b:0:12}" "$oid_b"
make_candidate "$tmp/candidate-side" "0.23.3-2-g${oid_side:0:12}" "$oid_side"
make_candidate "$tmp/candidate-unknown" "0.23.3-release" ""

out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-a/lastdbd" \
  --current-bin "$tmp/current-a/lastdbd" \
  --git-dir "$repo")"
[ "$(printf '%s\n' "$out" | jq -r .relation)" = "current" ] \
  || fail "equal candidate was not current: $out"

out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-b/lastdbd" \
  --current-bin "$tmp/current-a/lastdbd" \
  --git-dir "$repo")"
[ "$(printf '%s\n' "$out" | jq -r .relation)" = "forward" ] \
  || fail "descendant candidate was not forward: $out"

set +e
out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-a/lastdbd" \
  --current-bin "$tmp/current-b/lastdbd" \
  --git-dir "$repo")"
rc=$?
set -e
[ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | jq -r .relation)" = "stale" ] \
  || fail "older candidate did not fail stale: rc=$rc out=$out"

set +e
out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-side/lastdbd" \
  --current-bin "$tmp/current-b/lastdbd" \
  --git-dir "$repo")"
rc=$?
set -e
[ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | jq -r .relation)" = "diverged" ] \
  || fail "divergent candidate did not fail closed: rc=$rc out=$out"

set +e
out="$(python3 "$FRESH" \
  --candidate "$tmp/candidate-unknown/lastdbd" \
  --current-bin "$tmp/current-b/lastdbd" \
  --git-dir "$repo")"
rc=$?
set -e
[ "$rc" -eq 1 ] && [ "$(printf '%s\n' "$out" | jq -r .relation)" = "unknown" ] \
  || fail "unknown ancestry did not fail closed: rc=$rc out=$out"

mock_home="$tmp/home"
skill_dir="$mock_home/.last-stack/skills/lastdb-safe-upgrade/scripts"
mkdir -p "$skill_dir"
safe_log="$tmp/safe.log"
cat >"$skill_dir/safe-upgrade-lastdb.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'args=%s marker=%s exec=%s daemon=%s cli=%s daemon_sha=%s cli_sha=%s source=%s receipt=%s\n' \
  "$*" "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-}" "${LOOM_EXEC_ID:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:-}" \
  "${LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID:-}" \
  "${LASTDB_DEV_STAMP_RECEIPT:-}" >>"${SAFE_LOG:?}"
case " $* " in
  *" --probe-only "*)
    case "${SAFE_MOCK_PROBE:-green}" in
      green) printf 'VERDICT: GREEN_PROBE_ONLY\n' ;;
      false-green)
        # Real drivers cat sub-probe output: the smoke stage prints its own
        # "VERDICT: GREEN" before a later bar fails RED with rc=1.
        printf 'VERDICT: GREEN\n'
        printf 'VERDICT: RED\n'
        printf 'REASON: candidate fails the latency bar\n'
        exit 1
        ;;
      rc-red)
        printf 'VERDICT: GREEN_PROBE_ONLY\n'
        exit 1
        ;;
      timeout)
        trap 'rm -f -- "$SAFE_TIMEOUT_RESIDUE"; exit 143' HUP INT TERM
        : >"${SAFE_TIMEOUT_RESIDUE:?}"
        python3 - "${SAFE_TIMEOUT_PID_FILE:?}" <<'PY' &
import os
import signal
import sys
import time
from pathlib import Path

signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()), encoding="utf-8")
while True:
    time.sleep(1)
PY
        timeout_child=$!
        wait "$timeout_child"
        ;;
    esac
    ;;
  *)
    [ "${LASTDB_SAFE_UPGRADE_VIA_LOOM:-}" = "1" ] || exit 70
    [ -n "${LOOM_EXEC_ID:-}" ] || exit 71
    case "${SAFE_MOCK_CUTOVER:-green}" in
      green) printf 'VERDICT: GREEN\n' ;;
      timeout_effect|fail_effect)
        state="${LASTDB_CUTOVER_RECOVERY_STATE:?}"
        live="${SAFE_CUTOVER_LIVE_DIR:?}"
        if [ -n "${SAFE_CUTOVER_LAUNCHD_PROGRAM:-}" ]; then
          live="$(CDPATH= cd -- "$(dirname -- "$SAFE_CUTOVER_LAUNCHD_PROGRAM")" \
            && pwd -P)"
        fi
        candidate="${SAFE_CUTOVER_CANDIDATE_DIR:?}"
        backup_daemon="$live/lastdbd.bak-pre-old-test"
        backup_cli="$live/lastdb.bak-pre-old-test"
        cp -a "$live/lastdbd" "$backup_daemon"
        cp -a "$live/lastdb" "$backup_cli"
        daemon_sha="$(shasum -a 256 "$backup_daemon" | awk '{print $1}')"
        cli_sha="$(shasum -a 256 "$backup_cli" | awk '{print $1}')"
        state_tmp="${state}.driver.$$"
        jq -cn \
          --arg loom_execution_id "$LOOM_EXEC_ID" \
          --arg primary_home "${SAFE_CUTOVER_PRIMARY_HOME:?}" \
          --arg primary_socket "${SAFE_CUTOVER_PRIMARY_SOCKET:?}" \
          --arg sidebin_dir "$live" \
          --arg launchd_label "${SAFE_CUTOVER_LAUNCHD_LABEL:?}" \
          --arg launchd_plist "${SAFE_CUTOVER_LAUNCHD_PLIST:?}" \
          --arg backup_lastdbd "$backup_daemon" \
          --arg backup_lastdb "$backup_cli" \
          --arg backup_lastdbd_sha256 "$daemon_sha" \
          --arg backup_lastdb_sha256 "$cli_sha" \
          '{state_version:1,loom_execution_id:$loom_execution_id,
            stage:"sidebin-reload-started",effect_started:true,venue:"sidebin",
            primary_home:$primary_home,primary_socket:$primary_socket,
            sidebin_dir:$sidebin_dir,launchd_label:$launchd_label,
            launchd_plist:$launchd_plist,backup_lastdbd:$backup_lastdbd,
            backup_lastdb:$backup_lastdb,backup_lastdbd_sha256:$backup_lastdbd_sha256,
            backup_lastdb_sha256:$backup_lastdb_sha256}' >"$state_tmp"
        chmod 600 "$state_tmp"
        mv -f "$state_tmp" "$state"
        cp -a "$candidate/lastdbd" "$live/lastdbd.new"
        cp -a "$candidate/lastdb" "$live/lastdb.new"
        mv -f "$live/lastdbd.new" "$live/lastdbd"
        mv -f "$live/lastdb.new" "$live/lastdb"
        "${SAFE_CUTOVER_LAUNCHCTL_BIN:?}" bootout \
          "gui/$(id -u)/${SAFE_CUTOVER_LAUNCHD_LABEL}" >/dev/null 2>&1 || true
        nohup python3 "${SAFE_CUTOVER_SERVER_SCRIPT:?}" \
          "${SAFE_CUTOVER_PRIMARY_SOCKET}" "${SAFE_CUTOVER_EMERGENCY_PID_FILE:?}" \
          ignore-term >/dev/null 2>&1 &
        emergency_pid=$!
        if [ "$SAFE_MOCK_CUTOVER" = "fail_effect" ]; then
          for _wait in $(seq 1 100); do
            [ -s "$SAFE_CUTOVER_EMERGENCY_PID_FILE" ] && break
            sleep 0.01
          done
          [ -s "$SAFE_CUTOVER_EMERGENCY_PID_FILE" ] || exit 73
          printf 'VERDICT: RED\n'
          exit 1
        fi
        wait "$emergency_pid"
        ;;
      *) exit 72 ;;
    esac
    ;;
esac
SH
chmod 755 "$skill_dir/safe-upgrade-lastdb.sh"

stale_input="$(candidate_input "$tmp/candidate-a" "$oid_a")"
out="$(HOME="$mock_home" \
  LOOM_LIVE=1 \
  LOOM_INPUT="$stale_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-b/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"red"' || fail "stale graph probe was not red"
printf '%s\n' "$out" | grep -q '"freshness":"stale"' || fail "stale relation was not recorded"
[ ! -e "$safe_log" ] || fail "stale graph reached the safe-upgrade driver"

equal_input="$(candidate_input "$tmp/candidate-b" "$oid_b")"
out="$(HOME="$mock_home" \
  LOOM_LIVE=1 \
  LOOM_INPUT="$equal_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-b/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"current"' || fail "equal graph probe did not no-op"
[ ! -e "$safe_log" ] || fail "equal graph probe reached the safe-upgrade driver"

forward_input="$(candidate_input "$tmp/candidate-b" "$oid_b")"

# Item fanout cannot override the immutable tuple that the parent supplies.
conflict_input="$(printf '%s' "$forward_input" | jq -c \
  '. + {item:(. + {lastdb_sha256:"0000000000000000000000000000000000000000000000000000000000000000"})}')"
set +e
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$conflict_input" "$STEP" PROBE 2>&1)"
rc=$?
set -e
[ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q 'immutable item/context mismatch' \
  || fail "item/top-level candidate conflict did not fail closed: rc=$rc out=$out"
[ ! -e "$safe_log" ] || fail "immutable input conflict reached the safe-upgrade driver"

# The step recomputes the digest. A caller cannot supply a valid tuple with a
# digest from another path or protocol input.
bad_digest_input="$(printf '%s' "$forward_input" | jq -c \
  '.candidate_artifact_digest="0000000000000000000000000000000000000000000000000000000000000000"')"
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$bad_digest_input" "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'exact candidate binding refused' \
  || fail "mismatched artifact digest did not fail closed: $out"
printf '%s\n' "$out" | grep -q 'artifact digest does not match' \
  || fail "artifact digest refusal did not name the tuple mismatch: $out"
[ ! -e "$safe_log" ] || fail "mismatched artifact digest reached the safe-upgrade driver"

legacy_protocol_input="$(printf '%s' "$forward_input" | jq -c \
  '.safe_upgrade_protocol_version="5"')"
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$legacy_protocol_input" "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'safe-upgrade protocol version is not 6' \
  || fail "legacy safe-upgrade protocol was not refused: $out"
[ ! -e "$safe_log" ] || fail "legacy safe-upgrade protocol reached the driver"

# Any byte change after kickoff fails before ancestry or the driver. This test
# mutates only the paired CLI, which a daemon-only execution key would miss.
cp "$tmp/candidate-b/lastdb" "$tmp/candidate-b/lastdb.saved"
printf '# byte change after kickoff\n' >>"$tmp/candidate-b/lastdb"
set +e
out="$(HOME="$mock_home" LOOM_LIVE=1 LOOM_INPUT="$forward_input" "$STEP" PROBE 2>&1)"
rc=$?
set -e
[ "$rc" -eq 0 ] && printf '%s\n' "$out" | grep -q 'exact candidate binding refused' \
  || fail "paired CLI byte change was not refused: rc=$rc out=$out"
printf '%s\n' "$out" | grep -q 'candidate pair bytes changed' \
  || fail "paired CLI byte refusal did not name changed bytes: $out"
[ ! -e "$safe_log" ] || fail "changed paired CLI reached the safe-upgrade driver"
mv "$tmp/candidate-b/lastdb.saved" "$tmp/candidate-b/lastdb"
chmod 755 "$tmp/candidate-b/lastdb"

# Forward probe, driver green (rc=0, final verdict GREEN_PROBE_ONLY).
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-green \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"green"' || fail "green probe was not green: $out"

# A long successful probe can outlive the caller's drive window. A repeated
# request for the same immutable execution must reuse the stored result. The
# CUTOVER node reruns the complete safe-upgrade driver before any live change.
safe_log_lines_before="$(wc -l <"$safe_log" | tr -d ' ')"
resumed_green_input="$(printf '%s\n' "$forward_input" | jq -c '. + {verdict:"green",probe_rc:0}')"
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=false-green \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-resume-green \
  LOOM_INPUT="$resumed_green_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'reused exact stored green result' \
  || fail "stored green probe was not reused: $out"
if printf '%s\n' "$out" | grep -q 'LOOM_CONTEXT_PATCH'; then
  fail "stored green probe wrote another context patch: $out"
fi
safe_log_lines_after="$(wc -l <"$safe_log" | tr -d ' ')"
[ "$safe_log_lines_after" = "$safe_log_lines_before" ] \
  || fail "stored green probe reran the safe-upgrade driver"

# JSON false compares equal to zero in Python. Exact type checks must reject
# it so a malformed prior receipt cannot skip the probe driver.
resumed_false_input="$(printf '%s\n' "$forward_input" | jq -c '. + {verdict:"green",probe_rc:false}')"
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=green \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-resume-false \
  LOOM_INPUT="$resumed_false_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q 'LOOM_CONTEXT_PATCH' \
  || fail "boolean probe receipt skipped the driver: $out"
safe_log_lines_after_false="$(wc -l <"$safe_log" | tr -d ' ')"
[ "$safe_log_lines_after_false" -eq $((safe_log_lines_before + 1)) ] \
  || fail "boolean probe receipt did not rerun the driver"

# Incident lx-20260830T203912: the smoke stage's own "VERDICT: GREEN" inside a
# rc=1 red probe must not read as green — the false green sent a RED candidate
# into CUTOVER.
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=false-green \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-red \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"red"' \
  || fail "smoke-section GREEN inside a rc=1 probe was not red: $out"
printf '%s\n' "$out" | grep -q 'REASON: candidate fails the latency bar' \
  || fail "red probe did not carry the driver REASON line: $out"
[ -s "$tmp/candidate-b/probe-fail-lx-test-probe-red.log" ] \
  || fail "red probe left no durable evidence file"

# A driver that prints a green verdict but exits non-zero is still red.
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=rc-red \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-rc \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE)"
printf '%s\n' "$out" | grep -q '"verdict":"red"' \
  || fail "green text with rc=1 was not red: $out"

# The driver budget ends before the Loom node budget. The wrapper first sends
# TERM to its isolated group so shell traps can remove the exact owned CoW.
# A stubborn descendant then receives KILL after the short cleanup grace.
timeout_graph="$tmp/timeout-graph.json"
jq '.states.PROBE.timeout_sec = 5' "$GRAPH" >"$timeout_graph"
timeout_residue="$tmp/timeout-owned-cow"
timeout_pid_file="$tmp/timeout-child.pid"
timeout_started="$(date +%s)"
out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=timeout \
  SAFE_TIMEOUT_RESIDUE="$timeout_residue" \
  SAFE_TIMEOUT_PID_FILE="$timeout_pid_file" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-timeout \
  LOOM_INPUT="$forward_input" \
  LOOM_SAFE_UPGRADE_GRAPH="$timeout_graph" \
  LOOM_SAFE_UPGRADE_CLEANUP_GRACE_SECS=2 \
  LOOM_SAFE_UPGRADE_KILL_DRAIN_SECS=1 \
  LOOM_SAFE_UPGRADE_TIMEOUT_HEADROOM_SECS=1 \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE 2>&1)"
timeout_elapsed=$(( $(date +%s) - timeout_started ))
printf '%s\n' "$out" | grep -q '"probe_rc":124' \
  || fail "bounded driver timeout did not record rc=124: $out"
printf '%s\n' "$out" | grep -q 'driver timed out after 2s' \
  || fail "bounded driver timeout did not name its reserved budget: $out"
[ "$timeout_elapsed" -lt 8 ] \
  || fail "bounded driver cleanup exceeded its node budget: ${timeout_elapsed}s"
[ ! -e "$timeout_residue" ] \
  || fail "TERM did not let the driver remove its owned CoW residue"
[ -s "$timeout_pid_file" ] || fail "timeout fixture did not start its stubborn child"
timeout_child_pid="$(cat "$timeout_pid_file")"
if kill -0 "$timeout_child_pid" 2>/dev/null; then
  fail "bounded timeout left a driver descendant alive"
fi

# Block wrapper signals across Popen and handle assignment. This seam queues
# TERM in that interval, then waits until the child's cleanup trap is ready.
signal_gap_residue="$tmp/signal-gap-owned-cow"
signal_gap_pid_file="$tmp/signal-gap-child.pid"
set +e
signal_gap_out="$(HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=timeout \
  SAFE_TIMEOUT_RESIDUE="$signal_gap_residue" \
  SAFE_TIMEOUT_PID_FILE="$signal_gap_pid_file" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-popen-signal \
  LOOM_INPUT="$forward_input" \
  LOOM_SAFE_UPGRADE_GRAPH="$GRAPH" \
  LOOM_SAFE_UPGRADE_CLEANUP_GRACE_SECS=2 \
  LOOM_SAFE_UPGRADE_KILL_DRAIN_SECS=1 \
  LOOM_SAFE_UPGRADE_TIMEOUT_HEADROOM_SECS=1 \
  LOOM_SAFE_UPGRADE_TEST_SIGNAL_AFTER_POPEN=TERM \
  LOOM_SAFE_UPGRADE_TEST_SIGNAL_AFTER_POPEN_READY="$signal_gap_pid_file" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE 2>&1)"
signal_gap_rc=$?
set -e
[ "$signal_gap_rc" -eq 143 ] \
  || fail "Popen signal seam returned $signal_gap_rc: $signal_gap_out"
printf '%s\n' "$signal_gap_out" \
  | grep -q 'forwarded the signal and reaped the isolated driver group' \
  || fail "Popen signal seam omitted the owned-group cleanup proof"
[ ! -e "$signal_gap_residue" ] \
  || fail "Popen signal seam skipped the driver cleanup trap"
[ -s "$signal_gap_pid_file" ] \
  || fail "Popen signal seam did not start the stubborn descendant"
if kill -0 "$(cat "$signal_gap_pid_file")" 2>/dev/null; then
  fail "Popen signal seam left a detached driver descendant alive"
fi

# The shell wrapper execs Python, so a TERM to the actual step PID reaches its
# signal handler. It forwards TERM to the detached driver group, lets the trap
# remove owned residue, and kills the stubborn descendant before it exits 143.
cancel_residue="$tmp/cancel-owned-cow"
cancel_pid_file="$tmp/cancel-child.pid"
cancel_out="$tmp/cancel.out"
HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_PROBE=timeout \
  SAFE_TIMEOUT_RESIDUE="$cancel_residue" \
  SAFE_TIMEOUT_PID_FILE="$cancel_pid_file" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-probe-external-term \
  LOOM_INPUT="$forward_input" \
  LOOM_SAFE_UPGRADE_GRAPH="$GRAPH" \
  LOOM_SAFE_UPGRADE_CLEANUP_GRACE_SECS=2 \
  LOOM_SAFE_UPGRADE_KILL_DRAIN_SECS=1 \
  LOOM_SAFE_UPGRADE_TIMEOUT_HEADROOM_SECS=1 \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" PROBE >"$cancel_out" 2>&1 &
cancel_wrapper_pid=$!
for _wait in $(seq 1 100); do
  [ -e "$cancel_residue" ] && [ -s "$cancel_pid_file" ] && break
  sleep 0.02
done
[ -e "$cancel_residue" ] && [ -s "$cancel_pid_file" ] \
  || fail "external TERM fixture did not start its driver tree"
set +e
kill -TERM "$cancel_wrapper_pid"
sleep 0.1
kill -TERM "$cancel_wrapper_pid" 2>/dev/null || true
wait "$cancel_wrapper_pid"
cancel_rc=$?
set -e
[ "$cancel_rc" -eq 143 ] \
  || fail "external TERM did not preserve signal exit 143: rc=$cancel_rc out=$(cat "$cancel_out")"
grep -q 'forwarded the signal and reaped the isolated driver group' "$cancel_out" \
  || fail "external TERM output omitted the wrapper cleanup proof"
[ ! -e "$cancel_residue" ] \
  || fail "external TERM did not let the driver cleanup trap run"
cancel_child_pid="$(cat "$cancel_pid_file")"
if kill -0 "$cancel_child_pid" 2>/dev/null; then
  fail "external TERM left a detached driver descendant alive"
fi

# A CUTOVER timeout can happen after launchctl bootout and after the driver's
# nohup fallback starts. The wrapper kills that full driver group. Recovery
# then runs in another session, restores the saved pair, and proves that the
# LaunchAgent owns the healthy socket listener.
CUTOVER_FIXTURE_ROOT="$(mktemp -d /tmp/lsu-cut.XXXXXX)"
CUTOVER_FIXTURE_ROOT="$(CDPATH= cd -- "$CUTOVER_FIXTURE_ROOT" && pwd -P)"
cutover_fixture="$CUTOVER_FIXTURE_ROOT"
cutover_tools="$cutover_fixture/bin"
cutover_live="$cutover_fixture/live"
cutover_old="$cutover_fixture/old"
cutover_primary="$cutover_fixture/primary"
cutover_socket="$cutover_primary/data/folddb.sock"
cutover_plist="$cutover_fixture/com.example.lastdbd-primary-test.plist"
cutover_launch_state="$cutover_fixture/launchd.loaded"
CUTOVER_SUPERVISED_PID_FILE="$cutover_fixture/supervised.pid"
cutover_emergency_pid_file="$cutover_fixture/emergency.pid"
cutover_launch_log="$cutover_fixture/launchctl.log"
cutover_recovery_root="$cutover_fixture/recovery-state"
cutover_server="$cutover_fixture/server.py"
cutover_label="com.example.lastdbd-primary-test"
export CUTOVER_SUPERVISED_PID_FILE
mkdir -p "$cutover_tools" "$cutover_live" "$cutover_primary/data"
ln -s "$cutover_live" "$cutover_primary/current"
printf 'ProgramArguments.0=%s\n' \
  "$cutover_primary/current/lastdbd" >"$cutover_plist"
make_candidate "$cutover_old" "0.23.3-old" "$oid_a"
cp -a "$cutover_old/lastdbd" "$cutover_live/lastdbd"
cp -a "$cutover_old/lastdb" "$cutover_live/lastdb"

cat >"$cutover_server" <<'PY'
#!/usr/bin/env python3
import os
import signal
import socket
import sys
from pathlib import Path

socket_path = Path(sys.argv[1])
pid_path = Path(sys.argv[2])
mode = sys.argv[3]
if mode == "supervised":
    try:
        os.setsid()
    except PermissionError:
        pass
if mode == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
else:
    def stop(_signum, _frame):
        try:
            socket_path.unlink()
        except FileNotFoundError:
            pass
        raise SystemExit(0)
    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
try:
    socket_path.unlink()
except FileNotFoundError:
    pass
server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(str(socket_path))
server.listen(4)
pid_path.write_text(str(os.getpid()), encoding="utf-8")
while True:
    conn, _ = server.accept()
    try:
        request = conn.recv(8192)
        if not request:
            continue
        body = b'{"status":"ok"}'
        try:
            conn.sendall(
                b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                + f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n".encode()
                + body
            )
        except BrokenPipeError:
            pass
    finally:
        conn.close()
PY
chmod 755 "$cutover_server"

cat >"$cutover_tools/launchctl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${FAKE_LAUNCHCTL_LOG:?}"
case "${1:-}" in
  help) exit 0 ;;
  print)
    [ -f "${FAKE_LAUNCHCTL_STATE:?}" ] \
      && [ -s "${FAKE_LAUNCHCTL_PID_FILE:?}" ] || exit 3
    pid="$(cat "$FAKE_LAUNCHCTL_PID_FILE")"
    kill -0 "$pid" 2>/dev/null || exit 3
    printf 'state = running\npid = %s\n' "$pid"
    ;;
  bootout)
    was_loaded=0
    [ -f "${FAKE_LAUNCHCTL_STATE:?}" ] && was_loaded=1
    if [ -s "${FAKE_LAUNCHCTL_PID_FILE:?}" ]; then
      pid="$(cat "$FAKE_LAUNCHCTL_PID_FILE")"
      kill "$pid" 2>/dev/null || true
      for _wait in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.01
      done
    fi
    rm -f "$FAKE_LAUNCHCTL_STATE" "$FAKE_LAUNCHCTL_PID_FILE" \
      "${FAKE_LAUNCHCTL_SOCKET:?}"
    [ "$was_loaded" -eq 1 ]
    ;;
  bootstrap)
    [ "${FAKE_LAUNCHCTL_BOOTSTRAP_FAIL:-0}" != 1 ] || exit 5
    rm -f "${FAKE_LAUNCHCTL_SOCKET:?}" "${FAKE_LAUNCHCTL_PID_FILE:?}"
    python3 "${FAKE_LAUNCHCTL_SERVER_SCRIPT:?}" \
      "$FAKE_LAUNCHCTL_SOCKET" "$FAKE_LAUNCHCTL_PID_FILE" supervised \
      >/dev/null 2>&1 &
    for _wait in $(seq 1 100); do
      [ -S "$FAKE_LAUNCHCTL_SOCKET" ] && [ -s "$FAKE_LAUNCHCTL_PID_FILE" ] && break
      sleep 0.01
    done
    [ -S "$FAKE_LAUNCHCTL_SOCKET" ] && [ -s "$FAKE_LAUNCHCTL_PID_FILE" ] \
      || exit 6
    : >"$FAKE_LAUNCHCTL_STATE"
    ;;
  *) exit 2 ;;
esac
SH

cat >"$cutover_tools/lsof" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ -f "${FAKE_LAUNCHCTL_STATE:?}" ] && [ -s "${FAKE_LAUNCHCTL_PID_FILE:?}" ] \
  || exit 1
cat "$FAKE_LAUNCHCTL_PID_FILE"
SH

cat >"$cutover_tools/codesign" <<'SH'
#!/usr/bin/env bash
exit 0
SH
cat >"$cutover_tools/xattr" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod 755 "$cutover_tools/launchctl" "$cutover_tools/lsof" \
  "$cutover_tools/codesign" "$cutover_tools/xattr"

export FAKE_LAUNCHCTL_STATE="$cutover_launch_state"
export FAKE_LAUNCHCTL_PID_FILE="$CUTOVER_SUPERVISED_PID_FILE"
export FAKE_LAUNCHCTL_SOCKET="$cutover_socket"
export FAKE_LAUNCHCTL_SERVER_SCRIPT="$cutover_server"
export FAKE_LAUNCHCTL_LOG="$cutover_launch_log"
"$cutover_tools/launchctl" bootstrap "gui/$(id -u)" "$cutover_plist"
[ -S "$cutover_socket" ] || fail "CUTOVER timeout fixture did not start its initial primary"

cutover_timeout_graph="$cutover_fixture/timeout-graph.json"
jq '.states.CUTOVER.timeout_sec = 18' "$GRAPH" >"$cutover_timeout_graph"
run_cutover_recovery_case() {
  local exec_id="$1" bootstrap_fail="$2" expected_rc="$3" mock_mode="${4:-timeout_effect}"
  local case_out="$cutover_fixture/$exec_id.out" emergency_pid
  rm -f "$cutover_emergency_pid_file"
  set +e
  HOME="$mock_home" \
    PATH="$cutover_tools:$PATH" \
    SAFE_LOG="$safe_log" \
    SAFE_MOCK_CUTOVER="$mock_mode" \
    SAFE_CUTOVER_LIVE_DIR="$cutover_live" \
    SAFE_CUTOVER_LAUNCHD_PROGRAM="$cutover_primary/current/lastdbd" \
    SAFE_CUTOVER_CANDIDATE_DIR="$tmp/candidate-b" \
    SAFE_CUTOVER_PRIMARY_HOME="$cutover_primary" \
    SAFE_CUTOVER_PRIMARY_SOCKET="$cutover_socket" \
    SAFE_CUTOVER_LAUNCHD_LABEL="$cutover_label" \
    SAFE_CUTOVER_LAUNCHD_PLIST="$cutover_plist" \
    SAFE_CUTOVER_LAUNCHCTL_BIN="$cutover_tools/launchctl" \
    SAFE_CUTOVER_SERVER_SCRIPT="$cutover_server" \
    SAFE_CUTOVER_EMERGENCY_PID_FILE="$cutover_emergency_pid_file" \
    FAKE_LAUNCHCTL_BOOTSTRAP_FAIL="$bootstrap_fail" \
    LOOM_LIVE=1 \
    LOOM_EXEC_ID="$exec_id" \
    LOOM_INPUT="$forward_input" \
    LOOM_SAFE_UPGRADE_GRAPH="$cutover_timeout_graph" \
    LOOM_SAFE_UPGRADE_CLEANUP_GRACE_SECS=2 \
    LOOM_SAFE_UPGRADE_KILL_DRAIN_SECS=1 \
    LOOM_SAFE_UPGRADE_RECOVERY_TIMEOUT_SECS=10 \
    LOOM_SAFE_UPGRADE_RECOVERY_TERM_GRACE_SECS=1 \
    LOOM_SAFE_UPGRADE_RECOVERY_KILL_DRAIN_SECS=1 \
    LOOM_SAFE_UPGRADE_TIMEOUT_HEADROOM_SECS=1 \
    LOOM_SAFE_UPGRADE_CUTOVER_RECOVERY_SCRIPT="$RECOVERY" \
    LASTDB_CUTOVER_RECOVERY_ROOT="$cutover_recovery_root" \
    LASTDB_CUTOVER_RECOVERY_LAUNCHCTL_BIN="$cutover_tools/launchctl" \
    LASTDB_CUTOVER_RECOVERY_CODESIGN_BIN="$cutover_tools/codesign" \
    LASTDB_CUTOVER_RECOVERY_XATTR_BIN="$cutover_tools/xattr" \
    LASTDB_CUTOVER_RECOVERY_HEALTH_WAIT_SECS=1 \
    LASTDB_LAUNCHD_BOOTSTRAP_RETRY_DELAYS=0 \
    LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
    LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
    "$STEP" CUTOVER >"$case_out" 2>&1
  case_rc=$?
  set -e
  [ "$case_rc" -eq "$expected_rc" ] \
    || fail "CUTOVER recovery case $exec_id returned $case_rc, expected $expected_rc: $(cat "$case_out")"
  [ -s "$cutover_emergency_pid_file" ] \
    || fail "CUTOVER recovery case $exec_id did not start the nohup fallback"
  emergency_pid="$(cat "$cutover_emergency_pid_file")"
  if kill -0 "$emergency_pid" 2>/dev/null; then
    fail "CUTOVER recovery case $exec_id left its nohup fallback alive"
  fi
  cat "$case_out"
}

cutover_ok_out="$(run_cutover_recovery_case lx-test-cutover-timeout-ok 0 124)"
printf '%s\n' "$cutover_ok_out" | grep -q 'CUTOVER_TIMEOUT_RECOVERY=green' \
  || fail "CUTOVER timeout did not prove green supervisor recovery"
printf '%s\n' "$cutover_ok_out" | grep -q 'bounded supervisor recovery succeeded' \
  || fail "CUTOVER timeout omitted its successful recovery result"
cmp -s "$cutover_old/lastdbd" "$cutover_live/lastdbd" \
  && cmp -s "$cutover_old/lastdb" "$cutover_live/lastdb" \
  || fail "CUTOVER timeout did not restore the exact pre-cutover pair"
"$cutover_tools/launchctl" print "gui/$(id -u)/$cutover_label" >/dev/null \
  || fail "CUTOVER timeout left the primary LaunchAgent unloaded"
curl -sS --max-time 2 --unix-socket "$cutover_socket" http://x/health \
  | grep -q '"status":"ok"' \
  || fail "CUTOVER timeout recovery did not restore socket health"
if find "$cutover_recovery_root" -mindepth 1 -print -quit | grep -q .; then
  fail "successful CUTOVER recovery retained its private state"
fi

# A normal driver failure after live effect start must also restore supervision.
cutover_exit_out="$(run_cutover_recovery_case \
  lx-test-cutover-normal-exit 0 1 fail_effect)"
printf '%s\n' "$cutover_exit_out" | grep -q 'CUTOVER_TIMEOUT_RECOVERY=green' \
  && printf '%s\n' "$cutover_exit_out" \
    | grep -q 'driver exited nonzero; bounded supervisor recovery succeeded' \
  || fail "normal CUTOVER failure did not complete bounded recovery"
cmp -s "$cutover_old/lastdbd" "$cutover_live/lastdbd" \
  && cmp -s "$cutover_old/lastdb" "$cutover_live/lastdb" \
  || fail "normal CUTOVER failure did not restore the exact pair"
"$cutover_tools/launchctl" print "gui/$(id -u)/$cutover_label" >/dev/null \
  || fail "normal CUTOVER failure left the primary unsupervised"
if find "$cutover_recovery_root" -mindepth 1 -print -quit | grep -q .; then
  fail "normal CUTOVER failure retained state after green recovery"
fi

# External cancellation after bootout follows the same recovery path. A second
# TERM during driver cleanup cannot interrupt the independent recovery step.
cutover_signal_out="$cutover_fixture/lx-test-cutover-external-term.out"
rm -f "$cutover_emergency_pid_file"
env \
  HOME="$mock_home" \
  PATH="$cutover_tools:$PATH" \
  SAFE_LOG="$safe_log" \
  SAFE_MOCK_CUTOVER=timeout_effect \
  SAFE_CUTOVER_LIVE_DIR="$cutover_live" \
  SAFE_CUTOVER_LAUNCHD_PROGRAM="$cutover_primary/current/lastdbd" \
  SAFE_CUTOVER_CANDIDATE_DIR="$tmp/candidate-b" \
  SAFE_CUTOVER_PRIMARY_HOME="$cutover_primary" \
  SAFE_CUTOVER_PRIMARY_SOCKET="$cutover_socket" \
  SAFE_CUTOVER_LAUNCHD_LABEL="$cutover_label" \
  SAFE_CUTOVER_LAUNCHD_PLIST="$cutover_plist" \
  SAFE_CUTOVER_LAUNCHCTL_BIN="$cutover_tools/launchctl" \
  SAFE_CUTOVER_SERVER_SCRIPT="$cutover_server" \
  SAFE_CUTOVER_EMERGENCY_PID_FILE="$cutover_emergency_pid_file" \
  FAKE_LAUNCHCTL_BOOTSTRAP_FAIL=0 \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-cutover-external-term \
  LOOM_INPUT="$forward_input" \
  LOOM_SAFE_UPGRADE_GRAPH="$cutover_timeout_graph" \
  LOOM_SAFE_UPGRADE_CLEANUP_GRACE_SECS=2 \
  LOOM_SAFE_UPGRADE_KILL_DRAIN_SECS=1 \
  LOOM_SAFE_UPGRADE_RECOVERY_TIMEOUT_SECS=10 \
  LOOM_SAFE_UPGRADE_RECOVERY_TERM_GRACE_SECS=1 \
  LOOM_SAFE_UPGRADE_RECOVERY_KILL_DRAIN_SECS=1 \
  LOOM_SAFE_UPGRADE_TIMEOUT_HEADROOM_SECS=1 \
  LOOM_SAFE_UPGRADE_CUTOVER_RECOVERY_SCRIPT="$RECOVERY" \
  LASTDB_CUTOVER_RECOVERY_ROOT="$cutover_recovery_root" \
  LASTDB_CUTOVER_RECOVERY_LAUNCHCTL_BIN="$cutover_tools/launchctl" \
  LASTDB_CUTOVER_RECOVERY_CODESIGN_BIN="$cutover_tools/codesign" \
  LASTDB_CUTOVER_RECOVERY_XATTR_BIN="$cutover_tools/xattr" \
  LASTDB_CUTOVER_RECOVERY_HEALTH_WAIT_SECS=1 \
  LASTDB_LAUNCHD_BOOTSTRAP_RETRY_DELAYS=0 \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" CUTOVER >"$cutover_signal_out" 2>&1 &
cutover_wrapper_pid=$!
for _wait in $(seq 1 200); do
  if [ -s "$cutover_emergency_pid_file" ]; then
    cutover_emergency_pid="$(cat "$cutover_emergency_pid_file")"
    kill -0 "$cutover_emergency_pid" 2>/dev/null && break
  fi
  sleep 0.01
done
[ -s "$cutover_emergency_pid_file" ] \
  || fail "CUTOVER external TERM fixture did not reach its live effect"
set +e
kill -TERM "$cutover_wrapper_pid"
sleep 0.1
kill -TERM "$cutover_wrapper_pid" 2>/dev/null || true
wait "$cutover_wrapper_pid"
cutover_signal_rc=$?
set -e
[ "$cutover_signal_rc" -eq 143 ] \
  || fail "CUTOVER external TERM returned $cutover_signal_rc: $(cat "$cutover_signal_out")"
grep -q 'CUTOVER_TIMEOUT_RECOVERY=green' "$cutover_signal_out" \
  && grep -q 'wrapper received signal 15' "$cutover_signal_out" \
  && grep -q 'bounded supervisor recovery succeeded' "$cutover_signal_out" \
  || fail "CUTOVER external TERM did not complete bounded recovery"
if kill -0 "$(cat "$cutover_emergency_pid_file")" 2>/dev/null; then
  fail "CUTOVER external TERM left its nohup fallback alive"
fi
cmp -s "$cutover_old/lastdbd" "$cutover_live/lastdbd" \
  && cmp -s "$cutover_old/lastdb" "$cutover_live/lastdb" \
  || fail "CUTOVER external TERM did not restore the exact pair"
"$cutover_tools/launchctl" print "gui/$(id -u)/$cutover_label" >/dev/null \
  || fail "CUTOVER external TERM left the primary unsupervised"
if find "$cutover_recovery_root" -mindepth 1 -print -quit | grep -q .; then
  fail "successful external-signal recovery retained its state"
fi

cutover_red_out="$(run_cutover_recovery_case lx-test-cutover-timeout-red 1 125)"
printf '%s\n' "$cutover_red_out" | grep -q 'bounded supervisor recovery failed rc=' \
  || fail "CUTOVER recovery failure was not distinct from the driver timeout"
retained_state="$(find "$cutover_recovery_root" -maxdepth 1 -type f -name '*.json' -print -quit)"
[ -n "$retained_state" ] && [ "$(stat -f '%Lp' "$retained_state")" = 600 ] \
  || fail "failed CUTOVER recovery did not retain owner-only exact state"
jq -e --arg sidebin_dir "$cutover_live" '
  .loom_execution_id == "lx-test-cutover-timeout-red"
  and .effect_started == true
  and .sidebin_dir == $sidebin_dir
  and (.backup_lastdbd_sha256 | test("^[0-9a-f]{64}$"))
  and (.backup_lastdb_sha256 | test("^[0-9a-f]{64}$"))
' "$retained_state" >/dev/null \
  || fail "failed CUTOVER recovery retained incomplete state"

HOME="$mock_home" \
  SAFE_LOG="$safe_log" \
  LOOM_LIVE=1 \
  LOOM_EXEC_ID=lx-test-safe-upgrade \
  LOOM_INPUT="$forward_input" \
  LASTDB_SAFE_UPGRADE_CURRENT_BIN="$tmp/current-a/lastdbd" \
  LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$STEP" CUTOVER >/dev/null
grep -q 'marker=1 exec=lx-test-safe-upgrade' "$safe_log" \
  || fail "Loom did not mark the live driver call"
grep -q "daemon=$tmp/candidate-b/lastdbd cli=$tmp/candidate-b/lastdb" "$safe_log" \
  || fail "Loom did not pass the exact candidate paths to the driver"
grep -q "daemon_sha=$(sha256_file "$tmp/candidate-b/lastdbd") cli_sha=$(sha256_file "$tmp/candidate-b/lastdb") source=$oid_b" "$safe_log" \
  || fail "Loom did not pass both hashes and the source OID to the driver"
grep -q 'receipt=.*/lx-test-safe-upgrade-.*\.receipt' "$safe_log" \
  || fail "Loom did not isolate the DEV receipt by execution and pair hashes"

set +e
out="$("$DRIVER" --candidate "$tmp/candidate-b/lastdbd" --yes 2>&1)"
rc=$?
set -e
[ "$rc" -eq 1 ] && printf '%s\n' "$out" | grep -q 'requires the Loom' \
  || fail "direct live driver bypass was not refused: rc=$rc out=$out"

dry_a="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-a/lastdbd" --source-git-oid "$oid_a" --dry-run --json)"
dry_b="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-b/lastdbd" --source-git-oid "$oid_b" --dry-run --json)"
[ "$(printf '%s\n' "$dry_a" | jq -r .graph)" = "lastdb-safe-upgrade" ] \
  || fail "launcher did not select the safe-upgrade graph"
version_a="$("$tmp/candidate-a/lastdbd" --version | awk '{print $NF}')"
version_b="$("$tmp/candidate-b/lastdbd" --version | awk '{print $NF}')"
digest_a="$(artifact_digest "$oid_a" "$tmp/candidate-a/lastdbd" "$tmp/candidate-a/lastdb" "$(sha256_file "$tmp/candidate-a/lastdbd")" "$(sha256_file "$tmp/candidate-a/lastdb")" "$version_a" "$version_a")"
digest_b="$(artifact_digest "$oid_b" "$tmp/candidate-b/lastdbd" "$tmp/candidate-b/lastdb" "$(sha256_file "$tmp/candidate-b/lastdbd")" "$(sha256_file "$tmp/candidate-b/lastdb")" "$version_b" "$version_b")"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" = "safe-upgrade-v6-$digest_a" ] \
  || fail "launcher key did not bind candidate A full tuple digest"
[ "$(printf '%s\n' "$dry_b" | jq -r .key)" = "safe-upgrade-v6-$digest_b" ] \
  || fail "launcher key did not bind candidate B full tuple digest"
[ "$(printf '%s\n' "$dry_a" | jq -r .candidate_artifact_digest)" = "$digest_a" ] \
  || fail "launcher output omitted candidate A artifact digest"
[ "$(printf '%s\n' "$dry_a" | jq -r .safe_upgrade_protocol_version)" = 6 ] \
  || fail "launcher output omitted safe-upgrade protocol v6"
key_a="$(printf '%s\n' "$dry_a" | jq -r .key)"
[ "${#digest_a}" -eq 64 ] && [ "${#key_a}" -eq 80 ] \
  || fail "launcher execution key is not fixed length"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" != "$(printf '%s\n' "$dry_b" | jq -r .key)" ] \
  || fail "different candidates reused one Loom key"

cp -R "$tmp/candidate-a" "$tmp/candidate-a-relocated"
dry_a_relocated="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-a-relocated/lastdbd" --source-git-oid "$oid_a" --dry-run --json)"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" != "$(printf '%s\n' "$dry_a_relocated" | jq -r .key)" ] \
  || fail "identical candidate bytes at a new canonical path reused one Loom key"

make_candidate "$tmp/candidate-a-cli-change" "0.23.3-1-g${oid_a:0:12}" "$oid_a"
printf '# distinct CLI bytes\n' >>"$tmp/candidate-a-cli-change/lastdb"
dry_a_cli_change="$(LASTDB_SAFE_UPGRADE_FOLD_GIT_DIR="$repo" \
  "$LAUNCHER" --candidate "$tmp/candidate-a-cli-change/lastdbd" --source-git-oid "$oid_a" --dry-run --json)"
[ "$(printf '%s\n' "$dry_a" | jq -r .key)" != "$(printf '%s\n' "$dry_a_cli_change" | jq -r .key)" ] \
  || fail "a paired CLI-only byte change reused the prior Loom execution key"

grep -q 'run_safe_upgrade_loom(candidate)' "$DOGFOOD" \
  || fail "legacy dogfood cutover does not route through Loom"
if grep -q 'cut_args = \["--yes"' "$DOGFOOD"; then
  fail "legacy dogfood retains a direct live driver call"
fi
if grep -q 'safe-upgrade-lastdb\.sh\|\["bash", skill, "--candidate", cand, "--yes"\]' \
  "$ROOT/lib/canary-loom/loom-canary-step.sh"; then
  fail "parent canary step retains an alternate live driver call"
fi
grep -q 'LASTDB_SAFE_UPGRADE_VIA_LOOM' "$DRIVER" \
  || fail "driver lacks the Loom live-cutover contract"
grep -q 'publish "\$defs/lastdb-safe-upgrade.json"' "$ROOT/bin/last-stack-canary-loom" \
  || fail "parent launcher does not publish the safe-upgrade child graph"
grep -q 'export_loom_run_deadline_for' "$ROOT/bin/last-stack-canary-loom" \
  || fail "parent launcher does not size LOOM_RUN_DEADLINE_SECS for the child"
grep -q 'export_loom_run_deadline_for lastdb-safe-upgrade' "$LAUNCHER" \
  || fail "safe-upgrade launcher does not size LOOM_RUN_DEADLINE_SECS"
grep -q 'last-stack-safe-upgrade-loom' "$ROOT/skills/lastdb-safe-upgrade/SKILL.md" \
  || fail "skill does not route live upgrades through Loom"

printf 'PASS: LastDB live safe upgrades are Loom-only and fail closed on stale ancestry\n'
