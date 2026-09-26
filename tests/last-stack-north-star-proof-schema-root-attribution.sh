#!/usr/bin/env bash
# Offline contract for north-star-lastdb-schema-root-data-attribution.
# The source check reads a fixture tree, a Fold worktree, or the Fold portal.
# It does not open a LastDB home and it does not delete from a source home.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
RUNNER="$ROOT/bin/last-stack-north-star-proof"
EVALUATOR="$ROOT/bin/last-stack-kanban-done-when-eval"
HARNESS="$ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/run.sh"
CHECK="$ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/check_contract.py"
FIXTURE="$ROOT/tests/fixtures/north-star-lastdb-schema-root-data-attribution"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/schema-root-attribution-proof-test.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# shellcheck source=../harness/north-star/common.sh
. "$ROOT/harness/north-star/common.sh"

# A report names the exact rule that failed, and this file then deleted $WORK
# one instruction after printing a line that did not carry it. Several
# assertions are a bare `grep -q` under `set -e` and printed NOTHING at all.
# papercut-north-star-proof-test-fail-message-drops-the-report-reason-20260926
on_err() {
  local rc="$1" line="$2" report
  echo "$(basename "$0"): failed at line $line (rc=$rc)" >&2
  for report in "$WORK"/*/*.md "$WORK"/*-report/*.md; do
    [ -f "$report" ] || continue
    grep -q '^Source failures:' "$report" || continue
    printf '  %s: %s\n' "${report#"$WORK"/}" "$(ns_fold_report_failures "$report")" >&2
  done
}
trap 'on_err "$?" "$LINENO"' ERR

fail() {
  echo "last-stack-north-star-proof-schema-root-attribution: $*" >&2
  exit 1
}

expect_verdict() {
  local file="$1" want="$2" got
  [ -f "$file" ] || fail "missing report $file"
  got="$(sed -n '1p' "$file")"
  [ "$got" = "$want" ] || fail "verdict $(printf '%s' "$got") != $want in $file"
}

chmod +x "$RUNNER" "$HARNESS"
bash -n "$HARNESS"
bash -n "$0"
python3 -m py_compile "$CHECK"

"$RUNNER" --list | grep -qx 'north-star-lastdb-schema-root-data-attribution' ||
  fail "--list omits north-star-lastdb-schema-root-data-attribution"

python3 - "$WORK/good.json" <<'PY'
import json
import sys

doc = {
    "schema": "lastdb-schema-root-data-attribution-proof.v1",
    "surface": {
        "kind": "isolated-copy",
        "primary_opened": False,
        "primary_mutated": False,
        "source_delete": False,
        "prod_cutover": False,
        "captured_at": "2026-09-23T00:00:00Z",
    },
    "copy": {
        "source_digest_unchanged": True,
        "injected_object_deleted": True,
        "rooted_objects_preserved": True,
        "second_scrub_extra_deletes": 0,
    },
    "restore": {
        "unattributed_residue_user_objects": 0,
        "unknown_user_objects": 0,
        "schema_attributed_objects": 4,
        "retention_attributed_objects": 1,
        "system_attributed_objects": 1,
        "shared_atom_schema_paths": 2,
    },
    "writes": {
        "concurrent_write_source_events": 1,
        "concurrent_write_attribution_paths": 1,
        "later_write_source_event_before_response": True,
        "later_write_inline_size_before_response": True,
    },
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    json.dump(doc, handle)
PY

python3 - "$WORK/good.json" "$WORK/unknown.json" "$WORK/delete.json" "$WORK/primary.json" "$WORK/booleans.json" <<'PY'
import json
import sys

good, unknown, delete, primary, booleans = sys.argv[1:]
data = json.loads(open(good, encoding="utf-8").read())
data["restore"]["unknown_user_objects"] = 1
json.dump(data, open(unknown, "w", encoding="utf-8"))
data = json.loads(open(good, encoding="utf-8").read())
data["surface"]["source_delete"] = True
json.dump(data, open(delete, "w", encoding="utf-8"))
data = json.loads(open(good, encoding="utf-8").read())
data["surface"]["home_path"] = "/tmp/schema-root-proof/.lastdb"
json.dump(data, open(primary, "w", encoding="utf-8"))
json.dump({"schema": "lastdb-schema-root-data-attribution-proof.v1", "ok": True}, open(booleans, "w", encoding="utf-8"))
PY

mkdir -p "$WORK/bin" "$WORK/home/.lastdb"
cat >"$WORK/bin/lastdb" <<EOF
#!/bin/sh
echo called >"$WORK/marker"
exit 99
EOF
cat >"$WORK/bin/brain" <<EOF
#!/bin/sh
echo called >"$WORK/marker"
exit 99
EOF
chmod +x "$WORK/bin/lastdb" "$WORK/bin/brain"
cp "$WORK/good.json" "$WORK/home/.lastdb/evidence.json"

PATH="$WORK/bin:$PATH" \
SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE= \
NORTH_STAR_PROOF_DIR="$WORK/absent" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/absent.out" 2>"$WORK/absent.err" || true
[ ! -e "$WORK/marker" ] || fail "the offline proof called lastdb or brain"
expect_verdict "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'Source contract: PASS' "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'Offline exercise: PASS' "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'Operational evidence: ABSENT' "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The harness did not open a LastDB home.' \
  "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The harness did not reclaim residue on a shared node.' \
  "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The harness did not delete from a source home.' \
  "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The copy removed only the injected residue object.' \
  "$WORK/absent/north-star-lastdb-schema-root-data-attribution.md"
if "$EVALUATOR" --kind validation \
  --predicate "file $WORK/absent/north-star-lastdb-schema-root-data-attribution.md matches /^PASS/" \
  >"$WORK/absent-eval.out"; then
  fail "a report without operational evidence satisfied /^PASS/"
fi
grep -q '^pending:' "$WORK/absent-eval.out" || fail "missing-evidence report was not pending"

# An unset evidence variable loads the committed measurement. That file
# records the throwaway copy. The node wrote no history row, no system
# schema, no attribution path, and no inline size, so the proof stays FAIL.
if PATH="$WORK/bin:$PATH" \
  env -u SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  NORTH_STAR_PROOF_DIR="$WORK/committed" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/committed.out" 2>"$WORK/committed.err"; then
  fail "the committed measurement was accepted as PASS"
fi
expect_verdict "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -F -q "Evidence file: $ROOT/harness/north-star/north-star-lastdb-schema-root-data-attribution/measured-evidence.json" \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md" ||
  fail "the default evidence path is not measured-evidence.json"
grep -q 'Operational evidence: FAIL' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The evidence field retention_attributed_objects is below 1.' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The evidence field system_attributed_objects is below 1.' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The evidence field concurrent_write_attribution_paths is not 1.' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The evidence field later_write_inline_size_before_response is not true.' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"
if grep -q 'Operational evidence: ABSENT' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"; then
  fail "the committed measurement was treated as absent"
fi
if grep -q 'Operational evidence: PASS' \
  "$WORK/committed/north-star-lastdb-schema-root-data-attribution.md"; then
  fail "the committed measurement passed the operational check"
fi

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/booleans.json" \
  NORTH_STAR_PROOF_DIR="$WORK/booleans" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/booleans.out" 2>"$WORK/booleans.err"; then
  fail "a JSON file of booleans was accepted as operational evidence"
fi
expect_verdict "$WORK/booleans/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'The evidence section surface is absent.' \
  "$WORK/booleans/north-star-lastdb-schema-root-data-attribution.md"

PATH="$WORK/bin:$PATH" \
SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/good.json" \
NORTH_STAR_PROOF_DIR="$WORK/good" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/good.out"
[ ! -e "$WORK/marker" ] || fail "the evidence path called lastdb or brain"
expect_verdict "$WORK/good/north-star-lastdb-schema-root-data-attribution.md" PASS-OFFLINE
grep -q 'Operational evidence: PASS' "$WORK/good/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'Unattributed-residue user objects: 0.' \
  "$WORK/good/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'Unknown user objects: 0.' \
  "$WORK/good/north-star-lastdb-schema-root-data-attribution.md"
"$EVALUATOR" --kind validation \
  --predicate "file $WORK/good/north-star-lastdb-schema-root-data-attribution.md matches /^PASS/" \
  >"$WORK/good-eval.out"
grep -q '^satisfied:' "$WORK/good-eval.out" || fail "PASS-OFFLINE did not satisfy /^PASS/"

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/unknown.json" \
  NORTH_STAR_PROOF_DIR="$WORK/unknown" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/unknown.out" 2>"$WORK/unknown.err"; then
  fail "a restore with an unknown user object was accepted"
fi
expect_verdict "$WORK/unknown/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'The evidence field unknown_user_objects is not 0.' \
  "$WORK/unknown/north-star-lastdb-schema-root-data-attribution.md"

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/delete.json" \
  NORTH_STAR_PROOF_DIR="$WORK/delete" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/delete.out" 2>"$WORK/delete.err"; then
  fail "source deletion evidence was accepted"
fi
expect_verdict "$WORK/delete/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'The evidence field source_delete is not false.' \
  "$WORK/delete/north-star-lastdb-schema-root-data-attribution.md"

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/primary.json" \
  NORTH_STAR_PROOF_DIR="$WORK/primary-json" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/primary-json.out" 2>"$WORK/primary-json.err"; then
  fail "evidence that names a LastDB home was accepted"
fi
expect_verdict "$WORK/primary-json/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'The evidence names a LastDB home or a secret.' \
  "$WORK/primary-json/north-star-lastdb-schema-root-data-attribution.md"

if PATH="$WORK/bin:$PATH" \
  HOME="$WORK/home" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/home/.lastdb/evidence.json" \
  NORTH_STAR_PROOF_DIR="$WORK/primary-path" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/primary-path.out" 2>"$WORK/primary-path.err"; then
  fail "an evidence path under a LastDB home was accepted"
fi
expect_verdict "$WORK/primary-path/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'The harness refuses a LastDB home path.' \
  "$WORK/primary-path/north-star-lastdb-schema-root-data-attribution.md"
[ ! -e "$WORK/marker" ] || fail "the primary-path refusal called lastdb or brain"

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE=1 \
  NORTH_STAR_PROOF_DIR="$WORK/source-delete" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/source-delete.out" 2>"$WORK/source-delete.err"; then
  fail "an explicit source delete request was accepted"
fi
expect_verdict "$WORK/source-delete/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'Remove SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE.' \
  "$WORK/source-delete/north-star-lastdb-schema-root-data-attribution.md"

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER=1 \
  NORTH_STAR_PROOF_DIR="$WORK/cutover" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/cutover.out" 2>"$WORK/cutover.err"; then
  fail "an explicit production cutover request was accepted"
fi
expect_verdict "$WORK/cutover/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'Remove SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER.' \
  "$WORK/cutover/north-star-lastdb-schema-root-data-attribution.md"

if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$FIXTURE" \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE="$WORK/good.json" \
  NORTH_STAR_PROOF_DIR="$WORK/live" \
  "$RUNNER" --live north-star-lastdb-schema-root-data-attribution \
  >"$WORK/live.out" 2>"$WORK/live.err"; then
  fail "live mode was accepted"
fi
expect_verdict "$WORK/live/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'This harness runs in offline mode only.' \
  "$WORK/live/north-star-lastdb-schema-root-data-attribution.md"

mkdir -p "$WORK/cheat/fold_db/crates/core/src/db_operations" \
  "$WORK/cheat/fold_db/crates/core/src/fold_db_core/mutation_manager" \
  "$WORK/cheat/fold_db/crates/core/src/schema/core" \
  "$WORK/cheat/lastdb_node/src"
cp -R "$FIXTURE/fold_db/crates/core/src/fold_db_core" "$WORK/cheat/fold_db/crates/core/src/"
cp -R "$FIXTURE/fold_db/crates/core/src/schema" "$WORK/cheat/fold_db/crates/core/src/"
cp "$FIXTURE/lastdb_node/src/attribution_epoch.rs" "$WORK/cheat/lastdb_node/src/attribution_epoch.rs"
python3 - "$FIXTURE/fold_db/crates/core/src/db_operations/attribution_ledger.rs" \
  "$WORK/cheat/fold_db/crates/core/src/db_operations/attribution_ledger.rs" <<'PY'
import pathlib
import sys
source, dest = sys.argv[1:]
text = pathlib.Path(source).read_text(encoding="utf-8")
needle = "    UnattributedResidue,\n"
if needle not in text:
    raise SystemExit("fixture lost the residue class")
pathlib.Path(dest).write_text(text.replace(needle, "", 1), encoding="utf-8")
PY
if PATH="$WORK/bin:$PATH" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$WORK/cheat" \
  NORTH_STAR_PROOF_DIR="$WORK/cheat-report" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/cheat.out" 2>"$WORK/cheat.err"; then
  fail "a ledger without the residue class passed"
fi
expect_verdict "$WORK/cheat-report/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'Source contract: FAIL' "$WORK/cheat-report/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'The attribution class UnattributedResidue is absent.' \
  "$WORK/cheat-report/north-star-lastdb-schema-root-data-attribution.md"

mkdir -p "$WORK/home/.lastdb"
refused="$WORK/home/.lastdb/schema-root-proof-refuse"
if PATH="$WORK/bin:$PATH" \
  HOME="$WORK/home" \
  SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$refused" \
  NORTH_STAR_PROOF_DIR="$WORK/primary-source" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/primary-source.out" 2>"$WORK/primary-source.err"; then
  fail "a source path under a LastDB home was accepted"
fi
[ ! -e "$refused" ] || fail "the harness created a path under the LastDB home"
expect_verdict "$WORK/primary-source/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'The harness refuses a LastDB home path.' \
  "$WORK/primary-source/north-star-lastdb-schema-root-data-attribution.md"

mkdir -p "$WORK/git-seed"
git -C "$WORK/git-seed" init -q -b main
cp -R "$FIXTURE/fold_db" "$FIXTURE/lastdb_node" "$WORK/git-seed/"
git -C "$WORK/git-seed" add fold_db lastdb_node
git -C "$WORK/git-seed" -c user.name=Test -c user.email=test@example.invalid \
  commit -q -m 'fixture'
git -C "$WORK/git-seed" worktree add --quiet --detach "$WORK/fold-wt" HEAD
rm -rf "$WORK/fold-wt/fold_db" "$WORK/fold-wt/lastdb_node"
[ -f "$WORK/fold-wt/.git" ] || fail "the Fold worktree .git entry is not a file"
grep -q '^gitdir: ' "$WORK/fold-wt/.git" ||
  fail "the Fold worktree .git file lacks a gitdir prefix"
[ ! -e "$WORK/fold-wt/lastdb_node/src/attribution_epoch.rs" ] ||
  fail "the Fold worktree still has a checked-out source file"

PATH="$WORK/bin:$PATH" \
env -u SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR \
  -u SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE -u SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER \
  SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE= \
  FOLD_REPO="$WORK/fold-wt" \
  NORTH_STAR_PROOF_DIR="$WORK/worktree" \
  "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
  >"$WORK/worktree.out" 2>"$WORK/worktree.err" || true
expect_verdict "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md" FAIL
grep -q 'Source contract: PASS' "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md" ||
  fail "a Fold worktree .git file did not satisfy the attribution contract: $(ns_fold_report_failures "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md")"
grep -q 'Offline exercise: PASS' "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'Operational evidence: ABSENT' "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md"
grep -F -q "Source label: git:$WORK/fold-wt:HEAD" \
  "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md" ||
  fail "the harness did not load the Fold worktree with git show"
[ ! -e "$WORK/marker" ] || fail "the worktree proof called lastdb or brain"

# ── the ordering rule follows one call hop ───────────────────────────────────
# The rule is "a pending scope is opened before its event is appended", and that
# is a property of the CALL PATH. Two upstream pipelines share one attribution
# tail, so fold moved the append into a helper and left each caller's
# `begin_pending_scopes` in place; a span-local reading called that a violation
# and turned this gate red on every last-stack run of 2026-09-26.
# The fixture above carries only the inline spelling, which is why nothing
# caught it. These four cases carry the other shapes.
# papercut-north-star-attribution-ordering-rule-is-span-local-20260926
ordering_tree() {
  # ordering_tree <dir> <write.rs body>: a full source tree that differs from
  # the fixture in the write path only.
  local dir="$1" body="$2"
  mkdir -p "$dir/fold_db/crates/core/src/db_operations" \
    "$dir/fold_db/crates/core/src/fold_db_core/mutation_manager" \
    "$dir/fold_db/crates/core/src/schema/core" \
    "$dir/lastdb_node/src"
  cp -R "$FIXTURE/fold_db/crates/core/src/schema" "$dir/fold_db/crates/core/src/"
  cp "$FIXTURE/fold_db/crates/core/src/db_operations/attribution_ledger.rs" \
    "$dir/fold_db/crates/core/src/db_operations/attribution_ledger.rs"
  cp "$FIXTURE/lastdb_node/src/attribution_epoch.rs" "$dir/lastdb_node/src/attribution_epoch.rs"
  printf '%s\n' "$body" >"$dir/fold_db/crates/core/src/fold_db_core/mutation_manager/write.rs"
}
ordering_report() {
  # ordering_report <dir> <report-dir>: run the source check over that tree.
  PATH="$WORK/bin:$PATH" \
    SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR="$1" \
    NORTH_STAR_PROOF_DIR="$2" \
    "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
    >"$2.out" 2>"$2.err" || true
  printf '%s' "$2/north-star-lastdb-schema-root-data-attribution.md"
}
ordering_gate="$(cat <<'RS'
fn attribution_source_events_enabled() -> bool {
    std::env::var("LASTDB_ATTRIBUTION_SOURCE_EVENTS")
        .is_ok_and(|value| matches!(value.trim(), "1" | "true" | "on" | "yes"))
}
RS
)"
ordering_helper="$(cat <<'RS'
    async fn record_attribution_scopes(&self) -> Result<(), ()> {
        self.db_ops
            .attribution()
            .append_events_and_clear_pending_scopes(attribution_events(), &mutation_ids)
            .await?;
        Ok(())
    }
RS
)"

# The consolidated shape fold actually ships: the append is in a helper and both
# callers begin first. The source contract must PASS.
ordering_tree "$WORK/order-helper" "$ordering_gate
$ordering_helper
    async fn write_mutations_batch_with_receipt_cloud(&self) -> Result<(), ()> {
        self.db_ops.attribution().begin_pending_scopes(&scopes).await?;
        let receipt = self.write_with_aggregate_invalidations().await?;
        self.record_attribution_scopes(&scopes).await?;
        Ok(receipt)
    }
    pub(crate) async fn apply_replayed_mutations(&self) -> Result<(), ()> {
        self.db_ops.attribution().begin_pending_scopes(&scopes).await?;
        let receipt = self.write_with_aggregate_invalidations().await?;
        self.record_attribution_scopes(&scopes).await?;
        Ok(receipt)
    }"
report="$(ordering_report "$WORK/order-helper" "$WORK/order-helper-report")"
grep -q 'Source contract: PASS' "$report" \
  || fail "a shared attribution tail in a helper was read as a violation: $(sed -n '/Source failures/,+4p' "$report")"

# A caller that appends through the helper BEFORE it begins is the real
# regression, and it must still fail. The wrong ORDER, not an absent begin:
# a fixture with no begin at all cannot reach this branch.
ordering_tree "$WORK/order-late-begin" "$ordering_gate
$ordering_helper
    async fn write_mutations_batch_with_receipt_cloud(&self) -> Result<(), ()> {
        let receipt = self.write_with_aggregate_invalidations().await?;
        self.record_attribution_scopes(&scopes).await?;
        self.db_ops.attribution().begin_pending_scopes(&scopes).await?;
        Ok(receipt)
    }"
report="$(ordering_report "$WORK/order-late-begin" "$WORK/order-late-begin-report")"
grep -q 'A write appends an attribution event before its pending scope.' "$report" \
  || fail "a caller that appends before it begins passed: $(sed -n '/Source failures/,+4p' "$report")"

# An append nothing reaches after a begin has no proved ordering either.
ordering_tree "$WORK/order-orphan" "$ordering_gate
$ordering_helper
    async fn write_mutations_batch_with_receipt_cloud(&self) -> Result<(), ()> {
        self.db_ops.attribution().begin_pending_scopes(&scopes).await?;
        Ok(())
    }"
report="$(ordering_report "$WORK/order-orphan" "$WORK/order-orphan-report")"
grep -q 'A write appends an attribution event before its pending scope.' "$report" \
  || fail "an unreachable append helper passed: $(sed -n '/Source failures/,+4p' "$report")"

# The span-local violation the rule was written for, which the fixture never
# exercised: one function, append first, begin after.
ordering_tree "$WORK/order-inline" "$ordering_gate
    async fn write_mutations_batch_with_receipt_cloud(&self) -> Result<(), ()> {
        self.db_ops
            .attribution()
            .append_events_and_clear_pending_scopes(attribution_events(), &mutation_ids)
            .await?;
        self.db_ops.attribution().begin_pending_scopes(&scopes).await?;
        Ok(())
    }"
report="$(ordering_report "$WORK/order-inline" "$WORK/order-inline-report")"
grep -q 'A write appends an attribution event before its pending scope.' "$report" \
  || fail "an inline append before its begin passed: $(sed -n '/Source failures/,+4p' "$report")"

# --- Fold source lanes -------------------------------------------------------
# This is a last-stack gate, so its exit code must be a function of a last-stack
# commit. Grading the Fold portal's CURRENT head broke that: fold merged a
# correct refactor at 2026-09-26T11:24Z and every last-stack PR went red on it,
# and the mirror's HEAD is a branch a registered worktree freezes, so the gate
# graded 26f0f601f while fold's real main was 590ac314e.
# papercut-last-stack-ci-shard-grades-the-live-fold-portal-head-20260926
#
# Reporting lane: the live head. A DRIFT notice, never an exit code.
# Blocking lane: the PINNED oid in harness/north-star/fold-source.pin.
# Every assertion that is about OUR harness rather than about fold's content
# stays blocking in both lanes.
PORTAL="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}/fold/.portal/cache"
if [ -f "$PORTAL" ]; then
  MIRROR="$(tr -d '[:space:]' <"$PORTAL")"
  portal_run() {
    # portal_run <report-dir> [<fold oid>]: grade the portal source.
    local dir="$1" oid="${2:-}"
    PATH="$WORK/bin:$PATH" \
    env -u SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR \
      -u SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE \
      -u SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER \
      -u FOLD_REPO \
      SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE= \
      NORTH_STAR_FOLD_SOURCE_OID="$oid" \
      NORTH_STAR_PROOF_DIR="$dir" \
      "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
      >"$dir.out" 2>"$dir.err" || true
  }

  # Reporting lane: the live mirror head.
  portal_run "$WORK/portal-live"
  live_report="$WORK/portal-live/north-star-lastdb-schema-root-data-attribution.md"
  ns_fold_drift_report "live fold portal head" \
    "$(ns_fold_rev_label "$MIRROR" HEAD)" "$live_report"
  if ns_fold_source_absent "$live_report"; then
    echo "fold-source-drift: the live fold head is not readable in $MIRROR; skipping the live-lane harness assertions" >&2
  else
    # These hold whatever fold contains: they are properties of THIS harness.
    expect_verdict "$live_report" FAIL
    grep -q 'Operational evidence: ABSENT' "$live_report" ||
      fail "the live portal report lacks Operational evidence: ABSENT: $(ns_fold_report_failures "$live_report")"
    [ ! -e "$WORK/marker" ] || fail "the portal proof called lastdb or brain"
  fi

  # Blocking lane: the pinned oid.
  if PIN="$(ns_fold_source_pin)"; then
    if ns_fold_rev_present "$MIRROR" "$PIN"; then
      portal_run "$WORK/portal-pin" "$PIN"
      pin_report="$WORK/portal-pin/north-star-lastdb-schema-root-data-attribution.md"
      expect_verdict "$pin_report" FAIL
      grep -q 'Source contract: PASS' "$pin_report" ||
        fail "pinned fold $PIN lacks Source contract: PASS — fix fold or move harness/north-star/fold-source.pin deliberately: $(ns_fold_report_failures "$pin_report")"
      grep -q 'Offline exercise: PASS' "$pin_report" ||
        fail "pinned fold $PIN lacks Offline exercise: PASS — fix fold or move harness/north-star/fold-source.pin deliberately: $(ns_fold_report_failures "$pin_report")"
      grep -q 'Operational evidence: ABSENT' "$pin_report" ||
        fail "the pinned portal report lacks Operational evidence: ABSENT: $(ns_fold_report_failures "$pin_report")"
      grep -F -q "Source label: fold-portal:$PIN" "$pin_report" ||
        fail "the report does not name the fold commit it graded: $(grep -F 'Source label:' "$pin_report")"
      [ ! -e "$WORK/marker" ] || fail "the pinned portal proof called lastdb or brain"
    else
      # A pin this mirror cannot resolve is an environment fact, not a
      # last-stack defect. Refusing here would put another repo's fetch
      # state back in this gate's exit code, which is the whole defect.
      # The fixture lanes above still gate the contract; say so loudly.
      echo "fold-source-pin: skip — $PIN is not in $MIRROR; the fixture lanes still gate this contract" >&2
    fi
  else
    fail "harness/north-star/fold-source.pin holds no fold oid"
  fi
fi

echo "PASS last-stack-north-star-proof-schema-root-attribution"
