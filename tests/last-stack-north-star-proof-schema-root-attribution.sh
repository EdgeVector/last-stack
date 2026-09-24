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
  fail "a Fold worktree .git file did not satisfy the attribution contract"
grep -q 'Offline exercise: PASS' "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md"
grep -q 'Operational evidence: ABSENT' "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md"
grep -F -q "Source label: git:$WORK/fold-wt:HEAD" \
  "$WORK/worktree/north-star-lastdb-schema-root-data-attribution.md" ||
  fail "the harness did not load the Fold worktree with git show"
[ ! -e "$WORK/marker" ] || fail "the worktree proof called lastdb or brain"

PORTAL="${EDGEVECTOR_WORKSPACE:-$HOME/code/edgevector}/fold/.portal/cache"
if [ -f "$PORTAL" ]; then
  PATH="$WORK/bin:$PATH" \
  env -u SCHEMA_ROOT_ATTRIBUTION_SOURCE_DIR \
    -u SCHEMA_ROOT_ATTRIBUTION_ALLOW_SOURCE_DELETE -u SCHEMA_ROOT_ATTRIBUTION_ALLOW_PROD_CUTOVER \
    -u FOLD_REPO \
    SCHEMA_ROOT_ATTRIBUTION_PROOF_EVIDENCE_FILE= \
    NORTH_STAR_PROOF_DIR="$WORK/portal" \
    "$RUNNER" --offline north-star-lastdb-schema-root-data-attribution \
    >"$WORK/portal.out" 2>"$WORK/portal.err" || true
  expect_verdict "$WORK/portal/north-star-lastdb-schema-root-data-attribution.md" FAIL
  grep -q 'Source contract: PASS' "$WORK/portal/north-star-lastdb-schema-root-data-attribution.md" ||
    fail "the Fold portal source did not satisfy the attribution contract"
  grep -q 'Offline exercise: PASS' "$WORK/portal/north-star-lastdb-schema-root-data-attribution.md"
  grep -q 'Operational evidence: ABSENT' "$WORK/portal/north-star-lastdb-schema-root-data-attribution.md"
  [ ! -e "$WORK/marker" ] || fail "the portal proof called lastdb or brain"
fi

echo "PASS last-stack-north-star-proof-schema-root-attribution"
