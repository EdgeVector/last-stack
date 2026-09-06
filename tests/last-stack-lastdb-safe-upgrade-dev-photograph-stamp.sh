#!/usr/bin/env bash
# Exact-candidate receipt tests for the LastDB safe-upgrade DEV photograph.
set -euo pipefail

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)"
GATE="$ROOT/skills/lastdb-safe-upgrade/scripts/dev-photograph-stamp-gate.sh"
DRIVER="$ROOT/skills/lastdb-safe-upgrade/scripts/safe-upgrade-lastdb.sh"
PROOF="$ROOT/skills/lastdb-safe-upgrade/scripts/dev-photograph-candidate-proof.sh"
SKILL_MD="$ROOT/skills/lastdb-safe-upgrade/SKILL.md"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

[ -x "$GATE" ] || fail "receipt gate is absent or not executable"
[ -x "$PROOF" ] || fail "candidate proof helper is absent or not executable"
[ -x "$DRIVER" ] || fail "safe-upgrade driver is absent or not executable"
bash -n "$GATE"
bash -n "$PROOF"
bash -n "$DRIVER"

# shellcheck source=../skills/lastdb-safe-upgrade/scripts/dev-photograph-stamp-gate.sh
. "$GATE"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/lastdb-dev-stamp-v2.XXXXXX")"
SHORT_TMP="$(mktemp -d /tmp/ldp.XXXXXX)"
trap 'rm -rf -- "$TMP" "$SHORT_TMP"' EXIT
TMP="$(CDPATH= cd -- "$TMP" && pwd -P)"
SHORT_TMP="$(unset CDPATH; cd -- "$SHORT_TMP" && pwd -P)"
PRIMARY="$TMP/primary"
COW="$TMP/proof-root/cow"
CAND="$TMP/candidate"
mkdir -p "$PRIMARY" "$COW" "$CAND"
VERSION="0.24.0-1-gaaaaaaaaaaaa"
OID="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
cat >"$CAND/lastdbd" <<EOF
#!/usr/bin/env bash
printf 'lastdbd %s\\n' '$VERSION'
EOF
cat >"$CAND/lastdb" <<EOF
#!/usr/bin/env bash
printf 'lastdb %s\\n' '$VERSION'
EOF
chmod 755 "$CAND/lastdbd" "$CAND/lastdb"

export LOOM_EXEC_ID="lx-exact-candidate-test"
export LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID="$OID"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH="$CAND/lastdbd"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH="$CAND/lastdb"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION="$VERSION"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION="$VERSION"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256="$(dev_stamp_sha256_file "$CAND/lastdbd")"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256="$(dev_stamp_sha256_file "$CAND/lastdb")"
export LASTDB_HOME="$PRIMARY"

now="$(date +%s)"
now_rfc="$(date -u -r "$now" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$now" +%Y-%m-%dT%H:%M:%SZ)"
USER_HASH="11111111111111111111111111111111"
CLOUD_DB_HASH="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
MANIFEST_CACHE="$COW/laststore_backup_manifest.json"

receipt="$TMP/exact.receipt"
write_dev_stamp_receipt_v2 \
  "$receipt" "$PRIMARY" "$COW" 7 7 \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$CLOUD_DB_HASH" \
  "$CLOUD_DB_HASH/backup/manifests/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "$CLOUD_DB_HASH/backup/latest" "$USER_HASH" "$MANIFEST_CACHE" "$now_rfc" "$now" \
  || fail "v2 receipt writer failed"
assert_dev_photograph_stamp_ok "$receipt" "$PRIMARY" \
  || fail "exact v2 receipt was refused"
[ "$(_dev_stamp_file_mode "$receipt")" = "600" ] || fail "receipt mode is not 600"
[ "$(find "$TMP" -name '.exact.receipt.tmp.*' -print | wc -l | tr -d ' ')" = "0" ] \
  || fail "atomic receipt writer left a temporary file"

replace_key() {
  local file="$1" key="$2" replacement="$3" tmp_file
  tmp_file="$file.edit"
  awk -v k="$key" -v v="$replacement" '
    index($0, k "=") == 1 { print k "=" v; next }
    { print }
  ' "$file" >"$tmp_file"
  chmod 600 "$tmp_file"
  mv "$tmp_file" "$file"
}

expect_red_field() {
  local key="$1" replacement="$2" case_receipt
  case_receipt="$TMP/red-$key.receipt"
  cp "$receipt" "$case_receipt"
  chmod 600 "$case_receipt"
  replace_key "$case_receipt" "$key" "$replacement"
  if assert_dev_photograph_stamp_ok "$case_receipt" "$PRIMARY" >/dev/null 2>&1; then
    fail "receipt accepted mismatched field $key"
  fi
}

# Each v2 field can fail the gate. The two valid time fields also receive
# dedicated stale and future cases below.
expect_red_field receipt_version 1
expect_red_field verdict RED
expect_red_field loom_execution_id lx-other
expect_red_field source_git_oid cccccccccccccccccccccccccccccccccccccccc
expect_red_field lastdbd_path "$TMP/other/lastdbd"
expect_red_field lastdb_path "$TMP/other/lastdb"
expect_red_field lastdbd_sha256 cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
expect_red_field lastdb_sha256 dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd
expect_red_field lastdbd_version other
expect_red_field lastdb_version other
expect_red_field api_url "https://jdsx4ixk2i.execute-api.us-east-1.amazonaws.com"
expect_red_field home "$PRIMARY"
expect_red_field primary_home "$TMP/other-primary"
expect_red_field counter 0
expect_red_field cas_counter 8
expect_red_field manifest_sha256 missing
expect_red_field cloud_db_hash invalid
expect_red_field manifest_key missing
expect_red_field latest_key ""
expect_red_field user_hash invalid
expect_red_field manifest_cache "$TMP/other-manifest.json"
expect_red_field report_top_level false
expect_red_field committed_at 2026-01-01T00:00:00Z
expect_red_field committed_epoch 1

mismatched_latest_scope="$TMP/mismatched-latest-scope.receipt"
cp "$receipt" "$mismatched_latest_scope"
chmod 600 "$mismatched_latest_scope"
replace_key "$mismatched_latest_scope" latest_key \
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/backup/latest"
assert_dev_photograph_stamp_ok "$mismatched_latest_scope" "$PRIMARY" >/dev/null 2>&1 \
  && fail "receipt accepted a latest key for another cloud DB hash"

wrong_manifest_scope="$TMP/wrong-manifest-scope.receipt"
cp "$receipt" "$wrong_manifest_scope"
chmod 600 "$wrong_manifest_scope"
replace_key "$wrong_manifest_scope" manifest_key \
  "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc/backup/manifests/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
assert_dev_photograph_stamp_ok "$wrong_manifest_scope" "$PRIMARY" >/dev/null 2>&1 \
  && fail "receipt accepted a manifest key for another cloud DB hash"

wrong_manifest_digest="$TMP/wrong-manifest-digest.receipt"
cp "$receipt" "$wrong_manifest_digest"
chmod 600 "$wrong_manifest_digest"
replace_key "$wrong_manifest_digest" manifest_key \
  "$CLOUD_DB_HASH/backup/manifests/dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
assert_dev_photograph_stamp_ok "$wrong_manifest_digest" "$PRIMARY" >/dev/null 2>&1 \
  && fail "receipt accepted a manifest key for another digest"
for key in \
  fresh_device_id \
  production_cloud_config_absent \
  production_cloud_residue_absent \
  production_presence_cache_absent \
  production_manifest_cache_absent \
  copied_session_absent \
  identity_preserved \
  bootstrap_preserved; do
  expect_red_field "$key" false
done

duplicate="$TMP/duplicate.receipt"
cp "$receipt" "$duplicate"
printf 'counter=7\n' >>"$duplicate"
chmod 600 "$duplicate"
assert_dev_photograph_stamp_ok "$duplicate" "$PRIMARY" >/dev/null 2>&1 \
  && fail "duplicate receipt key was accepted"

unknown="$TMP/unknown.receipt"
cp "$receipt" "$unknown"
printf 'unreviewed_fact=true\n' >>"$unknown"
chmod 600 "$unknown"
assert_dev_photograph_stamp_ok "$unknown" "$PRIMARY" >/dev/null 2>&1 \
  && fail "unknown receipt key was accepted"

missing="$TMP/missing.receipt"
awk '$0 !~ /^manifest_sha256=/' "$receipt" >"$missing"
chmod 600 "$missing"
assert_dev_photograph_stamp_ok "$missing" "$PRIMARY" >/dev/null 2>&1 \
  && fail "missing receipt key was accepted"

legacy="$TMP/legacy.receipt"
cat >"$legacy" <<EOF
verdict=GREEN
api_url=$LASTDB_DEV_BACKUP_API_URL_DEFAULT
home=$COW
primary_home=$PRIMARY
counter=7
committed_at=$now_rfc
EOF
chmod 600 "$legacy"
assert_dev_photograph_stamp_ok "$legacy" "$PRIMARY" >/dev/null 2>&1 \
  && fail "legacy GREEN receipt was accepted"

bad_mode="$TMP/bad-mode.receipt"
cp "$receipt" "$bad_mode"
chmod 644 "$bad_mode"
assert_dev_photograph_stamp_ok "$bad_mode" "$PRIMARY" >/dev/null 2>&1 \
  && fail "world-readable receipt was accepted"

ln -s "$receipt" "$TMP/link.receipt"
assert_dev_photograph_stamp_ok "$TMP/link.receipt" "$PRIMARY" >/dev/null 2>&1 \
  && fail "receipt symlink was accepted"

stale_epoch=$((now - LASTDB_DEV_STAMP_MAX_AGE_SECS_DEFAULT - 5))
stale_rfc="$(date -u -r "$stale_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$stale_epoch" +%Y-%m-%dT%H:%M:%SZ)"
stale="$TMP/stale.receipt"
cp "$receipt" "$stale"
replace_key "$stale" committed_at "$stale_rfc"
replace_key "$stale" committed_epoch "$stale_epoch"
assert_dev_photograph_stamp_ok "$stale" "$PRIMARY" >/dev/null 2>&1 \
  && fail "stale receipt was accepted"

# Read the clock HERE, not from `now` at the top of the file. The gate rejects a
# receipt only while committed_epoch > check_time + skew(60s), so a future_epoch
# derived from a stale `now` loses one second of margin per second the test
# spends getting here — about 166 lines, and an unloaded pass already takes 34s
# end to end. Once >120s elapsed the "future" receipt was no longer in the
# future and the gate correctly ACCEPTED it, failing this assertion. That is
# what reddened required CI on main 13270464 while the identical tree passed on
# the PR head, and it blocked the host-track artifact publish behind it.
future_now="$(date +%s)"
future_epoch=$((future_now + LASTDB_DEV_STAMP_FUTURE_SKEW_SECS_DEFAULT + 120))
future_rfc="$(date -u -r "$future_epoch" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
  || date -u -d "@$future_epoch" +%Y-%m-%dT%H:%M:%SZ)"
future="$TMP/future.receipt"
cp "$receipt" "$future"
replace_key "$future" committed_at "$future_rfc"
replace_key "$future" committed_epoch "$future_epoch"
assert_dev_photograph_stamp_ok "$future" "$PRIMARY" >/dev/null 2>&1 \
  && fail "future receipt was accepted"

# The live pair must still match the immutable tuple. A receipt alone cannot
# authorize replacement bytes at the same path.
cp "$CAND/lastdb" "$CAND/lastdb.saved"
printf '# mutation\n' >>"$CAND/lastdb"
assert_candidate_binding_matches_expected "$CAND/lastdbd" "$CAND/lastdb" "$OID" >/dev/null 2>&1 \
  && fail "candidate CLI mutation passed the exact binding gate"
mv "$CAND/lastdb.saved" "$CAND/lastdb"
chmod 755 "$CAND/lastdb"
assert_candidate_binding_matches_expected "$CAND/lastdbd" "$CAND/lastdb" "$OID" \
  || fail "restored exact pair failed the binding gate"

export LASTDB_DEV_STAMP_RECEIPT="$receipt"
driver_out="$($DRIVER --check-dev-stamp 2>&1)" \
  || fail "driver check refused an exact receipt: $driver_out"
printf '%s\n' "$driver_out" | grep -q 'VERDICT: GREEN' \
  || fail "driver check did not report GREEN"
export LASTDB_DEV_STAMP_RECEIPT="$legacy"
set +e
driver_out="$($DRIVER --check-dev-stamp 2>&1)"
driver_rc=$?
set -e
[ "$driver_rc" -ne 0 ] && printf '%s\n' "$driver_out" | grep -q 'VERDICT: RED' \
  || fail "driver check accepted a legacy receipt"

# Exercise the proof helper with isolated fake binaries. No real daemon,
# LastSecrets entry, socket, cloud account, or primary home participates.
PROOF_FIXTURE="$SHORT_TMP/f"
PROOF_PRIMARY="$PROOF_FIXTURE/primary"
PROOF_CLONE="$PROOF_FIXTURE/rollback"
PROOF_CAND="$PROOF_FIXTURE/candidate"
PROOF_TMP_ROOT="$PROOF_FIXTURE/tmp"
PROOF_RECEIPT_ROOT="$PROOF_FIXTURE/receipts"
PROOF_EVIDENCE_ROOT="$PROOF_FIXTURE/state/dev-photograph-failures"
PROOF_LOG="$PROOF_FIXTURE/proof.out"
PROOF_PID_FILE="$PROOF_FIXTURE/candidate.pid"
PROOF_RESIDUE_MARKER="$PROOF_FIXTURE/residue-removed"
mkdir -p \
  "$PROOF_PRIMARY/data" "$PROOF_CLONE/data" "$PROOF_CAND" \
  "$PROOF_TMP_ROOT" "$PROOF_RECEIPT_ROOT" "$PROOF_EVIDENCE_ROOT"
printf 'identity-seed\n' >"$PROOF_PRIMARY/identity.key"
printf 'bootstrap\n' >"$PROOF_PRIMARY/.bootstrap_done"
printf 'production-device\n' >"$PROOF_PRIMARY/data/.device_id"
printf 'identity-seed\n' >"$PROOF_CLONE/identity.key"
printf 'bootstrap\n' >"$PROOF_CLONE/.bootstrap_done"
printf 'production-device\n' >"$PROOF_CLONE/data/.device_id"
printf '%s\n' '{"store_uuid":"proof-store-uuid"}' >"$PROOF_CLONE/laststore_high_water.json"
printf 'active-production\n' >"$PROOF_CLONE/cloud_sync.json"
printf 'paused-production\n' >"$PROOF_CLONE/cloud_sync.json.paused"
printf 'hidden-production-temp\n' >"$PROOF_CLONE/.cloud_sync.json.tmp"
chmod 600 \
  "$PROOF_PRIMARY/identity.key" "$PROOF_PRIMARY/.bootstrap_done" \
  "$PROOF_PRIMARY/data/.device_id" "$PROOF_CLONE/identity.key" \
  "$PROOF_CLONE/.bootstrap_done" "$PROOF_CLONE/data/.device_id"

cat >"$PROOF_CAND/lastdbd" <<'PY'
#!/usr/bin/env python3
import os
import signal
import socket
import sys
import time
from pathlib import Path

VERSION = "0.24.0-2-gbbbbbbbbbbbb"
if "--version" in sys.argv:
    print(f"lastdbd {VERSION}")
    raise SystemExit(0)

home = Path(sys.argv[sys.argv.index("--data-dir") + 1])
socket_path = home / "data" / "folddb.sock"
pid_file = os.environ.get("DEV_FAKE_DAEMON_PID_FILE")
if pid_file:
    Path(pid_file).write_text(str(os.getpid()), encoding="utf-8")
mode = os.environ.get("DEV_FAKE_SNAPSHOT_MODE")
if mode == "stale_pre_cas":
    (home / "laststore_backup_manifest.json").write_text("{}\n", encoding="utf-8")
server = socket.socket(socket.AF_UNIX)
server.bind(str(socket_path))
if mode in {"timeout", "stale_pre_cas"}:
    for index in range(12):
        print(f"daemon diagnostic line {index}", file=sys.stderr)
    print(
        f"post-CAS backup orphan GC active api_key=test-only-key "
        f"device_id=fresh-dev-device object={'a' * 64} path={home}/data/private",
        file=sys.stderr,
        flush=True,
    )

def stop(*_args):
    server.close()
    try:
        socket_path.unlink()
    except FileNotFoundError:
        pass
    raise SystemExit(0)

signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
while True:
    time.sleep(1)
PY

cat >"$PROOF_CAND/lastdb" <<'PY'
#!/usr/bin/env python3
import json
import hashlib
import os
import sys
import time
from pathlib import Path

VERSION = "0.24.0-2-gbbbbbbbbbbbb"
if "--version" in sys.argv:
    print(f"lastdb {VERSION}")
    raise SystemExit(0)

home = Path(sys.argv[sys.argv.index("--data-dir") + 1])
if "connect" in sys.argv:
    if not sys.stdin.read().strip():
        raise SystemExit(40)
    residue = list(home.glob("cloud_sync.json*")) + list(home.glob(".cloud_sync.json.tmp*"))
    if residue:
        raise SystemExit(41)
    (home / "cloud_sync.json").write_text(
        json.dumps({
            "api_url": "https://ygyu7ritx8.execute-api.us-west-2.amazonaws.com",
            "api_key": "test-only-key",
        }),
        encoding="utf-8",
    )
    os.chmod(home / "cloud_sync.json", 0o600)
    (home / "data" / ".device_id").write_text("fresh-dev-device\n", encoding="utf-8")
    os.chmod(home / "data" / ".device_id", 0o600)
    marker = os.environ.get("DEV_FAKE_RESIDUE_MARKER")
    if marker:
        Path(marker).write_text("removed\n", encoding="utf-8")
    raise SystemExit(0)

if "snapshot" not in sys.argv:
    raise SystemExit(42)
mode = os.environ.get("DEV_FAKE_SNAPSHOT_MODE", "success")
if mode == "stale_pre_cas":
    print("authentication refused before snapshot request", file=sys.stderr, flush=True)
    raise SystemExit(73)
if mode == "timeout":
    cache = home / "laststore_backup_manifest.json"
    cache.write_text("{}\n", encoding="utf-8")
    for index in range(12):
        print(f"snapshot diagnostic line {index}", file=sys.stderr)
    print(json.dumps({
        "ok": False,
        "user_hash": "2" * 32,
        "report": {"manifest_sha256": "d" * 64},
        "api_key": "test-only-key",
        "path": str(home / "private"),
    }), file=sys.stderr)
    print(
        f"snapshot waits after backup_latest_cas path={home}/private "
        f"device_id=fresh-dev-device",
        file=sys.stderr,
        flush=True,
    )
    time.sleep(30)
if mode == "mutate_device":
    (home / "data" / ".device_id").write_text("changed-after-snapshot\n", encoding="utf-8")
    os.chmod(home / "data" / ".device_id", 0o600)

cache = home / "laststore_backup_manifest.json"
if mode != "missing_cache":
    cache.write_text("{}\n", encoding="utf-8")
store_uuid = json.loads(
    (home / "laststore_high_water.json").read_text(encoding="utf-8")
)["store_uuid"]
cloud_db_hash = hashlib.sha256(
    f"laststore-db:{store_uuid}".encode("utf-8")
).hexdigest()
report = {
    "manifest_sha256": "c" * 64,
    "manifest_key": cloud_db_hash + "/backup/manifests/" + "c" * 64,
    "latest_key": cloud_db_hash + "/backup/latest",
    "counter": 9,
    "cut_csn": 8,
    "chunks_referenced": 1,
    "chunks_uploaded": 1,
    "chunks_already_present": 0,
    "bytes_uploaded": 2,
    "frontier_through": 8,
    "cas_counter": 9,
    "gc_eligible_log_segments": 0,
}
payload = {
    "ok": True,
    "user_hash": "2" * 32,
    "report": report,
    "manifest_cache": str(cache),
}
if mode == "nested_report":
    payload.pop("report")
    payload["data"] = {"report": report}
elif mode == "invalid_user_hash":
    payload["user_hash"] = "not-a-user-hash"
elif mode == "wrong_manifest_cache":
    payload["manifest_cache"] = str(home / "wrong-manifest.json")
elif mode == "mismatched_latest_key":
    payload["report"]["latest_key"] = "3" * 64 + "/backup/latest"
elif mode == "wrong_manifest_scope":
    payload["report"]["manifest_key"] = "3" * 64 + "/backup/manifests/" + "c" * 64
elif mode == "wrong_manifest_digest":
    payload["report"]["manifest_key"] = cloud_db_hash + "/backup/manifests/" + "d" * 64
print(json.dumps(payload))
PY

cat >"$PROOF_CAND/lastsecrets" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = get ]
printf 'test-only-invite\n'
SH
chmod 755 "$PROOF_CAND/lastdbd" "$PROOF_CAND/lastdb" "$PROOF_CAND/lastsecrets"

PROOF_VERSION="0.24.0-2-gbbbbbbbbbbbb"
PROOF_OID="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
export LASTDB_SAFE_UPGRADE_EXPECTED_SOURCE_OID="$PROOF_OID"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_PATH="$PROOF_CAND/lastdbd"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_PATH="$PROOF_CAND/lastdb"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_VERSION="$PROOF_VERSION"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_VERSION="$PROOF_VERSION"
LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256="$(dev_stamp_sha256_file "$PROOF_CAND/lastdbd")"
LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256="$(dev_stamp_sha256_file "$PROOF_CAND/lastdb")"
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256
export LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256

run_proof_case() {
  local name="$1" mode="$2" timeout_secs="$3" safe_name proof_pid
  local evidence_root="${4:-$PROOF_EVIDENCE_ROOT}"
  safe_name="$(printf '%s' "lx-proof-$name" | tr -c 'A-Za-z0-9._-' '_')"
  export LOOM_EXEC_ID="lx-proof-$name"
  PROOF_CASE_RECEIPT="$PROOF_RECEIPT_ROOT/${safe_name}-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDBD_SHA256:0:16}-${LASTDB_SAFE_UPGRADE_EXPECTED_LASTDB_SHA256:0:16}.receipt"
  rm -f -- "$PROOF_CASE_RECEIPT" "$PROOF_LOG" "$PROOF_PID_FILE" "$PROOF_RESIDUE_MARKER"
  set +e
  DEV_FAKE_DAEMON_PID_FILE="$PROOF_PID_FILE" \
  DEV_FAKE_RESIDUE_MARKER="$PROOF_RESIDUE_MARKER" \
  DEV_FAKE_SNAPSHOT_MODE="$mode" \
  LASTDB_DEV_STAMP_ROOT="$PROOF_RECEIPT_ROOT" \
  LASTDB_DEV_PHOTOGRAPH_TMP_ROOT="$PROOF_TMP_ROOT" \
  LASTDB_DEV_PHOTOGRAPH_EVIDENCE_ROOT="$evidence_root" \
  LASTDB_DEV_PHOTOGRAPH_EVIDENCE_TAIL_LINES=6 \
  LASTDB_DEV_PHOTOGRAPH_EVIDENCE_TAIL_BYTES=4096 \
  LASTDB_DEV_PHOTOGRAPH_LASTSECRETS_BIN="$PROOF_CAND/lastsecrets" \
  LASTDB_DEV_PHOTOGRAPH_READY_WAITS=80 \
  LASTDB_DEV_PHOTOGRAPH_READY_SLEEP_SECS=0.05 \
  LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_ATTEMPTS=1 \
  LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_RETRY_SECS=0 \
  LASTDB_DEV_PHOTOGRAPH_SNAPSHOT_TIMEOUT_SECS="$timeout_secs" \
    "$PROOF" \
      --candidate-lastdbd "$PROOF_CAND/lastdbd" \
      --candidate-lastdb "$PROOF_CAND/lastdb" \
      --primary-home "$PROOF_PRIMARY" \
      --clone-source "$PROOF_CLONE" \
      --receipt "$PROOF_CASE_RECEIPT" \
      --source-git-oid "$PROOF_OID" >"$PROOF_LOG" 2>&1
  PROOF_CASE_RC=$?
  set -e
  PROOF_CASE_OUT="$(cat "$PROOF_LOG")"
  PROOF_CASE_EVIDENCE="$(printf '%s\n' "$PROOF_CASE_OUT" \
    | sed -n 's/^DEV_PHOTOGRAPH_EVIDENCE: //p' | tail -1)"
  if find "$PROOF_TMP_ROOT" -mindepth 1 -print -quit | grep -q .; then
    fail "proof case $name left its owned CoW root"
  fi
  if [ -s "$PROOF_PID_FILE" ]; then
    proof_pid="$(cat "$PROOF_PID_FILE")"
    if kill -0 "$proof_pid" 2>/dev/null; then
      fail "proof case $name left its candidate daemon alive"
    fi
  fi
  return "$PROOF_CASE_RC"
}

run_proof_case success success 3 \
  || fail "strict top-level proof failed: $PROOF_CASE_OUT"
printf '%s\n' "$PROOF_CASE_OUT" | grep -q 'DEV_PHOTOGRAPH: GREEN' \
  || fail "successful proof omitted its GREEN verdict"
[ -z "$PROOF_CASE_EVIDENCE" ] \
  || fail "successful proof wrote failure evidence"
[ -f "$PROOF_CASE_RECEIPT" ] || fail "successful proof omitted its receipt"
[ -f "$PROOF_RESIDUE_MARKER" ] || fail "hidden cloud residue reached DEV connect"
assert_dev_photograph_stamp_ok "$PROOF_CASE_RECEIPT" "$PROOF_PRIMARY" \
  || fail "successful proof wrote a receipt that its gate refused"
grep -q '^report_top_level=true$' "$PROOF_CASE_RECEIPT" \
  || fail "receipt omitted the top-level report proof"
grep -q '^user_hash=22222222222222222222222222222222$' "$PROOF_CASE_RECEIPT" \
  || fail "receipt omitted the sealed snapshot user hash"
grep -Eq '^cloud_db_hash=[0-9a-f]{64}$' "$PROOF_CASE_RECEIPT" \
  || fail "receipt omitted the locally derived cloud DB hash"
grep -q '/laststore_backup_manifest.json$' "$PROOF_CASE_RECEIPT" \
  || fail "receipt omitted the exact isolated manifest cache"

for bad_mode in \
  nested_report invalid_user_hash wrong_manifest_cache missing_cache \
  mutate_device mismatched_latest_key wrong_manifest_scope wrong_manifest_digest; do
  if run_proof_case "$bad_mode" "$bad_mode" 3; then
    fail "proof accepted invalid snapshot mode $bad_mode"
  fi
  [ ! -e "$PROOF_CASE_RECEIPT" ] \
    || fail "invalid snapshot mode $bad_mode wrote a receipt"
done

if run_proof_case stale stale_pre_cas 3; then
  fail "proof accepted a pre-CAS snapshot failure with an existing manifest cache"
fi
[ ! -e "$PROOF_CASE_RECEIPT" ] \
  || fail "pre-CAS snapshot failure wrote a receipt"
[ -n "$PROOF_CASE_EVIDENCE" ] && [ -d "$PROOF_CASE_EVIDENCE" ] \
  || fail "pre-CAS snapshot failure left no durable evidence: $PROOF_CASE_OUT"
stale_summary="$PROOF_CASE_EVIDENCE/summary.txt"
stale_daemon_tail="$PROOF_CASE_EVIDENCE/daemon.tail.log"
stale_snapshot_tail="$PROOF_CASE_EVIDENCE/snapshot.tail.log"
grep -q '^DEV_PHOTOGRAPH_FAILURE phase=snapshot_command attempt=1/1 timeout_secs=3 snapshot_rc=73$' \
  "$stale_summary" \
  || fail "existing cache falsely changed the pre-CAS failure phase"
grep -q '^DEV_PHOTOGRAPH_OBSERVED manifest_cache_present_before=true manifest_cache_present_after=true$' \
  "$stale_summary" \
  || fail "pre-CAS evidence omitted the separate cache observations"
grep -q 'post-CAS backup orphan GC active' "$stale_daemon_tail" \
  || fail "the regression fixture omitted its uncorrelated daemon text"
grep -q 'authentication refused before snapshot request' "$stale_snapshot_tail" \
  || fail "pre-CAS evidence omitted the current snapshot failure"

timeout_started="$(date +%s)"
if run_proof_case timeout timeout 1; then
  fail "proof accepted a snapshot command that exceeded its deadline"
fi
timeout_elapsed=$(( $(date +%s) - timeout_started ))
[ "$timeout_elapsed" -lt 10 ] \
  || fail "snapshot command timeout was not bounded: ${timeout_elapsed}s"
[ ! -e "$PROOF_CASE_RECEIPT" ] \
  || fail "timed-out snapshot wrote a receipt"
[ -n "$PROOF_CASE_EVIDENCE" ] && [ -d "$PROOF_CASE_EVIDENCE" ] \
  || fail "timed-out snapshot left no durable evidence bundle: $PROOF_CASE_OUT"
summary="$PROOF_CASE_EVIDENCE/summary.txt"
daemon_tail="$PROOF_CASE_EVIDENCE/daemon.tail.log"
snapshot_tail="$PROOF_CASE_EVIDENCE/snapshot.tail.log"
for evidence_file in "$summary" "$daemon_tail" "$snapshot_tail"; do
  [ -f "$evidence_file" ] && [ ! -L "$evidence_file" ] \
    || fail "failure evidence file is absent or unsafe: $evidence_file"
  [ "$(_dev_stamp_file_mode "$evidence_file")" = 600 ] \
    || fail "failure evidence file is not owner-only: $evidence_file"
done
grep -q '^DEV_PHOTOGRAPH_FAILURE phase=snapshot_command attempt=1/1 timeout_secs=1 snapshot_rc=124$' \
  "$summary" || fail "timeout evidence omitted the exact phase and budget"
grep -q '^DEV_PHOTOGRAPH_OBSERVED manifest_cache_present_before=false manifest_cache_present_after=true$' \
  "$summary" || fail "timeout evidence omitted the separate cache observations"
printf '%s\n' "$PROOF_CASE_OUT" \
  | grep -q '^DEV_PHOTOGRAPH_FAILURE phase=snapshot_command attempt=1/1 timeout_secs=1 snapshot_rc=124$' \
  || fail "timeout output omitted the exact phase and budget"
grep -q 'post-CAS backup orphan GC active' "$daemon_tail" \
  || fail "daemon evidence omitted its observed post-CAS text"
grep -q '<redacted-snapshot-envelope>' "$snapshot_tail" \
  || fail "snapshot evidence did not suppress the raw envelope"
grep -q 'snapshot waits after backup_latest_cas' "$snapshot_tail" \
  || fail "snapshot evidence omitted its bounded diagnostic tail"
[ "$(wc -l <"$daemon_tail" | tr -d ' ')" -le 7 ] \
  && [ "$(wc -l <"$snapshot_tail" | tr -d ' ')" -le 7 ] \
  || fail "failure evidence exceeded the configured six-line tail bound"
if grep -ERq \
    'test-only-key|fresh-dev-device|22222222222222222222222222222222|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd' \
    "$PROOF_CASE_EVIDENCE" \
    || grep -Fq "$PROOF_TMP_ROOT" "$summary" "$daemon_tail" "$snapshot_tail" \
    || printf '%s\n' "$PROOF_CASE_OUT" | grep -Eq \
      'test-only-key|fresh-dev-device|22222222222222222222222222222222|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'; then
  fail "failure evidence exposed a secret, digest, device ID, or full CoW path"
fi

evidence_blocker="$PROOF_FIXTURE/evidence-root-is-a-file"
printf 'not a directory\n' >"$evidence_blocker"
if run_proof_case noev timeout 1 "$evidence_blocker"; then
  fail "proof passed after its photograph and evidence copy both failed"
fi
printf '%s\n' "$PROOF_CASE_OUT" \
  | grep -q '^DEV_PHOTOGRAPH_FAILURE phase=snapshot_command attempt=1/1 timeout_secs=1 snapshot_rc=124$' \
  || fail "evidence-copy failure omitted the exact phase and budget: $PROOF_CASE_OUT"
printf '%s\n' "$PROOF_CASE_OUT" \
  | grep -q '^DEV_PHOTOGRAPH_EVIDENCE: unavailable$' \
  || fail "evidence-copy failure did not report the fail-closed state: $PROOF_CASE_OUT"
[ ! -e "$PROOF_CASE_RECEIPT" ] \
  || fail "evidence-copy failure wrote a receipt"
if printf '%s\n' "$PROOF_CASE_OUT" | grep -Eq \
    'test-only-key|fresh-dev-device|22222222222222222222222222222222|dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'; then
  fail "evidence-copy failure exposed raw proof data"
fi

grep -q 'safe-upgrade-v6-<digest>' "$SKILL_MD" \
  || fail "SKILL.md does not state the exact execution-key tuple"
grep -q 'both canonical paths' "$SKILL_MD" \
  || fail "SKILL.md omits candidate paths from the execution-key digest"
grep -q 'laststore_backup_manifest.json' "$SKILL_MD" \
  || fail "SKILL.md omits the production manifest-cache scrub"
grep -q 'current-session.json' "$SKILL_MD" \
  || fail "SKILL.md omits the copied session scrub"
grep -q '.cloud_sync.json.tmp' "$SKILL_MD" \
  || fail "SKILL.md omits hidden cloud credential residue"
grep -q 'top-level `report`' "$SKILL_MD" \
  || fail "SKILL.md omits the sealed snapshot envelope"
for name in LASTDB_HOME FOLDDB_HOME FOLD_SYNC_DEVICE_ID; do
  grep -q "$name" "$SKILL_MD" \
    || fail "SKILL.md omits the unset variable $name"
done

printf 'OK: exact-candidate LastDB DEV photograph receipt gate\n'
