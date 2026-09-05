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
trap 'rm -rf -- "$TMP"' EXIT
TMP="$(CDPATH= cd -- "$TMP" && pwd -P)"
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

receipt="$TMP/exact.receipt"
write_dev_stamp_receipt_v2 \
  "$receipt" "$PRIMARY" "$COW" 7 7 \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" \
  "backup/latest" "$now_rfc" "$now" \
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
expect_red_field latest_key ""
expect_red_field committed_at 2026-01-01T00:00:00Z
expect_red_field committed_epoch 1
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

future_epoch=$((now + LASTDB_DEV_STAMP_FUTURE_SKEW_SECS_DEFAULT + 120))
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

grep -q 'safe-upgrade-v6-<digest>' "$SKILL_MD" \
  || fail "SKILL.md does not state the exact execution-key tuple"
grep -q 'both canonical paths' "$SKILL_MD" \
  || fail "SKILL.md omits candidate paths from the execution-key digest"
grep -q 'laststore_backup_manifest.json' "$SKILL_MD" \
  || fail "SKILL.md omits the production manifest-cache scrub"
grep -q 'current-session.json' "$SKILL_MD" \
  || fail "SKILL.md omits the copied session scrub"
for name in LASTDB_HOME FOLDDB_HOME FOLD_SYNC_DEVICE_ID; do
  grep -q "$name" "$SKILL_MD" \
    || fail "SKILL.md omits the unset variable $name"
done

printf 'OK: exact-candidate LastDB DEV photograph receipt gate\n'
