#!/usr/bin/env bash
# A last-stack gate must not take its exit code from another repository's tip.
#
# fold merged a correct refactor at 2026-09-26T11:24Z and every last-stack PR
# went red on it: the same tree ran .lastgit/ci.sh rc=0 at 11:22Z and rc=1 at
# 11:40Z with no last-stack change, and rc=1 on a pristine origin/main archive.
# papercut-last-stack-ci-shard-grades-the-live-fold-portal-head-20260926
#
# This guard fixes the two lanes in place:
#   the LIVE fold head may only REPORT   — a violating live tree keeps the gate green
#   the PINNED fold oid BLOCKS           — a violating pin reds the gate, naming the oid
# and it fixes the message: a red must carry the rule the report already named.
# papercut-north-star-proof-test-fail-message-drops-the-report-reason-20260926
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
PIN_FILE="$ROOT/harness/north-star/fold-source.pin"
FIXTURE="$ROOT/tests/fixtures/north-star-lastdb-schema-root-data-attribution"
PROOF_TEST="$ROOT/tests/last-stack-north-star-proof-schema-root-attribution.sh"
SIBLING_TEST="$ROOT/tests/last-stack-north-star-proof-cloud-sync-resume.sh"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fold-source-lanes.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

fail() {
  echo "last-stack-north-star-fold-source-lanes: $*" >&2
  exit 1
}

bash -n "$0"
# shellcheck source=../harness/north-star/common.sh
. "$ROOT/harness/north-star/common.sh"

# --- the pin itself ---------------------------------------------------------
[ -f "$PIN_FILE" ] || fail "no fold-source pin at $PIN_FILE"
pin="$(ns_fold_source_pin)" || fail "ns_fold_source_pin read no oid from $PIN_FILE"
case "$pin" in
  [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
  *) fail "the pin is not a full 40-hex fold oid: $pin" ;;
esac
grep -q '^#' "$PIN_FILE" || fail "the pin file does not say what it pins or how to move it"
# A comment-only pin file must read as ABSENT, not as the comment text.
printf '%s\n' '# nothing pinned' >"$WORK/comment-only.pin"
if NORTH_STAR_FOLD_SOURCE_PIN_FILE="$WORK/comment-only.pin" ns_fold_source_pin >/dev/null 2>&1; then
  fail "a comment-only pin file read as a pinned oid"
fi

# --- the reporting lane can never set an exit code --------------------------
cat >"$WORK/failing.md" <<'MD'
FAIL

Source contract: FAIL

Source failures:
- A write appends an attribution event before its pending scope.

MD
set +e
ns_fold_drift_report "probe" deadbeef "$WORK/failing.md" >"$WORK/drift.out" 2>&1
drift_rc=$?
ns_fold_drift_report "probe" deadbeef "$WORK/absent.md" >>"$WORK/drift.out" 2>&1
absent_rc=$?
set -e
[ "$drift_rc" = 0 ] || fail "the reporting lane returned $drift_rc on a FAIL report; it must never gate"
[ "$absent_rc" = 0 ] || fail "the reporting lane returned $absent_rc on a missing report; it must never gate"
grep -q 'A write appends an attribution event before its pending scope.' "$WORK/drift.out" ||
  fail "the drift notice does not carry the rule the report named: $(cat "$WORK/drift.out")"
grep -q 'oid=deadbeef' "$WORK/drift.out" ||
  fail "the drift notice does not name the fold oid it graded: $(cat "$WORK/drift.out")"

# --- both proof tests must grade the pin, not only the live head ------------
for t in "$PROOF_TEST" "$SIBLING_TEST"; do
  [ -f "$t" ] || fail "missing proof test $t"
  grep -q 'ns_fold_drift_report' "$t" ||
    fail "$(basename "$t") does not report the live fold head through the non-gating lane"
  grep -q 'ns_fold_source_pin' "$t" ||
    fail "$(basename "$t") does not grade the pinned fold oid"
  # The regression is a `fail` taking its verdict from the LIVE report.
  if grep -n 'fail .*\$live_report\|live_report.*|| *fail .*Source contract' "$t" |
      grep -q 'Source contract'; then
    fail "$(basename "$t") fails on a Source contract verdict read from the live fold head"
  fi
  grep -q 'the Fold portal source did not satisfy' "$t" &&
    fail "$(basename "$t") still reds this gate on another repository's content"
  # Every fail that follows a report assertion must carry the report's reason.
  grep -q 'ns_fold_report_failures' "$t" ||
    fail "$(basename "$t") does not print the report reason on a failure"
done

# --- the harness grades the commit it is given, and names it ----------------
for h in north-star-lastdb-schema-root-data-attribution north-star-lastdb-cloud-sync-resume; do
  run="$ROOT/harness/north-star/$h/run.sh"
  grep -q 'NORTH_STAR_FOLD_SOURCE_OID' "$run" ||
    fail "$h/run.sh ignores NORTH_STAR_FOLD_SOURCE_OID, so the pinned lane cannot exist"
  # Strip comments first: the rationale comment next to the fix quotes the
  # defective label verbatim, so a raw grep fails on correct source.
  sed -e 's/[[:space:]]*#.*$//' "$run" | grep -q 'fold-portal:HEAD' &&
    fail "$h/run.sh still labels the report fold-portal:HEAD, which names no commit"
done

# --- end to end: a violating LIVE tree over a conformant PIN ----------------
# Two commits in one bare mirror: the pin conforms, HEAD violates.
seed="$WORK/seed"
mkdir -p "$seed/fold_db/crates/core/src/db_operations" \
  "$seed/fold_db/crates/core/src/fold_db_core/mutation_manager" \
  "$seed/lastdb_node/src"
cp -R "$FIXTURE/fold_db/crates/core/src/schema" "$seed/fold_db/crates/core/src/"
cp "$FIXTURE/fold_db/crates/core/src/db_operations/attribution_ledger.rs" \
  "$seed/fold_db/crates/core/src/db_operations/attribution_ledger.rs"
cp "$FIXTURE/lastdb_node/src/attribution_epoch.rs" "$seed/lastdb_node/src/attribution_epoch.rs"
cp "$FIXTURE/fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs" \
  "$seed/fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs"
git -C "$seed" init -q -b main
git -C "$seed" -c user.name=Test -c user.email=test@example.invalid add -A
git -C "$seed" -c user.name=Test -c user.email=test@example.invalid commit -q -m conformant
good_oid="$(git -C "$seed" rev-parse HEAD)"
cat >"$seed/fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs" <<'RS'
fn attribution_source_events_enabled() -> bool {
    std::env::var("LASTDB_ATTRIBUTION_SOURCE_EVENTS")
        .is_ok_and(|value| matches!(value.trim(), "1" | "true" | "on" | "yes"))
}
    async fn write_mutations_batch_with_receipt_cloud(&self) -> Result<(), ()> {
        self.db_ops
            .attribution()
            .append_events_and_clear_pending_scopes(attribution_events(), &mutation_ids)
            .await?;
        self.db_ops.attribution().begin_pending_scopes(&scopes).await?;
        Ok(())
    }
RS
git -C "$seed" -c user.name=Test -c user.email=test@example.invalid add -A
git -C "$seed" -c user.name=Test -c user.email=test@example.invalid commit -q -m violating
bad_oid="$(git -C "$seed" rev-parse HEAD)"
mirror="$WORK/fold-mirror.git"
git init -q --bare -b main "$mirror"
git -C "$seed" push -q "$mirror" main
git --git-dir="$mirror" symbolic-ref HEAD refs/heads/main
[ "$(git --git-dir="$mirror" rev-parse HEAD)" = "$bad_oid" ] ||
  fail "the fixture mirror HEAD is not the violating commit"

ws="$WORK/ws"
mkdir -p "$ws/fold/.portal"
printf '%s\n' "$mirror" >"$ws/fold/.portal/cache"

run_proof() { # run_proof <pin oid> <out>
  printf '%s\n' "$1" >"$WORK/probe.pin"
  set +e
  env EDGEVECTOR_WORKSPACE="$ws" NORTH_STAR_FOLD_SOURCE_PIN_FILE="$WORK/probe.pin" \
    bash "$PROOF_TEST" >"$2" 2>&1
  local rc=$?
  set -e
  printf '%s\n' "$rc"
}

rc="$(run_proof "$good_oid" "$WORK/live-violates.out")"
[ "$rc" = 0 ] ||
  fail "a violating LIVE fold head red this gate (rc=$rc): $(tail -3 "$WORK/live-violates.out")"
grep -q "fold-source-drift: .*oid=$bad_oid source=FAIL" "$WORK/live-violates.out" ||
  fail "the violating live head produced no drift report: $(tail -5 "$WORK/live-violates.out")"
grep -q 'A write appends an attribution event before its pending scope.' "$WORK/live-violates.out" ||
  fail "the drift report omits the rule that failed: $(tail -5 "$WORK/live-violates.out")"

rc="$(run_proof "$bad_oid" "$WORK/pin-violates.out")"
[ "$rc" = 1 ] ||
  fail "a violating PINNED fold oid did not red this gate (rc=$rc); the blocking lane is gone"
grep -q "pinned fold $bad_oid" "$WORK/pin-violates.out" ||
  fail "the pinned failure does not name the oid: $(tail -5 "$WORK/pin-violates.out")"
grep -q 'A write appends an attribution event before its pending scope.' "$WORK/pin-violates.out" ||
  fail "the pinned failure does not carry the rule the report named: $(tail -5 "$WORK/pin-violates.out")"

# --- a mirror that cannot serve the source at all ---------------------------
# A fresh host, a pruned mirror, or a fetch that has not run yet. This is an
# environment fact about EdgeVector/fold, so it must not red a last-stack PR
# either — the same rule as a violating live tree.
empty="$WORK/empty.git"
git init -q --bare -b main "$empty"
ws_empty="$WORK/ws-empty"
mkdir -p "$ws_empty/fold/.portal"
printf '%s\n' "$empty" >"$ws_empty/fold/.portal/cache"
printf '%s\n' "$pin" >"$WORK/probe.pin"
set +e
env EDGEVECTOR_WORKSPACE="$ws_empty" NORTH_STAR_FOLD_SOURCE_PIN_FILE="$WORK/probe.pin" \
  bash "$PROOF_TEST" >"$WORK/empty-mirror.out" 2>&1
empty_rc=$?
set -e
[ "$empty_rc" = 0 ] ||
  fail "an unreadable fold mirror red this gate (rc=$empty_rc): $(tail -3 "$WORK/empty-mirror.out")"
grep -q 'not readable in' "$WORK/empty-mirror.out" ||
  fail "an unreadable fold mirror was not reported: $(tail -5 "$WORK/empty-mirror.out")"

echo "PASS last-stack-north-star-fold-source-lanes"
