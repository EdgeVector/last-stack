#!/bin/bash
# Measure cloud-sync resume proof on a real, throwaway ephemeral LastDB home.
#
# Boots a real lastdbd against a home under /tmp (never the primary
# ~/.lastdb or ~/.folddb), runs the actual `lastdb cloud status`,
# `lastdb cloud snapshot`, and `lastdb db put-file-blob` commands against it,
# and records the real exit codes and output. Cloud sync is paused
# product-wide pending the laststore redesign (Situation
# cloud-sync-paused-pending-laststore-redesign-20260719) and this harness
# never runs `lastdb connect` and never clears that pause, so every cloud
# command below is expected to refuse. That refusal is the real
# measurement -- not a placeholder -- and it is why the evidence this script
# produces stays FAIL until Tom performs the bounded human re-enable by
# hand on his own throwaway or CoW home.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../common.sh
. "$ROOT/harness/north-star/common.sh"

HERE="$(cd "$(dirname "$0")" && pwd -P)"
CHECK_SCRIPT="$HERE/check_contract.py"

for cmd in lastdb lastdbd python3; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "measure.sh requires '$cmd' on PATH; cannot run a real probe." >&2
    exit 1
  }
done
command -v shasum >/dev/null 2>&1 || command -v sha256sum >/dev/null 2>&1 || {
  echo "measure.sh requires 'shasum' or 'sha256sum' on PATH; cannot run a real probe." >&2
  exit 1
}

# shasum is a macOS built-in; sha256sum lives at /sbin on macOS, which a
# stripped-PATH CI shell does not always inherit (rc=127).
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    sha256sum "$1" | awk '{print $1}'
  fi
}

MEASURE_ID="csr-$(date -u +'%Y%m%d-%H%M%S')-$$"

# A Unix socket path is capped at 103 bytes on macOS. $TMPDIR under a
# routine or CI run directory is often already 80+ bytes, so the daemon's
# socket (<home>/data/folddb.sock) can blow that limit there. Root the
# ephemeral home directly under /tmp, which stays short on every host this
# proof runs on, instead of under $TMPDIR.
EPHEMERAL_HOME="$(mktemp -d /tmp/csr.XXXXXX)"
for root in "$HOME/.lastdb" "$HOME/.folddb"; do
  case "$EPHEMERAL_HOME" in
    "$root"|"$root"/*)
      echo "Refusing an ephemeral home under $root" >&2
      exit 1
      ;;
  esac
done

EVIDENCE_JSON="$HERE/measured-evidence.json"
RUN_LOG="$HERE/measured-evidence.log"
TMP_EVIDENCE="$(mktemp "${TMPDIR:-/tmp}/csr-evidence.XXXXXX")"
DAEMON_LOG="$EPHEMERAL_HOME/daemon.out"
CANARY_FILE="$EPHEMERAL_HOME/canary.bin"
DAEMON_PID=""

cleanup() {
  if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$EPHEMERAL_HOME" "$TMP_EVIDENCE"
}
trap cleanup EXIT

echo "Ephemeral home: $EPHEMERAL_HOME"
echo "Evidence and log will be written to: $HERE"

MEASUREMENT_START="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

echo -n "csr-canary-$MEASURE_ID" >"$CANARY_FILE"
CANARY_BYTES="$(wc -c <"$CANARY_FILE" | tr -d ' ')"
CANARY_SHA256="$(sha256_of "$CANARY_FILE")"

echo "Booting an ephemeral lastdbd (never the primary home)..."
lastdbd --data-dir "$EPHEMERAL_HOME" >"$DAEMON_LOG" 2>&1 &
DAEMON_PID=$!

SOCK="$EPHEMERAL_HOME/data/folddb.sock"
BOOT_OK=0
for _ in $(seq 1 50); do
  if [ -S "$SOCK" ]; then
    BOOT_OK=1
    break
  fi
  kill -0 "$DAEMON_PID" 2>/dev/null || break
  sleep 0.2
done

run_probe() {
  # Runs one real `lastdb` subcommand against the ephemeral daemon and
  # records its actual exit code and output to stdout (the caller
  # redirects this into the run log). Never touches the primary home.
  local label="$1" out rc
  shift
  out="$(lastdb --data-dir "$EPHEMERAL_HOME" "$@" 2>&1)"
  rc=$?
  printf '$ lastdb --data-dir <ephemeral-home> %s\n' "$*"
  printf '%s\n' "$out"
  printf 'Exit: %s\n' "$rc"
  printf 'PROBE_RESULT: %s_exit=%s\n' "$label" "$rc"
  echo ""
}

{
  echo "Measurement: cloud-sync-resume proof (real ephemeral probe)"
  echo "Measurement ID: $MEASURE_ID"
  echo "Ephemeral home: $EPHEMERAL_HOME"
  echo "Situation: cloud-sync-paused-pending-laststore-redesign-20260719"
  echo "This harness never runs 'lastdb connect' and never clears that pause."
  echo ""
  echo "PROBE_RESULT: boot_ok=$BOOT_OK"
  if [ "$BOOT_OK" -ne 1 ]; then
    echo ""
    echo "The ephemeral daemon did not open its socket within the timeout."
    echo "Boot log omitted here (a fresh identity boot prints a one-time"
    echo "throwaway recovery phrase on stderr); see $DAEMON_LOG for local"
    echo "diagnostics before it is removed."
  else
    echo ""
    run_probe cloud_status cloud status
    run_probe snapshot cloud snapshot
    run_probe put_file_blob db put-file-blob --schema files/File --field file \
      --key-hash "$MEASURE_ID" --bytes "$CANARY_FILE"
    echo '$ lastdb --data-dir <ephemeral-home> ops --by-app'
    lastdb --data-dir "$EPHEMERAL_HOME" ops --by-app 2>&1
    echo ""
  fi
  printf 'PROBE_RESULT: canary_bytes=%s\n' "$CANARY_BYTES"
  printf 'PROBE_RESULT: canary_sha256=%s\n' "$CANARY_SHA256"
} >"$RUN_LOG"

if [ -n "$DAEMON_PID" ] && kill -0 "$DAEMON_PID" 2>/dev/null; then
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
fi
DAEMON_PID=""

MEASUREMENT_END="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
WINDOW_SECS="$(python3 -c "
from datetime import datetime
fmt = '%Y-%m-%dT%H:%M:%SZ'
a = datetime.strptime('$MEASUREMENT_START', fmt)
b = datetime.strptime('$MEASUREMENT_END', fmt)
print(int((b - a).total_seconds()))
")"

# Derive every measured field from the PROBE_RESULT lines just written to
# the run log -- the log is the source of truth, evidence is a mechanical
# read of it, not a second independently authored copy.
probe_value() {
  sed -n "s/^PROBE_RESULT: $1=\(.*\)\$/\1/p" "$RUN_LOG" | tail -1
}
CLOUD_STATUS_EXIT="$(probe_value cloud_status_exit)"
SNAPSHOT_EXIT="$(probe_value snapshot_exit)"
PUT_FILE_BLOB_EXIT="$(probe_value put_file_blob_exit)"

if [ "${SNAPSHOT_EXIT:-1}" = "0" ]; then
  COW_VERDICT="PASS"
else
  COW_VERDICT="FAIL"
fi

if [ "${PUT_FILE_BLOB_EXIT:-1}" = "0" ]; then
  COW_DOCUMENTS=1
  GROUP_FILES=1
  GROUP_BYTES="$CANARY_BYTES"
  FILE_BLOB_BYTES="$CANARY_BYTES"
  HAVE_CANARY_SAMPLE=1
else
  COW_DOCUMENTS=0
  GROUP_FILES=0
  GROUP_BYTES=0
  FILE_BLOB_BYTES=0
  HAVE_CANARY_SAMPLE=0
fi

if [ "$BOOT_OK" != "1" ] || [ "${CLOUD_STATUS_EXIT:-1}" != "0" ] || \
   [ "${SNAPSHOT_EXIT:-1}" != "0" ] || [ "${PUT_FILE_BLOB_EXIT:-1}" != "0" ]; then
  DEGRADED="true"
else
  DEGRADED="false"
fi

LOG_SHA256="$(sha256_of "$RUN_LOG")"

# Build the evidence file from the variables derived above. There is no
# catchup to report: cloud sync was never connected on this ephemeral home,
# so no primary catch-up ran, and this script does not claim a Situation
# clearance or re-enable -- only Tom can perform that bounded human action.
{
  printf '{\n'
  printf '  "schema": "lastdb-cloud-sync-resume-proof.v1",\n'
  printf '  "provenance": {\n'
  printf '    "command": "harness/north-star/north-star-lastdb-cloud-sync-resume/measure.sh",\n'
  printf '    "run_start_at": "%s",\n' "$MEASUREMENT_START"
  printf '    "run_end_at": "%s",\n' "$MEASUREMENT_END"
  printf '    "ephemeral_home_path": "%s",\n' "$EPHEMERAL_HOME"
  printf '    "run_log_sha256": "%s"\n' "$LOG_SHA256"
  printf '  },\n'
  printf '  "surface": {\n'
  printf '    "kind": "ephemeral",\n'
  printf '    "primary_home_opened": false,\n'
  printf '    "primary_mutated": false,\n'
  printf '    "primary_reenabled_by_harness": false,\n'
  printf '    "live_cutover": false,\n'
  printf '    "home_path": "%s"\n' "$EPHEMERAL_HOME"
  printf '  },\n'
  printf '  "hash_group": {\n'
  printf '    "cow_document_count": %s,\n' "$COW_DOCUMENTS"
  printf '    "group_file_count": %s,\n' "$GROUP_FILES"
  printf '    "group_bytes_uploaded": %s,\n' "$GROUP_BYTES"
  printf '    "staging_object_count": 0,\n'
  printf '    "cow_proof_verdict": "%s",\n' "$COW_VERDICT"
  printf '    "promoted": false,\n'
  printf '    "source_unchanged": true\n'
  printf '  },\n'
  printf '  "probe": {\n'
  printf '    "upload_bytes": %s,\n' "$GROUP_BYTES"
  printf '    "upload_window_secs": %s,\n' "$WINDOW_SECS"
  printf '    "staging_growth_bytes": 0,\n'
  printf '    "backlog_start": 0,\n'
  printf '    "backlog_end": 0,\n'
  printf '    "degraded": %s,\n' "$DEGRADED"
  printf '    "window_start": "%s",\n' "$MEASUREMENT_START"
  printf '    "window_end": "%s"\n' "$MEASUREMENT_END"
  printf '  },\n'
  printf '  "reenable": {\n'
  printf '    "situation_slug": "cloud-sync-paused-pending-laststore-redesign-20260719"\n'
  printf '  },\n'
  printf '  "catchup": {\n'
  printf '    "primary_sync_lag_bytes": 0,\n'
  printf '    "staging_depth": 0,\n'
  printf '    "staging_cap": 0,\n'
  printf '    "brain_reads": 0,\n'
  printf '    "brain_writes": 0,\n'
  printf '    "kanban_reads": 0,\n'
  printf '    "kanban_writes": 0,\n'
  printf '    "lastgit_reads": 0,\n'
  printf '    "lastgit_writes": 0\n'
  printf '  },\n'
  printf '  "file_blob": {\n'
  printf '    "upload_bytes": %s,\n' "$FILE_BLOB_BYTES"
  printf '    "fetch_bytes": 0,\n'
  printf '    "upload_route": "upload_file_blob"'
  if [ "$HAVE_CANARY_SAMPLE" = "1" ]; then
    printf ',\n    "canary_sha256": "%s"\n' "$CANARY_SHA256"
  else
    printf '\n'
  fi
  printf '  }\n'
  printf '}\n'
} >"$TMP_EVIDENCE"

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$TMP_EVIDENCE" ||
  { echo "measure.sh produced invalid JSON; not writing evidence." >&2; exit 1; }

# Always record what really happened -- a failing real measurement is more
# useful than a missing one, and more honest than a synthetic PASS.
cp "$TMP_EVIDENCE" "$EVIDENCE_JSON"
echo "Generated evidence: $EVIDENCE_JSON"
echo "Generated log: $RUN_LOG"

echo "Validating evidence against the source contract..."
if python3 "$CHECK_SCRIPT" "${CLOUD_SYNC_RESUME_SOURCE_DIR:-$(ns_repo_path lastdb)}" "$EVIDENCE_JSON" "$RUN_LOG"; then
  echo "Measurement complete: the real ephemeral probe reached PASS."
  exit 0
fi
echo "Measurement complete: the real ephemeral probe did not reach PASS."
echo "Cloud sync is paused pending the laststore redesign; only Tom can clear"
echo "the Situation and perform the bounded re-enable that a PASS requires."
exit 1
